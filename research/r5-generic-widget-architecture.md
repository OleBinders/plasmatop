# R5 — Generic configurable-widget architecture: is it viable for plasmatop?

Researched 2026-09-13, in response to the Epic 1.6 architecture question
(BACKLOG.md): should plasmatop pivot from 5 hand-built widgets to one
generic, user-configurable widget package (like `org.kde.plasma.systemmonitor.*`),
placed as multiple instances? Everything below was confirmed by reading the
actual installed files on this machine (Fedora 44, Plasma 6.7.5,
`ksystemstats-6.7.5-1.fc44`) and querying the live `ksystemstats` D-Bus
service — not inferred from documentation.

## 1. How the built-in `org.kde.plasma.systemmonitor.*` widgets actually work

**They are not 6 separately-coded plasmoids.** Confirmed by listing package
contents directly:

```
org.kde.plasma.systemmonitor/            <- the real, only, implementation
├── contents/config/{main.xml,config.qml}
└── contents/ui/{main.qml,CompactRepresentation.qml,FullRepresentation.qml,config/*}

org.kde.plasma.systemmonitor.cpu/        <- NOT a separate implementation
├── contents/config/faceproperties       <- the ONLY content file besides metadata.json
└── metadata.json

org.kde.plasma.systemmonitor.net/        <- same shape as .cpu
├── contents/config/faceproperties
└── metadata.json
```

`org.kde.plasma.systemmonitor.cpu/metadata.json` carries
`"X-Plasma-RootPath": "org.kde.plasma.systemmonitor"` — this tells Plasma
"when you instantiate the `.cpu` plugin ID, actually load `main.qml` etc.
from the `org.kde.plasma.systemmonitor` package on disk." The `.cpu`
package contributes *only* a `faceproperties` preset file (plain KConfig
text, not QML):

```ini
[Config]
chartFace=org.kde.ksysguard.piechart
highPrioritySensorIds=["cpu/all/usage"]
totalSensors=["cpu/all/usage"]
lowPrioritySensorIds=["cpu/all/cpuCount","cpu/all/coreCount"]
[FaceConfig]
rangeAuto=false
rangeFrom=0
rangeTo=100
```

So "5 separate widgets, one generic implementation" in KDE's own version of
this idea is achieved via **one QML/C++ package plus N tiny metadata+preset
files that alias distinct `KPlugin.Id`s onto it and seed different default
sensor selections** — not N QML packages sharing a component library. There
is no `org.kde.plasma.systemmonitor.gpu` preset installed on this machine at
all (confirmed absent from `/usr/share/plasma/plasmoids/`) — KDE doesn't
ship a GPU preset, consistent with §2 below.

**How the config UI actually implements "pick sensors + pick display
style"** — read `contents/ui/config/{ConfigSensors,ConfigAppearance}.qml`
directly: both are ~30-line QML shells that do nothing but reparent a
**C++-provided `QQuickItem`** into themselves:

```qml
readonly property Item configUi: Plasmoid.faceController.sensorsConfigUi
...
children: root.configUi
```

`Plasmoid.faceController` (`SensorFaceController`) and its
`sensorsConfigUi`/`appearanceConfigUi` are compiled C++ objects from the
`plasma-systemmonitor` package (`rpm -qf` confirms), not portable QML.
The actual sensor browser (walk the whole ksystemstats sensor tree,
multi-select, assign per-sensor colors, put some sensors in
`textOnlySensorIds` for plain-text-only display) lives in that C++ layer.

**"Bar/graph/number" style is a plugin choice, not a per-metric dropdown.**
Grepping the installed files found five interchangeable "chart face"
plugins: `org.kde.ksysguard.{barchart,linechart,horizontalbars,piechart,
textonly}`, each its own QML+C++ plugin under
`/usr/lib64/qt6/qml/org/kde/ksysguard/`. A widget instance picks ONE
`chartFace` for its primary display (`config/main.xml`'s `chartFace` String
entry) plus an independent `textOnlySensorIds` StringList for sensors shown
as plain text instead of drawn into that chart. It is *not* "each selected
metric gets its own bar-or-graph-or-text choice" — it's coarser: one chart
type for the widget, with a text-only escape hatch per sensor.

**Bottom line for §1's question:** genericity here is bought with real,
non-trivial C++ infrastructure (a sensor-tree model, a pluggable chart-face
system, a generic sensor-picker dialog) that lives in the `plasma-systemmonitor`
package upstream — multiple compiled `.so` plugins
(`libSensorFacesplugin`, `libPlasmaSystemMonitorPageplugin`,
`libPlasmaSystemMonitorTableplugin`, `libFormatterplugin`, `libSensorsplugin`,
`libprocesscoreplugin`). Reproducing the *UI mechanism* KDE uses (not just
the visual idea) in a QML-only Plasma widget project is a much bigger lift
than "add a config option" — it is closer to "build a miniature version of
`plasma-systemmonitor` itself."

## 2. Does the sensors framework expose anything for the Arc B580? (the crux)

**Yes and no — and the "no" has a specific, reproducible cause, not vague
patchiness.**

Confirmed `ksystemstats` is running (`systemctl --user status
plasma-ksystemstats.service` → active) and queried it live over D-Bus
(`org.kde.ksystemstats1`, method `allSensors`, no `qdbus` on this machine so
used `busctl --user call ... allSensors`):

```
"gpu"  "GPU"  "gpu/all"  "gpu/all/totalVram"  "gpu/all/usage"  "gpu/all/usedVram"
"gpu/gpu0"  "gpu/gpu0/coreFrequency"  "gpu/gpu0/memoryFrequency"  "gpu/gpu0/name"
"gpu/gpu0/power"  "gpu/gpu0/temperature"  "gpu/gpu0/totalVram"  "gpu/gpu0/usage"
"gpu/gpu0/usedVram"  "gpu/gpu0/video"
```

This is **more sensor metadata than R1/R2 expected** — GPU utilization,
temperature, power, both clock domains, and (unlike plasmatop-gpu's own
data source) VRAM used/total are all declared as existing sensors.

But calling `sensorData` (after `subscribe`, with a 2s wait) on all of them
returns **every numeric sensor as `0`**, and `totalVram`/`usedVram` are
silently absent from the response entirely (declared in `allSensors`
metadata, never actually emitted). `gpu/gpu0/name` does resolve, but only to
the generic string `"GPU 1"`, not `"Arc B580"` — a further sign this is a
placeholder/never-actually-attached backend, not "attached but reporting
zero load."

**Root cause, found directly, not inferred:**
`journalctl --user -u plasma-ksystemstats.service` shows, from earlier
today:

```
ksystemstats[7250]: "Device directory \"/sys/bus/event_source/devices/i915_0000_03_00.0\" does not exist\n"
```

`ksystemstats_plugin_gpu.so` contains a `LinuxIntelGpu` class (confirmed via
`strings`) that shells out to `/usr/libexec/ksystemstats_intel_helper`
(owned by the `ksystemstats` RPM itself, i.e. this is upstream KDE code, not
a third-party plugin). Running that helper binary directly, as the normal
user, reproduces the exact same failure with no arguments:

```
$ /usr/libexec/ksystemstats_intel_helper
Device directory "/sys/bus/event_source/devices/i915" does not exist
```

`strings` on the helper shows references only to `i915` — never `xe`. This
machine's Arc B580 (Battlemage, `xe` kernel driver, per R2) exposes its perf
PMU device as `/sys/bus/event_source/devices/xe_0000_03_00.0` (confirmed
present via `ls /sys/bus/event_source/devices/`), a completely different
name the helper never looks for. So KDE's own Intel-GPU sensor backend is
**hardcoded to the legacy i915 perf-PMU interface** and has no code path for
`xe`-driver Intel GPUs at all — it isn't "patchy," it's a specific,
reproducible dead end for exactly the same reason `intel_gpu_top` was
already found to be a dead end in R2 (i915-vs-xe driver-generation split).
The sensor *declarations* (labels, min/max, units) still register — because
that part of the plugin doesn't need the helper to succeed — which is why
`allSensors` looks promising until you actually read live values.

**Corroborating: no `org.kde.plasma.systemmonitor.gpu` preset ships at
all** on this system (only `.cpu/.cpucore/.diskactivity/.diskusage/.memory/.net`
exist under `/usr/share/plasma/plasmoids/`). KDE doesn't ship a default GPU
widget preset, consistent with GPU sensor data being unreliable enough
project-wide that they don't build a canned "add this to your panel" config
around it.

**Verdict for §2: the native `org.kde.ksysguard.sensors`/ksystemstats
framework cannot drive a real GPU widget on this exact machine today.**
R1's "may or may not be adoptable" and R2's "patchy/vendor-dependent" hedges
are now confirmed as a hard no, with a specific root cause, for the widget
that is explicitly plasmatop's priority-one deliverable. Building the
"generic widget" pivot on top of this framework is not viable while GPU
remains in scope.

## 3. If not the native framework, what should plasmatop's generic
   mechanism look like?

Since `plasmatop-gpu` already proved a working data path (bundled script +
`Plasma5Support.DataSource` + QML delta math, per `ARCHITECTURE.md`), the
generic mechanism should be built on top of *that*, not on ksystemstats.

**Config schema shape**, per resource type, needed to let a user pick
metrics + style:

- A `visibleMetrics` `StringList` KConfigXT entry (metric keys, e.g.
  `["utilization","tempPkg","tempVram","freq","power"]` for GPU) — same
  "stringify a list into a KConfigXT StringList/String" trick R1 already
  found in the locally-installed `org.kde.olib.thermalmonitor`
  (`Plasmoid.configuration.sensors`), so this is a proven pattern already
  present on this machine, not a novel idea.
- A per-metric style entry — cleanest as one more StringList in a parallel
  `"key:style"` encoding (`bar`/`graph`/`text`), or a JSON-string entry
  (also an established KConfigXT workaround per R1) if per-metric threshold
  overrides need to travel with it too — `goodMax`/`warnMax` per metric,
  which Epic 1.6 already asks for and which the current `plasmatop-gpu`
  hardcodes as root `readonly property real` constants (`tempGoodMax:
  0.60`, `tempWarnMax: 0.85`, plus `0.6`/`0.85` inlined a second time on the
  utilization `BarMeter` in both compact and full representations).
- Each resource type's available-metrics list is inherently different in
  *shape*, not just count: GPU is flat (5 scalar metrics); CPU wants
  per-core arrays; network wants per-interface up/down pairs; disk wants
  per-mount usage plus throughput. A config UI that has to describe all of
  these uniformly is exactly the problem KDE solved with a real C++
  sensor-tree browser (§1) — not something to casually reinvent in an
  evening.

**Two candidate shapes, per the task's framing:**

- **(A) One plasmoid package, "resource type" dropdown, swaps which
  bundled script runs.** Rejected. It reproduces KDE's `X-Plasma-RootPath`
  trick but with all the per-resource-shape complexity (per-core arrays,
  per-interface pairs, per-mount lists) now living inside ONE widget's
  config UI and QML instead of being naturally scoped by which package is
  installed. It also breaks the packaging-time clarity `ARCHITECTURE.md`
  already established (`contents/scripts/<name>-stats.sh` per widget) by
  turning "which script runs" into a runtime config choice instead of a
  install-time one, for zero benefit — the product owner explicitly still
  wants separate placed instances (GPU widget on one panel, CPU on
  another), so nothing is saved by merging the packages themselves.

- **(B) Keep 5 separate plasmoid packages, extract a shared, generic
  "configurable metric list" QML component into `shared/theme/`.**
  Recommended. Concretely: a new `shared/theme/MetricRow.qml` (or similar)
  that takes a metric descriptor (`{key, label, value, maxValue, style,
  goodMax, warnMax, colors}`) and renders a `BarMeter`, `Sparkline`, or
  plain `Text` based on `style` — this is a thin wrapper, since
  `BarMeter`/`Sparkline`/`ColorScale` are *already* fully metric-agnostic
  (their public API is `value`/`maxValue`/`goodMax`/`warnMax`/colors —
  nothing GPU-specific leaked into them at all, confirmed reading all three
  files in full). Each widget's own `main.qml` keeps its own
  `applyStats()`/delta-math (the actually hard, resource-specific part) and
  just builds an array of metric descriptors from it, plus a shared
  `ConfigMetricsList.qml` form component (checkboxes + style combo box per
  metric, reusable Kirigami.FormLayout pattern) that each widget's
  `ConfigGeneral.qml`-equivalent instantiates with its own resource-specific
  metric list. Metric lists stay naturally scoped per resource (a GPU
  config never has to pretend it might show "per-core" anything), while the
  actual code that gets duplicated per new widget today — the hand-written,
  copy-pasted `Label` + `BarMeter` block repeated 3-4x per widget with
  every color/threshold property spelled out each time (see `main.qml`
  lines 342-419) — collapses to one shared, data-driven component.

## 4. Migration cost estimate for `plasmatop-gpu`

Read `widgets/plasmatop-gpu/contents/ui/main.qml` (450 lines),
`ConfigGeneral.qml`, `config/main.xml`, `contents/scripts/gpu-stats.sh`, and
all of `shared/theme/{BarMeter,Sparkline,ColorScale}.qml` in full.

**What does NOT need to change** (the majority of the widget's real
engineering value):
- `gpu-stats.sh` — dynamic `xe` card/hwmon discovery, fdinfo dedup-by-
  `drm-client-id` scan, stateless JSON output. Zero changes.
- `applyStats()`/`engineBusyPercent()` in `main.qml` — the delta-math for
  utilization %/power watts from raw counters. Zero changes; these just
  need to keep populating whatever properties feed the new metric
  descriptor array.
- `BarMeter.qml`/`Sparkline.qml`/`ColorScale.qml` — already fully
  metric-agnostic (`value`/`maxValue`/`goodMax`/`warnMax`/color properties
  only, no GPU-specific assumptions anywhere in any of the three files).
  Zero changes needed to adopt shape B.

**What would need to change** (moderate, mechanical-to-medium):
- Build the metric-descriptor array (5 entries: utilization/tempPkg/
  tempVram/freq/power) from the existing `root.utilizationPercent`/
  `tempPkgC`/etc. properties — small, ~30-50 lines.
- New shared `MetricRow.qml`-equivalent component in `shared/theme/` that
  replaces the hand-written per-metric `QQC2.Label` + `Theme.BarMeter` (or
  `Theme.Sparkline`) blocks currently repeated with full property lists
  each time in `fullRepresentation` (lines ~342-443) — genuinely new
  shared code, ~60-100 lines, straightforward given BarMeter/Sparkline's
  existing clean API.
- Extend `config/main.xml` with `visibleMetrics`/per-metric style+threshold
  entries, additive to the existing schema (poll interval + 5 colors stay
  as-is) — ~20-30 lines of KConfigXT.
- Extend `ConfigGeneral.qml` with a metric-picker section (visibility
  checkbox + style combo per metric) — genuinely new UI, ~80-150 lines,
  though it can copy the existing color-picker `RowLayout` pattern already
  used 5 times in that file.
- **Design decision, not just code**: `compactRepresentation` (panel view)
  today always shows utilization only, hardcoded. Under a
  multi-metric-visible model, the panel needs a rule for which ONE metric
  it shows (first visible one? a separate "compact metric" config?) — the
  built-in `.cpu`/`.net` widgets sidestep this by being single-metric by
  design, so there's no existing pattern to copy; this needs a real (small)
  decision, not just refactoring.

**Verdict: a moderate, well-scoped refactor — not a rewrite.** Realistic
scope is on the order of 150-300 changed/added lines across `main.qml` +
`config/main.xml` + `ConfigGeneral.qml`, plus one new shared component,
because the two hardest parts of the widget (GPU data sourcing/delta math,
and the visual meter/graph primitives) are already resource-agnostic and
require zero changes. This is coder-agent-afternoon-sized work per
`AGENTS.md`'s existing role split, not a multi-day rebuild.

## Recommendation

**Pivot now, but only to shape (B) — separate packages sharing a generic,
config-driven metric-list component — not to the native ksystemstats
framework and not to a single resource-type-dropdown package.**

Justification, against what was actually found, not the idea in the
abstract:

1. **The native framework is a confirmed non-starter for GPU on this exact
   machine**, with a specific, reproducible root cause (KDE's own
   `ksystemstats_intel_helper` hardcodes the legacy i915 perf-PMU device
   path and has no `xe`-driver code path at all — same class of bug that
   already killed `intel_gpu_top` in R2, now independently confirmed inside
   KDE's own sensor daemon via live D-Bus queries and direct execution of
   the helper binary). Since GPU is explicitly plasmatop's priority-one,
   actual-capability-gap widget, adopting the framework wholesale is ruled
   out regardless of how appealing its config UI is.
2. **Replicating the native framework's UI mechanism is a much bigger lift
   than it looks from the outside** — it's backed by multiple compiled C++
   Qt plugins (a sensor-tree model, five interchangeable chart-face
   plugins, a generic sensor-picker dialog) that live in the upstream
   `plasma-systemmonitor` package, not portable QML. Not worth building an
   equivalent from scratch for a personal 5-widget project.
3. **Shape (B) is cheap right now specifically because only `plasmatop-gpu`
   exists.** The migration cost analysis above shows the retrofit is
   moderate specifically because it only touches the "wire up N hardcoded
   metric blocks by hand" layer — every future widget (CPU/mem/net/disk)
   avoids ever writing that layer at all if the generic component exists
   first. Sequencing this before Epic 2 means CPU is built once, correctly,
   instead of built hardcoded now and refactored later. The BACKLOG's own
   framing ("now is the cheapest point to pivot if we're going to") is
   confirmed by this analysis, not just asserted.
4. **The Epic 1.6 items already held pending this research** (configurable
   per-metric thresholds, dropping the redundant utilization
   BarMeter+Sparkline in favor of text readouts) are direct, natural
   consequences of shape (B)'s metric-descriptor/style model — implementing
   them under the current hardcoded architecture and then re-implementing
   them again under a generic one would be wasted work.
5. **Shape (A) (one package, resource-type dropdown) is explicitly not
   recommended** — it doesn't reduce the number of things a user installs
   any further than shape (B) (the product owner still wants separate
   placed instances), while making the actual metric-shape complexity
   (per-core, per-interface, per-mount, all different from GPU's flat
   5-scalar case) harder to manage by cramming it into one widget's runtime
   config instead of leaving it naturally scoped per package, and it
   discards the current architecture's clean "one script per widget"
   packaging-time story for no corresponding benefit.

## Sources / evidence trail

- Live D-Bus queries against `org.kde.ksystemstats1` (`busctl --user call
  ... allSensors`, `subscribe`, `sensorData`) on this machine, 2026-09-13.
- `journalctl --user -u plasma-ksystemstats.service` (real timestamped error
  about the missing `i915_0000_03_00.0` PMU device).
- Direct execution of `/usr/libexec/ksystemstats_intel_helper` as the normal
  user (reproduces the same error standalone).
- `strings`/`rpm -qf` against `ksystemstats_plugin_gpu.so` and the intel
  helper binary.
- Full reads of `/usr/share/plasma/plasmoids/org.kde.plasma.systemmonitor/`
  (`main.qml`, `config/{main.xml,config.qml}`,
  `ui/config/{ConfigSensors,ConfigAppearance}.qml`) and the `.cpu`/`.net`
  preset packages.
- Full reads of `widgets/plasmatop-gpu/contents/{ui/main.qml,
  ui/ConfigGeneral.qml, config/main.xml, scripts/gpu-stats.sh}` and all of
  `shared/theme/{BarMeter,Sparkline,ColorScale}.qml`.
- `research/r1-plasmoid-dev.md` §3 (Option C) and `research/r2-gpu-telemetry.md`
  §1-§6, both re-confirmed and sharpened by this spike rather than
  superseded.
