#!/usr/bin/env bash
#
# disk-stats.sh — plasmatop-disk data source
#
# Prints ONE line of JSON to stdout with raw current-state usage figures for
# every "real" mounted filesystem on this machine. Like mem-stats.sh, every
# figure here is an instantaneous gauge (used/total bytes right now) — no
# delta math anywhere, per ARCHITECTURE.md's per-widget notes for disk usage
# (throughput would need delta math, but that's explicitly out of scope for
# this widget, see BACKLOG/ARCHITECTURE — usage bars only).
#
# Mount discovery reads /proc/mounts directly (more script-friendly than
# parsing `df` output's column formatting/locale quirks) and applies three
# filters, entirely generically — nothing below is hardcoded to any specific
# path/device on this machine:
#
#   1. Filesystem-type blocklist — excludes virtual/pseudo filesystems
#      (tmpfs, proc, cgroup2, etc. — see BLOCKED_FSTYPES below). This list
#      was built by actually enumerating this machine's live /proc/mounts
#      (`cut -d' ' -f3 /proc/mounts | sort -u`) and is a superset of the
#      product owner's initial list — this machine also mounts selinuxfs,
#      binder, rpc_pipefs, and a couple of virtual fuse.* subtypes
#      (fuse.portal, fuse.kio-fuse) that aren't real storage either.
#      NOTE: "fuseblk" (a real filesystem exposed through FUSE, e.g. this
#      machine's NTFS-formatted /dev/sda1 drive) is deliberately NOT
#      blocked — only the *virtual* fuse.* subtypes are, by exact fstype
#      match, so a real fuse-backed filesystem still gets counted.
#
#   2. Dedup by source device — /proc/mounts lists the SAME underlying
#      filesystem once per mountpoint it's attached at (this machine's
#      btrfs root is mounted at both / and /home, subvol=root vs
#      subvol=home, same /dev/nvme0n1p3 block device). Reporting both would
#      double-count that device's free/used space. For each unique first
#      column (source device), keep only the mountpoint with the FEWEST
#      "/"-separated path segments — naturally picks "/" (0 segments) over
#      "/home" (1 segment) without hardcoding either path string.
#
#   3. Minimum-size filter — excludes small partitions (this machine's
#      ~2GiB /boot, ~599MiB /boot/efi) by a size THRESHOLD
#      (MIN_SIZE_BYTES, 10 GiB) rather than by hardcoding those paths,
#      so this generalizes to another machine's boot/EFI partition sizes
#      too.
#
# Label derivation (e.g. "/" -> "ROOT", "/home/olebinders/Games" -> "GAMES")
# deliberately happens in QML, not here — presentation concerns live
# alongside the metric descriptors that consume them, same convention as
# mem-stats.sh leaving the used-memory subtraction to main.qml.
#
# Output shape:
# {
#   "timestamp_ms": 1234567890123,
#   "ok": true,
#   "mounts": [
#     {"mountpoint":"/","source":"/dev/nvme0n1p3","total_bytes":497330159616,"used_bytes":316229259264},
#     {"mountpoint":"/home/olebinders/Games","source":"/dev/nvme1n1p1","total_bytes":2000397795328,"used_bytes":557111730176},
#     {"mountpoint":"/run/media/olebinders/Lagring","source":"/dev/sda1","total_bytes":895344439296,"used_bytes":372557934592}
#   ]
# }

set -euo pipefail

timestamp_ms() {
    echo $(($(date +%s%N) / 1000000))
}

# --- Step 1/2: blocklist + source-dedup (pick shallowest mountpoint) -------
# One awk pass over /proc/mounts. Depth = count of non-empty "/"-split
# segments ("/" -> 0, "/home" -> 1, "/home/olebinders/Games" -> 3) — lower
# depth wins per source, so "/" is naturally preferred over "/home" for the
# same underlying device with no path hardcoded.
BLOCKED_FSTYPES="tmpfs devtmpfs sysfs proc cgroup cgroup2 pstore bpf tracefs \
debugfs securityfs devpts mqueue hugetlbfs fusectl configfs ramfs autofs \
binfmt_misc efivarfs squashfs overlay selinuxfs binder rpc_pipefs \
fuse.portal fuse.kio-fuse fuse.gvfsd-fuse fuse.sdcard"

candidates=$(awk -v blocked="$BLOCKED_FSTYPES" '
    BEGIN {
        n = split(blocked, arr, " ");
        for (i = 1; i <= n; i++) isBlocked[arr[i]] = 1;
    }
    {
        source = $1; mountpoint = $2; fstype = $3;
        if (fstype in isBlocked) next;

        depth = 0;
        segCount = split(mountpoint, segs, "/");
        for (i = 1; i <= segCount; i++) if (segs[i] != "") depth++;

        if (!(source in bestDepth) || depth < bestDepth[source]) {
            bestDepth[source] = depth;
            bestMount[source] = mountpoint;
        }
    }
    END {
        for (s in bestMount) print s "\t" bestMount[s];
    }
' /proc/mounts | sort -t $'\t' -k2,2)
# Sorted by mountpoint (2nd field) -- awk's `for (s in ...)` iteration order
# is unspecified, and QML's list-order should be stable/deterministic run to
# run rather than however the awk hash table happens to enumerate it. "/"
# (0x2F) sorts before any letter, so this also happens to put ROOT first
# whenever it survives filtering, without hardcoding that path anywhere.

# --- Step 3: per-candidate size lookup + minimum-size filter ---------------
# LC_ALL=C so df never inserts a locale-specific thousands separator into
# the byte counts (verified GNU coreutils df doesn't do this regardless,
# but forcing C locale removes any doubt across other systems' df builds).
MIN_SIZE_BYTES=$((10 * 1024 * 1024 * 1024)) # 10 GiB

entries=""
while IFS=$'\t' read -r source escaped_mountpoint; do
    [ -n "$source" ] || continue

    # /proc/mounts escapes space/tab/newline/backslash as octal \NNN
    # (fstab-style) -- bash's `printf %b` decodes that same octal-escape
    # convention natively, so a mountpoint containing a space (e.g. a
    # removable-media label) still round-trips correctly instead of
    # showing up with a literal "\040" in it.
    mountpoint=$(printf '%b' "$escaped_mountpoint")

    [ -d "$mountpoint" ] || continue

    read -r total_bytes used_bytes <<< "$(LC_ALL=C df -B1 --output=size,used "$mountpoint" 2>/dev/null | tail -n1)"
    [ -n "${total_bytes:-}" ] && [ -n "${used_bytes:-}" ] || continue

    if [ "$total_bytes" -lt "$MIN_SIZE_BYTES" ]; then
        continue
    fi

    # JSON-escape the mountpoint/source (basic: backslash and double-quote
    # only -- sufficient for real-world path characters; a mountpoint
    # containing a raw control character is not a case worth handling here).
    json_mountpoint=$(printf '%s' "$mountpoint" | sed 's/\\/\\\\/g; s/"/\\"/g')
    json_source=$(printf '%s' "$source" | sed 's/\\/\\\\/g; s/"/\\"/g')

    entry=$(printf '{"mountpoint":"%s","source":"%s","total_bytes":%d,"used_bytes":%d}' \
        "$json_mountpoint" "$json_source" "$total_bytes" "$used_bytes")

    if [ -z "$entries" ]; then
        entries="$entry"
    else
        entries="$entries,$entry"
    fi
done <<< "$candidates"

printf '{"timestamp_ms":%s,"ok":true,"mounts":[%s]}\n' "$(timestamp_ms)" "$entries"
