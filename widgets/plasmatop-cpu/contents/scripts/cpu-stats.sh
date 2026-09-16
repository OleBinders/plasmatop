#!/usr/bin/env bash
#
# cpu-stats.sh — plasmatop-cpu data source
#
# Prints ONE line of JSON to stdout with raw current-state CPU telemetry.
# No delta math is done here (no busy% figures) — the widget's QML keeps
# the previous tick's raw /proc/stat jiffie counters per core and computes
# busy% from the delta, per ARCHITECTURE.md's "cumulative-counter deltas
# are computed in QML, not in the script" rule (same split as GPU/network).
# This keeps the script a simple, stateless, single-shot read.
#
# All data sources here are plain world-readable files — no permission
# workarounds needed anywhere (unlike GPU's xe/fdinfo situation), confirmed
# live in research/r8-cpu-telemetry.md.
#
# The coretemp hwmon index is discovered dynamically every run — never
# hardcode hwmon7, it's boot-order-dependent exactly like GPU's hwmon3
# (research/r8 §3, same pattern gpu-stats.sh already uses for "xe").
#
# Output shape:
# {
#   "timestamp_ms": 1234567890123,
#   "ok": true,
#   "cpus": {
#     "0": {"user":195266,"nice":104070,"system":141437,"idle":9146355,
#           "iowait":28500,"irq":6395,"softirq":13796,"steal":0},
#     "1": { ... same shape, one entry per logical core (cpuN line) ... }
#   },
#   "freq_khz": {"0": 4523012, "1": 4498135, ...},
#   "temp_pkg_c": 35.0
# }
#
# cpus.<N>.* are the raw cumulative jiffie counters for that logical core's
# `cpuN` line in /proc/stat, in the same field order the kernel documents
# (user nice system idle iowait irq softirq steal — guest/guest_nice
# omitted, not needed for the busy% formula: busy% = 100 * (1 -
# Δ(idle+iowait) / Δ(sum of all fields)), computed in QML between two
# ticks). freq_khz.<N> is that core's current
# /sys/devices/system/cpu/cpuN/cpufreq/scaling_cur_freq reading (kHz);
# QML takes the max across all cores for the AsciiBox header's aggregate
# frequency readout (research/r8 §4). temp_pkg_c is the coretemp package
# sensor (`Package id 0` label), already converted from hwmon's raw
# millidegrees to °C here (a direct snapshot value, not a cumulative
# counter — no delta math needed for this one field, same as GPU's temp
# readings).

set -euo pipefail

timestamp_ms() {
    echo $(($(date +%s%N) / 1000000))
}

# --- Per-core /proc/stat counters + per-core frequency ----------------------
cpus_json=""
freq_json=""
first_cpu=1
first_freq=1

while read -r line; do
    case "$line" in
        cpu[0-9]*)
            # Fields: cpuN user nice system idle iowait irq softirq steal guest guest_nice
            read -r label user nice system idle iowait irq softirq steal _ _ <<< "$line"
            n="${label#cpu}"

            [ "$first_cpu" -eq 1 ] || cpus_json="${cpus_json},"
            cpus_json="${cpus_json}\"${n}\":{\"user\":${user},\"nice\":${nice},\"system\":${system},\"idle\":${idle},\"iowait\":${iowait},\"irq\":${irq},\"softirq\":${softirq},\"steal\":${steal}}"
            first_cpu=0

            freq_path="/sys/devices/system/cpu/cpu${n}/cpufreq/scaling_cur_freq"
            freq="0"
            [ -r "$freq_path" ] && freq=$(cat "$freq_path" 2>/dev/null || echo 0)

            [ "$first_freq" -eq 1 ] || freq_json="${freq_json},"
            freq_json="${freq_json}\"${n}\":${freq}"
            first_freq=0
            ;;
    esac
done < /proc/stat

# --- Package temperature (coretemp hwmon, discovered dynamically) ----------
temp_pkg_c="null"

hwmon=""
for dir in /sys/class/hwmon/hwmon[0-9]*; do
    [ -e "$dir/name" ] || continue
    if [ "$(cat "$dir/name" 2>/dev/null)" = "coretemp" ]; then
        hwmon="$dir"
        break
    fi
done

if [ -n "$hwmon" ]; then
    for entry in "$hwmon"/temp*_label; do
        [ -e "$entry" ] || continue
        label=$(cat "$entry" 2>/dev/null || echo "")
        if [ "$label" = "Package id 0" ]; then
            input="${entry%_label}_input"
            if [ -r "$input" ]; then
                raw=$(cat "$input" 2>/dev/null || echo "")
                if [ -n "$raw" ]; then
                    temp_pkg_c=$(awk -v r="$raw" 'BEGIN { printf "%.1f", r / 1000 }')
                fi
            fi
            break
        fi
    done
fi

printf '{"timestamp_ms":%s,"ok":true,"cpus":{%s},"freq_khz":{%s},"temp_pkg_c":%s}\n' \
    "$(timestamp_ms)" "$cpus_json" "$freq_json" "$temp_pkg_c"
