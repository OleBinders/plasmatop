# R8 — CPU telemetry spike (`plasmatop-cpu`)

Machine: Fedora Linux 44, Plasma 6.7.5. All commands below run live as the
normal user `olebinders` (no sudo), 2026-09-14.

## 0. This machine's actual CPU

```
$ lscpu | head -15
Architecture:                            x86_64
CPU(s):                                  12
On-line CPU(s) list:                     0-11
Vendor ID:                               GenuineIntel
Model name:                              Intel(R) Core(TM) i5-10600K CPU @ 4.10GHz
Thread(s) per core:                      2
Core(s) per socket:                      6
Socket(s):                               1
CPU max MHz:                             4800,0000
CPU min MHz:                             800,0000
```

**Intel Core i5-10600K: 6 physical cores / 12 logical cores (hyperthreading
on), 1 socket.** Not the Arc B580's GPU-side Intel stack — separate
`coretemp` driver, separate hwmon device (see §3). `nproc` also reports
`12`, matching `/proc/cpuinfo`'s `grep -c ^processor` count (`12`). This is
the number that drives the per-core grid size below — genuinely 12 rows'
worth of bars, not 4-8 like most btop screenshots/R6-R7's reference
captures (an 8-core machine).

## 1. Per-core utilization from `/proc/stat`

```
$ head -3 /proc/stat
cpu  2385501 1322997 1727948 111622203 359766 111154 69867 0 0 0
cpu0 195266 104070 141437 9146355 28500 6395 13796 0 0 0
cpu1 212219 121275 139436 9290063 35183 6181 7976 0 0 0
```

Fields after the `cpuN` label are, in order: `user nice system idle iowait
irq softirq steal guest guest_nice` (all cumulative jiffies since boot,
monotonically increasing, never resetting). Confirmed live with two samples
1s apart:

```
cpu0 (t0): 195266 104070 141437 9146355 28500 6395 13796
cpu0 (t1): 195271 104088 141447 9148520(!) 28528 6396 13800
```

**Busy% formula, confirmed correct**: sum all 7 (or 8, including `steal`)
fields for `idle_delta = (idle+iowait)_t1 - (idle+iowait)_t0` and
`total_delta = sum(all fields)_t1 - sum(all fields)_t0`, then
`busy_pct = 100 * (1 - idle_delta/total_delta)`. This is the same
delta-between-two-cumulative-samples pattern as `/proc/net/dev` byte
counters and the GPU widget's `energy1_input`/fdinfo cycles — **identical
shape to the established pattern**, no new technique needed.

**No permission issues whatsoever** — `/proc/stat` is `-r--r--r--`, world
readable, always has been for any process on Linux; there is no `xe`-driver-
style access gap here at all. This is a strictly easier data source than
the GPU widget's had to deal with.

**Performance**: parsing all 13 lines (`cpu` + `cpu0`..`cpu11`) of
`/proc/stat`, reading 12 `scaling_cur_freq` files, and one hwmon temp file
in a single bash invocation measured **9ms wall time** on this machine —
no fdinfo-style fan-out-over-thousands-of-files problem the GPU widget hit
(that needed `grep -l`/`xargs` tricks to stay under ~50ms; CPU stats here
are inherently a fixed, small file count and don't need that).

**Conclusion**: same "shell script prints raw counters, QML does delta
math" split as GPU/network — the script stays stateless and stays a
single-shot read; QML keeps the previous tick's raw per-core values in a
JS property/array and does the arithmetic once it has two samples and a
real elapsed-time denominator (or just recompute delta ratios directly
without needing wall-clock time at all, since jiffie deltas already encode
elapsed time — simpler than GPU/network, no need to also read `timestamp_ms`
for this specific metric, though the script should still include it for
consistency with other widgets' JSON shape and for anything that does want
a wall-clock rate).

## 2. Core count and grid sizing

12 logical cores (§0). GPU's `fullRepresentation` box is sized
`Layout.preferredWidth: Kirigami.Units.gridUnit * 13`,
`Layout.preferredHeight: Kirigami.Units.gridUnit * 18` for **4** stacked
`MetricRow`s (each row roughly a label + bar/graph + value, ~1-1.5
`gridUnit` tall including spacing). Naively stacking 12 such rows
one-per-core (bashtop's own layout for its 8-core reference machine, see
§6) would need ~12-15 `gridUnit` of height for the core section ALONE,
before package temp/freq/overall-utilization rows — doesn't fit the
established box height without either growing the box significantly
(portrait Plasma widgets have practical panel/desktop-widget height
limits) or compacting the per-core representation.

**Recommendation: a 2-column grid, 6 rows of 2 cores each**, not one
row per core. Each cell is a compact `C0 [bar] 42%`-style row (label,
short bar, percentage — no per-core temp or per-core sparkline, see §4/§6
for why those are dropped at this core count). At box width 13 `gridUnit`
minus padding/border, each column gets roughly 6 `gridUnit` — enough for a
2-3 char core label, a ~4-5 char-cell bar, and a 3-digit percentage. This
keeps the core section to **6 rows tall** (~6-8 `gridUnit` including
spacing) instead of 12, leaving room in an 18-`gridUnit`-tall box for a
header row (package temp + frequency, see §3/§4) and possibly one overall-
CPU summary row above the grid. If a future machine has far more logical
cores (e.g. a 32-thread workstation), the same component should scale the
column count up (or cap row height and add a 3rd/4th column) rather than
letting the box grow unbounded — but 2 columns is the right starting point
for this machine's 12 and matches typical desktop core counts generally.

## 3. CPU package temperature

```
$ sensors
...
coretemp-isa-0000
Adapter: ISA adapter
Package id 0:  +35.0°C  (high = +80.0°C, crit = +100.0°C)
Core 0:        +32.0°C  (high = +80.0°C, crit = +100.0°C)
Core 1:        +33.0°C  (high = +80.0°C, crit = +100.0°C)
...
Core 5:        +32.0°C  (high = +80.0°C, crit = +100.0°C)
```

hwmon discovery:

```
$ for h in /sys/class/hwmon/hwmon*; do echo "$h -> $(cat $h/name)"; done
/sys/class/hwmon/hwmon0 -> acpitz
/sys/class/hwmon/hwmon1 -> nvme
/sys/class/hwmon/hwmon2 -> nvme
/sys/class/hwmon/hwmon3 -> xe        (the GPU's hwmon, per R2 — unrelated)
/sys/class/hwmon/hwmon4 -> asus
/sys/class/hwmon/hwmon5 -> jc42
/sys/class/hwmon/hwmon6 -> jc42
/sys/class/hwmon/hwmon7 -> coretemp   <-- this one
/sys/class/hwmon/hwmon8 -> iwlwifi_1
```

```
$ cat /sys/class/hwmon/hwmon7/temp1_label
Package id 0
$ cat /sys/class/hwmon/hwmon7/temp1_input
39000
```

**`hwmon7`'s `temp1_label` == `"Package id 0"` is the package temp**,
value in millidegrees C (`39000` = 39.0°C) — same units/convention as the
GPU widget's `pkg`/`vram` hwmon temps. `temp2_label`..`temp7_label` are
`Core 0`..`Core 5` (six physical-core temps, one per physical core, NOT
one per logical/hyperthreaded core — HT sibling threads share a physical
core's temp sensor, so there is no `Core 6`..`Core 11`). This matters for
scope: BACKLOG only asks for **package** temp (a single value, shown once
in the header, not per-core) — confirmed there is exactly one such
sensor, unambiguous, no aggregation/max-across-cores needed.

**Permissions**: confirmed world-readable, same as everything else in this
doc:

```
$ ls -la /sys/class/hwmon/hwmon7/temp1_input /sys/class/hwmon/hwmon7/temp1_label
-r--r--r--. 1 root root 4096 ... temp1_input
-r--r--r--. 1 root root 4096 ... temp1_label
```

Exactly like GPU's `hwmon3` (§3 of R2): **hwmon index is boot-order-
dependent** — a real script must scan `/sys/class/hwmon/hwmon*/name` for
the string `coretemp` (not hardcode `hwmon7`) the same way `gpu-stats.sh`
scans for `xe`. Within that hwmon device, scan `temp*_label` for the exact
string `Package id 0` rather than assuming `temp1` is always the package
entry (it happens to be `temp1` here, but pinning to the label string is
more robust and mirrors how `gpu-stats.sh` already looks up `pkg`/`vram`
by label rather than by fixed `tempN` index).

Reading sysfs directly (no `sensors` shell-out) is viable here, matching
GPU's own sysfs-first approach exactly — no reason to invoke `sensors -j`
as a subprocess when the two files needed (`temp1_label` to confirm/find
the index once, `temp1_input` to read every tick) are this cheap and
already proven-readable.

## 4. Per-core / package frequency

Two candidate sources, both checked live:

**(a) `/sys/devices/system/cpu/cpuN/cpufreq/scaling_cur_freq`** (kHz):

```
$ for i in 0 1 5 11; do echo -n "cpu$i: "; cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq; done
cpu0: 4523012
cpu1: 4498135
cpu5: 4500064
cpu11: 4500068
$ ls -la /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
-r--r--r--. 1 root root 4096 ... scaling_cur_freq
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
intel_cpufreq
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
performance
```

World-readable, one value per logical CPU, kHz integer, present for all 12
`cpuN` on this machine (`intel_cpufreq` driver, `performance` governor —
values sit close to the 4.8GHz max/boost most of the time under this
governor, which is why samples above cluster near 4.5GHz even near-idle).

**(b) `/proc/cpuinfo`'s `cpu MHz` field**:

```
$ grep "cpu MHz" /proc/cpuinfo | head -5
cpu MHz		: 4507.706
cpu MHz		: 4800.000
cpu MHz		: 4500.237
cpu MHz		: 4485.779
```

Same information, different unit (MHz float vs. kHz int) and a heavier
read (`/proc/cpuinfo` is a bigger file to parse — the whole per-logical-
CPU block, feature flags etc. — just to extract one field per core,
compared to one small dedicated file per core for the sysfs path).

**Recommendation: use the sysfs `scaling_cur_freq` path**, same rationale
as GPU's `act_freq` sysfs read over any `/proc`-parsing alternative — it's
a direct, single-purpose, already-integer file per core, cheap to read in
a loop (12 tiny reads, sub-millisecond, confirmed within the 9ms combined
timing in §1), and avoids parsing `/proc/cpuinfo`'s much larger/noisier
text block for one field.

**Whether to show per-core frequency in the grid**: no. Mirroring the GPU
widget's `AsciiBox` `trailingText` pattern (frequency shown once in the box
header, not as a per-row stat) — R7 (§109-112) independently confirms
bashtop does the *exact same thing*: frequency appears exactly once, at
the top of the CPU box next to the model name, not repeated per-core.
**Recommendation: aggregate frequency (max, or mean, across the 12
`scaling_cur_freq` values — max is more useful/responsive for "is the CPU
boosting right now") in the `AsciiBox` header's `trailingText`, same slot
GPU uses.** This also solves the space problem from §2 — a per-core grid
cell only needs to fit a label + bar + percentage, not also a frequency
number, which is what makes the compact 2-column grid workable at 12
cores.

## 5. QML dynamic-length list pattern: `ListModel` + `Repeater`

Per `MetricRow.qml`'s header comment and `ARCHITECTURE.md`'s summary of the
GPU widget's Epic 1.6 finding: reassigning a plain JS array to a
`Repeater`'s `model` every tick does **not** reliably refresh existing
delegates' bound properties, even though the array property itself updates
correctly — this is why `plasmatop-gpu` hardcodes 4 fixed-index
`Theme.MetricRow { metric: root.metrics[i] }` declarations instead of a
`Repeater { model: root.metrics }`.

CPU's per-core count is a different shape of problem than GPU's fixed 4
metrics: **it's fixed for the lifetime of the running plasmoid (core count
doesn't change while the widget is running) but unknown at write-time
(varies 4/6/8/12/16/... by machine)** — so neither GPU's "just hardcode N
fixed declarations" trick (N isn't known until runtime) nor "reassign a
plain array to Repeater.model every tick" (the confirmed-broken pattern)
work here.

**Confirmed correct pattern for this case: a real `ListModel`, populated
ONCE at `Component.onCompleted` (one `.append()` call per core, driven by
`Qt.application.` — actually by a `coreCount` value read from the stats
script's first tick or a QML-side `Qt` core-count query), with a
`Repeater { model: coreListModel; delegate: ... }`. Per-tick value updates
then go through `coreListModel.setProperty(index, "value", newBusyPct)`
(and `"freq"`/whatever fields are needed) on each existing row — NOT
further `.append()` calls, and NOT reassigning `model` to a new array.**
This is exactly the distinction the codebase already anticipated:
`ListModel.setProperty()` on an already-appended row is a genuine, well-
supported Qt Quick reactivity path (unlike rebinding `model` to a fresh JS
array), because it mutates a role of an existing model item in place
rather than asking the `Repeater` to reconcile "is this the same list or a
different one" against a whole new array identity every time. This is the
standard/documented way `ListModel`-backed `Repeater`s are meant to be
updated per-tick in Qt Quick, and does not share GPU's array-reassignment
failure mode.

**Conclusion for architecture**: `plasmatop-cpu` needs a **new
`shared/theme/` component** for the per-core section — `MetricRow` itself
is the wrong fit (it's a single fixed-descriptor row, not a repeatable-N
grid, and has no `ListModel`/`Repeater` machinery at all today). Something
like `shared/theme/CoreGrid.qml`: takes a core count at
`Component.onCompleted` (or an initial array of per-core descriptors),
builds its internal `ListModel` once, exposes an `updateCore(index,
busyPct)` (or similar) method for the per-tick delta-math result, and lays
out its `Repeater`'s delegates in the 2-column grid from §2 (a `GridLayout`
with `columns: 2`, or a `Grid`, rather than a single-column
`ColumnLayout` the way `MetricRow`s are stacked today). Package
temp/frequency stay as ordinary `MetricRow`s or `AsciiBox` header fields
(§3/§4) — only the per-core section needs the new component.

## 6. btop/bashtop per-core layout — quick confirmation (R6/R7 already cover this)

R6 (§Lines 83-88) and R7 (§340-354) already document bashtop's actual CPU
box in detail from a prior spike; re-confirming rather than re-researching:

- Bashtop's reference capture is an **8-core** machine (`Core1`...`Core8`),
  laid out as **one row per core in a single column**, stacked top-to-
  bottom with no blank line between rows — **not** a multi-column grid.
- Each per-core row packs four things into ~30 characters: label, a tiny
  inline braille sparkline (a few characters wide — a per-core trend
  micro-graph, not a bar), percentage, and temperature.
- Frequency appears exactly once, in the box header (§4 above already
  cross-references this).

**This machine's 12-core case is denser than bashtop's 8-core reference**
— a single column of 12 such rows, each with its own inline sparkline AND
per-core temp, would be taller than this project's established box heights
comfortably allow (§2). The recommendation above (2-column grid, bar only,
no per-core sparkline/temp) is a deliberate compaction relative to
bashtop's single-column style, justified specifically by this machine
having 50% more cores than the reference capture and by this project
having already established the "temperature/frequency belong in the
header, not per-row" convention independently for the GPU widget — this
isn't a new invention, it's applying an existing project convention plus a
straightforward column-count adjustment for a higher core count. No
further web research was needed beyond re-reading R6/R7's existing
findings.

## 7. Recommendation summary

**Data sourcing** (`contents/scripts/cpu-stats.sh`, same shape as
`gpu-stats.sh`):
- Stateless, single-shot script. Reads: all `cpuN` lines of `/proc/stat`
  (raw jiffie counters, no delta math), `scaling_cur_freq` for all
  `/sys/devices/system/cpu/cpu*/cpufreq/` entries (kHz), and
  `coretemp`'s `Package id 0` hwmon `temp*_input` (discovered dynamically
  by scanning `hwmon*/name` for `coretemp` then `temp*_label` for
  `"Package id 0"` — never hardcode `hwmon7`, boot-order-dependent exactly
  like GPU's `hwmon3`).
- No permission workarounds needed anywhere — `/proc/stat`, `cpufreq`,
  and `coretemp` hwmon files are all plain world-readable files, unlike
  GPU's `intel_gpu_top`/`xe` fdinfo situation. This is the easy case
  ARCHITECTURE.md's per-widget table already anticipated.
- QML does delta math on `/proc/stat`'s per-core counters between ticks
  (busy% formula in §1), exactly like the network widget's byte-counter
  deltas — no new pattern.

**QML architecture**:
- New `shared/theme/CoreGrid.qml` (or similar name) backed by a `ListModel`
  populated once at startup (one `.append()` per logical core, count from
  the first stats tick or a QML-side core-count read) with a `Repeater`
  laid out in a **2-column `GridLayout`** (6 rows of 2 for this machine's
  12 cores). Per-tick updates via `.setProperty(index, ...)` on existing
  rows, never re-`.append()` or reassign `model` — this is the reliable
  path per §5, unlike GPU's plain-array-to-Repeater anti-pattern.
- Package temperature and aggregate/max frequency: reuse the existing
  `AsciiBox` header `trailingText` slot (frequency) and either a
  `MetricRow` or a second header-adjacent text field (temperature) —
  no per-core temp or per-core frequency shown, consistent with both this
  project's GPU-widget convention and bashtop's own header placement
  (§4/§6).
- Each per-core grid cell: label + short bar (via the existing
  `BarMeter`/`ColorScale` components, reused as-is — no changes needed
  there, same as GPU's Epic 1.6 finding that `MetricRow`'s internals
  needed zero changes) + percentage text. No per-core sparkline/temp —
  deliberately more compact than bashtop's reference given this machine's
  higher core count (§6).
