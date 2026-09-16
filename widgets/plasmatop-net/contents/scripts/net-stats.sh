#!/usr/bin/env bash
#
# net-stats.sh — plasmatop-net data source
#
# Prints ONE line of JSON to stdout with the current default-route
# interface's raw cumulative rx/tx byte counters. No delta/rate math is
# done here — the widget's QML keeps the previous tick's raw values and
# divides by actual elapsed wall time, per ARCHITECTURE.md's "cumulative
# counter deltas are computed in QML, not in the script" rule (same split
# as gpu-stats.sh's busy-time/energy counters). This keeps the script a
# simple, stateless, single-shot read.
#
# Scope decision (product owner, see AGENTS.md task brief): show throughput
# for the PRIMARY (default-route) interface only — not per-interface, not
# an aggregate across all interfaces.
#
# The default-route interface is re-detected on EVERY invocation, not
# cached — it can legitimately change between polls (wifi reconnect,
# docking/undocking, VPN up/down). main.qml guards against computing a
# nonsense delta across an interface change by comparing this tick's
# "interface" field against the previous tick's before doing any byte-count
# subtraction (see applyStats() there).
#
# --- Default-route detection -----------------------------------------------
# Reads /proc/net/route directly rather than shelling out to `ip route show
# default` — one fewer external-binary dependency, and the file format is
# stable/documented. Header line (NR==1: "Iface Destination Gateway Flags
# RefCnt Use Metric Mask MTU Window IRTT") is skipped; a "default route" is
# any row whose Destination column is the all-zeros network 00000000
# (network-byte-order hex, so 00000000 regardless of host endianness). If
# more than one such row exists (e.g. both wired and wifi up with a default
# route each), the one with the lowest Metric column wins, matching how the
# kernel itself picks which default route actually carries traffic.
#
# No default route present (e.g. freshly booted with networking still
# coming up, or genuinely offline) is handled as a normal, non-crashing
# "no data yet" case: this script exits 0 with ok:false and an error
# string, exactly like gpu-stats.sh does for "no xe card found". main.qml's
# onNewData warns and returns without touching haveData, so the widget
# keeps showing its "—" waiting sentinel (same convention as every other
# plasmatop widget) instead of crashing or showing garbage.
#
# --- Byte counters ------------------------------------------------------
# /proc/net/dev's well-known parsing quirk: a long interface name can run
# directly into its first counter with no whitespace between the ":" and
# the number (e.g. "reallylonginterface:12345"), which would otherwise
# glue them into one awk field. Fixed here the standard way: `sed 's/:/ /'`
# inserts a space in place of the (single, per-line) colon before handing
# the line to awk, so the interface name and its first counter always land
# in separate fields regardless of name length.
#
# After that substitution each data line is:
#   <iface> <rx_bytes> <rx_packets> <rx_errs> <rx_drop> <rx_fifo> \
#     <rx_frame> <rx_compressed> <rx_multicast> <tx_bytes> ...
# i.e. rx_bytes is field 2, tx_bytes is field 10 (8 receive columns then
# 8 transmit columns, per /proc/net/dev's own header row) — verified
# live against this machine's /proc/net/dev.
#
# Output shape:
# {
#   "timestamp_ms": 1234567890123,
#   "ok": true,
#   "interface": "eno1",
#   "rx_bytes": 5368889634,
#   "tx_bytes": 3795328681
# }

set -euo pipefail

timestamp_ms() {
    echo $(($(date +%s%N) / 1000000))
}

# --- Discover the default-route interface -----------------------------------
iface=$(awk '
    NR > 1 && $2 == "00000000" {
        metric = $7 + 0
        if (best == "" || metric < best) {
            best = metric
            ifc = $1
        }
    }
    END { print ifc }
' /proc/net/route 2>/dev/null || true)

if [ -z "$iface" ]; then
    printf '{"timestamp_ms":%s,"ok":false,"error":"no default route"}\n' "$(timestamp_ms)"
    exit 0
fi

# --- Read that interface's cumulative rx/tx byte counters -------------------
line=$(sed 's/:/ /' /proc/net/dev | awk -v ifc="$iface" '$1 == ifc { print; exit }')

if [ -z "$line" ]; then
    printf '{"timestamp_ms":%s,"ok":false,"error":"interface not found in /proc/net/dev"}\n' "$(timestamp_ms)"
    exit 0
fi

rx_bytes=$(printf '%s\n' "$line" | awk '{print $2}')
tx_bytes=$(printf '%s\n' "$line" | awk '{print $10}')

printf '{"timestamp_ms":%s,"ok":true,"interface":"%s","rx_bytes":%s,"tx_bytes":%s}\n' \
    "$(timestamp_ms)" "$iface" "$rx_bytes" "$tx_bytes"
