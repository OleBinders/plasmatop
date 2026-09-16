#!/usr/bin/env bash
#
# mem-stats.sh — plasmatop-mem data source
#
# Prints ONE line of JSON to stdout with raw current-state memory/swap
# figures read from /proc/meminfo. Unlike gpu-stats.sh/cpu-stats.sh, there
# is NO delta math anywhere in this widget at all (not just "not in the
# script") — every figure here is an instantaneous gauge (how much memory
# is available/free right now), not a cumulative counter, so main.qml can
# use each tick's raw values directly with no previous-tick baseline, per
# ARCHITECTURE.md's per-widget notes ("plasmatop-mem: /proc/meminfo, direct
# values, no delta math needed").
#
# All four fields are converted to BYTES here (from /proc/meminfo's native
# kB, which despite the "kB" label is actually kibibytes, i.e. *1024 — the
# traditional /proc/meminfo unit quirk) so the widget's QML never has to
# remember which unit a given field is in. Bytes, not kB, chosen so the
# same values divide cleanly into GiB (1024^3) for display without an
# intermediate kB->byte step in QML.
#
# Output shape:
# {
#   "timestamp_ms": 1234567890123,
#   "ok": true,
#   "mem_total_bytes": 16663802880,
#   "mem_available_bytes": 10317373440,
#   "swap_total_bytes": 8589930496,
#   "swap_free_bytes": 6342590464
# }
#
# "Used" memory is deliberately NOT computed here — main.qml computes
# usedBytes = mem_total_bytes - mem_available_bytes (NOT MemFree, which
# excludes reclaimable page cache/buffers and wildly overstates "used" —
# see ARCHITECTURE.md/BACKLOG for the full rationale). Keeping that
# subtraction in QML (not here) matches this project's convention of
# scripts being simple raw-value readers, with any presentation math
# living in main.qml alongside the metric descriptors that consume it.

set -euo pipefail

timestamp_ms() {
    echo $(($(date +%s%N) / 1000000))
}

# Single awk pass over /proc/meminfo, pulling just the four fields this
# widget needs. Values in /proc/meminfo are whitespace-separated
# "Label:    12345 kB" lines; $2 is the raw kB figure.
read -r mem_total_kb mem_available_kb swap_total_kb swap_free_kb <<< "$(awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    /^SwapTotal:/    { swaptotal = $2 }
    /^SwapFree:/     { swapfree = $2 }
    END { printf "%d %d %d %d", total+0, avail+0, swaptotal+0, swapfree+0 }
' /proc/meminfo)"

printf '{"timestamp_ms":%s,"ok":true,"mem_total_bytes":%d,"mem_available_bytes":%d,"swap_total_bytes":%d,"swap_free_bytes":%d}\n' \
    "$(timestamp_ms)" \
    "$((mem_total_kb * 1024))" \
    "$((mem_available_kb * 1024))" \
    "$((swap_total_kb * 1024))" \
    "$((swap_free_kb * 1024))"
