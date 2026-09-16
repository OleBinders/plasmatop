#!/usr/bin/env bash
#
# gpu-stats.sh — plasmatop-gpu data source
#
# Prints ONE line of JSON to stdout with raw current-state GPU telemetry.
# No delta math is done here (no VRAM/busy-% percentages, no watts) — the
# widget's QML keeps the previous tick's raw values and divides by actual
# elapsed wall time, per ARCHITECTURE.md's "cumulative-counter deltas are
# computed in QML, not in the script" rule. This keeps the script a simple,
# stateless, single-shot read that's easy to test standalone.
#
# The card (cardN whose driver resolves to "xe") and hwmon index
# (hwmonN whose name is "xe") are discovered dynamically every run — never
# hardcode card1/hwmon3, both are boot-order-dependent (research/r2).
#
# Output shape:
# {
#   "timestamp_ms": 1234567890123,
#   "ok": true,
#   "freq_mhz": 1200,
#   "temp_pkg_c": 51.0,
#   "temp_vram_c": 54.0,
#   "energy_uj": 191145647216,
#   "clients": {
#     "50": {
#       "rcs":  {"cycles": 104713481, "total_cycles": 244492727878},
#       "vcs":  {"cycles": 0,         "total_cycles": 244492727878},
#       "vecs": {"cycles": 0,         "total_cycles": 244492727878},
#       "bcs":  {"cycles": 11077,     "total_cycles": 244492727878},
#       "ccs":  {"cycles": 8324,      "total_cycles": 244492727878},
#       "vram_kib": 0
#     },
#     "207": { ... same shape, one entry per distinct drm-client-id ... }
#   }
# }
#
# clients.<client-id>.<engine>.cycles / total_cycles are the RAW per-client
# cumulative counters from /proc/*/fdinfo (drm-cycles-<name> /
# drm-total-cycles-<name>) for every fd whose drm-driver is "xe",
# deduplicated per drm-client-id (a process can hold several dup()'d fds
# pointing at the same DRM client — summing them raw would multiply-count
# busy time, verified live on this machine: pid 7244/plasmashell held 4
# fds all reporting client-id 50 with identical counters).
#
# clients.<client-id>.vram_kib is that client's CURRENT (not cumulative —
# no delta math needed) VRAM allocation from fdinfo's `drm-total-vram0` key,
# in KiB. Epic 1.7 (VRAM used %): verified live on this machine (no sysfs
# source exists for VRAM used/total on the xe driver, confirmed absent
# again per research/r2 §2) that `/proc/*/fdinfo` DOES carry this directly
# once a process holds an xe DRM fd — e.g. a real captured entry:
#   drm-total-vram0:  9000448 KiB
# Reading nvtop's own source (github.com/Syllo/nvtop,
# src/extract_gpuinfo_intel_xe.c) confirms this is exactly the mechanism it
# uses too: it parses this same "drm-total-vram0" fdinfo key (accepting
# either a " kB" or " KiB" unit suffix across kernel versions) and sums it
# per-process for its MEM column — not `drm-resident-vram0` (which nvtop
# never reads). This script follows the same key/semantics for an
# apples-to-apples match against nvtop's own reported figures. Unlike
# busy-time cycles, this is an instantaneous gauge already, not a
# monotonic counter — no previous-tick baseline is needed, so QML can just
# sum vram_kib across whichever clients are present in a given tick's
# snapshot directly (see applyStats() in main.qml).
#
# VRAM TOTAL capacity has no sysfs/fdinfo source at all (confirmed absent,
# research/r2 §2 again). nvtop gets it from a DRM_IOCTL_XE_DEVICE_QUERY /
# DRM_XE_DEVICE_QUERY_MEM_REGIONS ioctl against an open DRM fd (read
# directly from nvtop's src/extract_gpuinfo_intel_xe.c
# gpuinfo_intel_xe_refresh_dynamic_info()) — not practical to reproduce
# from a bundled bash script (no ioctl builtin; would need a compiled
# helper, which this project's "small bundled shell script per widget"
# data-sourcing pattern deliberately avoids, per ARCHITECTURE.md). Per
# R2's explicitly-sanctioned fallback, VRAM total is instead a configurable
# KConfigXT default (`vramTotalGib`, see contents/config/main.xml),
# seeded from nvtop's own live-observed figure on this exact machine/GPU
# (captured twice, consistently: "11.930Gi" total for the Arc B580).
#
# IMPORTANT, found via live diagnosis (R5 / BACKLOG Epic 1.6): this script
# used to pre-sum both cycles AND total_cycles across all deduped clients
# and emit a single flat "engines" object. That is wrong, not just
# fragile. drm-total-cycles-<name> is each client's OWN reference-clock
# counter — it advances at (approximately) the same rate for every
# concurrently-open client, driven by wall-clock time, NOT a shared
# "engine capacity" that gets divided up among clients. A real desktop
# routinely has 15-25 concurrent xe DRM clients (compositor, Xwayland,
# plasmashell, browser, thumbnailers, idle helpers, etc. — verified live,
# 20 distinct client-ids at once on this machine). Summing total_cycles
# across N such clients inflates the denominator by ~N while the
# numerator (cycles) only picks up real busy contributions — deflating
# true busy% by roughly 1/N. Verified live: a sustained, near-saturating
# OpenCL compute burn on the ccs engine measured ~3.5% by the old sum/sum
# formula against 20 concurrent clients, while correct per-client math
# implies the true figure is on that order times higher. This — not just
# DRM client churn between polls (a second, real bug on top of this one)
# — is the primary explanation for the "ComfyUI shows <=2%" real-world
# report.
#
# Fix: this script now emits raw per-client counters and does NOT sum
# total_cycles across clients at all. QML tracks each client-id's
# previous cycles/total_cycles persistently (surviving across ticks a
# client is absent, so a client only needs to be seen in ANY two ticks,
# not necessarily consecutive, to contribute a valid delta — fixes the
# churn bug), sums Δcycles across clients present in both the current
# tick and their own last-seen tick (multiple simultaneous clients truly
# can each add real busy time to the same engine), and divides by a
# SINGLE reference Δtotal_cycles (any one qualifying client's own delta —
# they all advance at the same rate) rather than the sum of all clients'
# deltas. See engineBusyPercent()/applyStats() in main.qml.
#
# Filtering on driver name alone (not also drm-pdev) is sufficient here
# since this machine has exactly one xe GPU (§ discovery above) — revisit
# if plasmatop ever needs to target a multi-GPU xe machine.

set -euo pipefail

timestamp_ms() {
    echo $(($(date +%s%N) / 1000000))
}

# --- Discover the xe card -----------------------------------------------
card=""
for dir in /sys/class/drm/card[0-9]*; do
    [ -e "$dir" ] || continue
    [ -e "$dir/device/driver" ] || continue
    driver=$(basename "$(readlink -f "$dir/device/driver")" 2>/dev/null || true)
    if [ "$driver" = "xe" ]; then
        card="$dir"
        break
    fi
done

if [ -z "$card" ]; then
    printf '{"timestamp_ms":%s,"ok":false,"error":"no xe drm card found"}\n' "$(timestamp_ms)"
    exit 0
fi

device_path="$card/device"

# --- Discover the xe hwmon index -----------------------------------------
hwmon=""
for dir in "$device_path"/hwmon/hwmon[0-9]*; do
    [ -e "$dir/name" ] || continue
    if [ "$(cat "$dir/name" 2>/dev/null)" = "xe" ]; then
        hwmon="$dir"
        break
    fi
done

# --- Frequency -------------------------------------------------------------
freq_path="$device_path/tile0/gt0/freq0/act_freq"
freq_mhz=0
[ -r "$freq_path" ] && freq_mhz=$(cat "$freq_path" 2>/dev/null || echo 0)

# --- Temperatures (hwmon, m°C -> °C) ---------------------------------------
temp_pkg_c="null"
temp_vram_c="null"
energy_uj="null"

if [ -n "$hwmon" ]; then
    for entry in "$hwmon"/temp*_label; do
        [ -e "$entry" ] || continue
        label=$(cat "$entry" 2>/dev/null || echo "")
        input="${entry%_label}_input"
        [ -r "$input" ] || continue
        raw=$(cat "$input" 2>/dev/null || echo "")
        [ -n "$raw" ] || continue
        case "$label" in
            pkg)  temp_pkg_c=$(awk -v r="$raw" 'BEGIN { printf "%.1f", r / 1000 }') ;;
            vram) temp_vram_c=$(awk -v r="$raw" 'BEGIN { printf "%.1f", r / 1000 }') ;;
        esac
    done

    energy_path="$hwmon/energy1_input"
    if [ -r "$energy_path" ]; then
        energy_uj=$(cat "$energy_path" 2>/dev/null || echo "null")
        [ -n "$energy_uj" ] || energy_uj="null"
    fi
fi

# --- Busy-time counters from /proc/*/fdinfo, deduped by drm-client-id ------
# Engine classes reported by the xe driver's fdinfo (see research/r2 §5-6
# and the live capture in this file's header comment).
#
# Performance note: this machine has ~3000 fdinfo entries across all
# processes at idle. Forking `cat`/`grep` once per file (an early version of
# this script did that) took ~2.9s wall time per invocation -- too slow for
# a 1.5-2s poll interval. Filtering with two `grep` calls (each forks once,
# does its own internal file-loop in C) plus a single `awk` pass over just
# the matched files brings this down to tens of milliseconds.
matched_files=$(grep -l "^drm-driver:" /proc/[0-9]*/fdinfo/* 2>/dev/null \
    | xargs -r grep -l "^drm-driver:[[:space:]]*xe$" 2>/dev/null || true)

clients_json=""
if [ -n "$matched_files" ]; then
    clients_json=$(printf '%s\n' "$matched_files" | xargs awk '
        FNR == 1 {
            cid = ""; cyc_rcs = 0; tot_rcs = 0; cyc_vcs = 0; tot_vcs = 0
            cyc_vecs = 0; tot_vecs = 0; cyc_bcs = 0; tot_bcs = 0; cyc_ccs = 0; tot_ccs = 0
            vram_kib = 0
        }
        /^drm-client-id:/        { cid = $2 }
        /^drm-cycles-rcs:/       { cyc_rcs = $2 }
        /^drm-total-cycles-rcs:/ { tot_rcs = $2 }
        /^drm-cycles-vcs:/       { cyc_vcs = $2 }
        /^drm-total-cycles-vcs:/ { tot_vcs = $2 }
        /^drm-cycles-vecs:/      { cyc_vecs = $2 }
        /^drm-total-cycles-vecs:/{ tot_vecs = $2 }
        /^drm-cycles-bcs:/       { cyc_bcs = $2 }
        /^drm-total-cycles-bcs:/ { tot_bcs = $2 }
        /^drm-cycles-ccs:/       { cyc_ccs = $2 }
        /^drm-total-cycles-ccs:/ { tot_ccs = $2 }
        # Value is like "9000448 KiB" ($2=amount, $3=unit) -- both "KiB"
        # and older-kernel "kB" mean the same 1024-byte unit here (see
        # header comment / nvtop source), so no unit-specific branching
        # is needed, just take $2.
        /^drm-total-vram0:/      { vram_kib = $2 }
        ENDFILE {
            # dup()d fds of the same client report identical cumulative
            # counters -- count each client-id only once, else busy time
            # (and VRAM) is multiplied by however many fds that client
            # happens to hold (verified live: plasmashell held 4 fds, all
            # client-id 50). NOTE: unlike the old version of this script,
            # we do NOT sum cycles/total_cycles across client-ids here --
            # each client keeps its own raw counters in the output. See
            # the header comment above for why summing total_cycles across
            # clients is wrong (it double/triple/N-counts elapsed time
            # once per concurrently-open client instead of once). vram_kib
            # is an instantaneous gauge (not cumulative), so no such
            # caveat applies to it -- it is simply summed across deduped
            # clients directly in QML every tick, no delta math.
            if (cid != "" && !(cid in seen)) {
                seen[cid] = 1
                printf "\"%s\":{\"rcs\":{\"cycles\":%d,\"total_cycles\":%d},\"vcs\":{\"cycles\":%d,\"total_cycles\":%d},\"vecs\":{\"cycles\":%d,\"total_cycles\":%d},\"bcs\":{\"cycles\":%d,\"total_cycles\":%d},\"ccs\":{\"cycles\":%d,\"total_cycles\":%d},\"vram_kib\":%d}\n", \
                    cid, cyc_rcs, tot_rcs, cyc_vcs, tot_vcs, \
                    cyc_vecs, tot_vecs, cyc_bcs, tot_bcs, cyc_ccs, tot_ccs, vram_kib
            }
        }
    ' 2>/dev/null | paste -sd, - || true)
fi

printf '{"timestamp_ms":%s,"ok":true,"freq_mhz":%s,"temp_pkg_c":%s,"temp_vram_c":%s,"energy_uj":%s,"clients":{%s}}\n' \
    "$(timestamp_ms)" \
    "$freq_mhz" "$temp_pkg_c" "$temp_vram_c" "$energy_uj" \
    "$clients_json"
