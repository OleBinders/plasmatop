# Architecture — plasmatop

Synthesized 2026-09-13 from `research/r1-plasmoid-dev.md`, `r2-gpu-telemetry.md`,
`r3-tui-aesthetic-rendering.md`. Read those for full detail/evidence; this
doc is the decisions, not the research.

## Package layout (applies to all 5 widgets)

```
widgets/plasmatop-<name>/
├── metadata.json
└── contents/
    ├── ui/
    │   ├── main.qml              # PlasmoidItem root (mandatory in Plasma 6)
    │   └── ConfigGeneral.qml     # config form, if the widget has settings
    ├── config/
    │   ├── main.xml              # KConfigXT schema
    │   └── config.qml            # ConfigModel/ConfigCategory
    └── scripts/
        └── <name>-stats.sh       # data-source helper, see "Data sourcing" below
```

`metadata.json` required fields: `KPlugin.{Id,Name,Description,Icon,Category,Version}`,
`"KPackageStructure": "Plasma/Applet"`, `"X-Plasma-API-Minimum-Version": "6.0"`
(mandatory — its absence hides the widget from Add Widgets).

**Widget IDs**: `com.olebinders.plasmatop.<name>` (cpu/mem/net/disk/gpu) —
no owned domain, so using the author's name as namespace, matching common
practice for unpublished/personal KDE plasmoids. Install target:
`~/.local/share/plasma/plasmoids/<Id>/`.

**QML import rules** (Plasma 6.7, unversioned imports — see R1 §2 for the
full deprecated-from-Plasma-5 list): `org.kde.plasma.plasmoid` (`PlasmoidItem`
root), `org.kde.plasma.core`, `org.kde.plasma.components`, `org.kde.kirigami`,
`org.kde.ksvg`, `org.kde.plasma.plasma5support` (data source), `org.kde.kcmutils`
(config page container).

## Data sourcing — one pattern for all 5 widgets

**`Plasma5Support.DataSource` (executable engine) + QML `Timer`**, running a
small **bundled shell script per widget** (`contents/scripts/<name>-stats.sh`),
not a system CLI tool. This reconciles R1 (consistency argument for
`Plasma5Support.DataSource` across all five widgets) with R2 (don't depend on
`intel_gpu_top`/`gputop` — broken/unparseable on this machine's `xe` driver):
instead of shelling to an external tool whose output format we don't control,
each widget ships its own tiny script that reads `/proc` and `/sys` directly
and prints one JSON line to stdout. QML parses it with `JSON.parse(data.stdout)`
in `onNewData` — identical integration code shape across all five widgets.

```qml
import org.kde.plasma.plasma5support as Plasma5Support

Plasma5Support.DataSource {
    id: statsSource
    engine: "executable"
    connectedSources: []
    onNewData: (sourceName, data) => {
        const stats = JSON.parse(data["stdout"])
        // update properties, feed BarMeter/Sparkline
        disconnectSource(sourceName)
    }
}
Timer {
    interval: Plasmoid.configuration.pollInterval * 1000
    running: true; repeat: true
    onTriggered: statsSource.connectSource(
        Qt.resolvedUrl("scripts/gpu-stats.sh").toString().replace("file://", ""))
}
```

**Cumulative-counter deltas (network bytes, GPU busy-time, GPU energy) are
computed in QML, not in the script.** The script is stateless — it prints raw
current counter values every invocation; the widget keeps the previous tick's
raw values in a JS property and divides by the actual elapsed time between
signals. This avoids inventing a state file per widget and keeps each script
a simple, testable, single-shot read.

**Known architectural risk (flagged, not blocking):** `Plasma5Support` is
described by KDE as a porting/compat shim, not a committed long-term Plasma 6
API. Acceptable for now — no first-party replacement exists yet for
shell/file polling — but if Plasma ships a native replacement, revisit.

### Per-widget data sources

| Widget | Script reads | Notes |
|---|---|---|
| `plasmatop-cpu` | `/proc/stat` (usage), `/proc/cpuinfo` or `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` (freq), `sensors -j` or hwmon for package temp | `/proc/stat` deltas computed in QML like network |
| `plasmatop-mem` | `/proc/meminfo` | Direct values, no delta math needed |
| `plasmatop-net` | `/proc/net/dev` | Raw byte counters per interface; QML computes throughput from deltas |
| `plasmatop-disk` | `/proc/diskstats` (throughput), `statvfs`/`df`-equivalent via script (usage %) | Per-mount usage is a snapshot; throughput needs delta math |
| `plasmatop-gpu` | sysfs `tile0/gt0/freq0/act_freq`, hwmon `temp2_input`/`temp3_input`, hwmon `energy1_input`, `/proc/*/fdinfo` (busy-time deltas) | See below — no VRAM used/total in v1 (no sysfs source exists; deferred, see Epic 1 backlog) |

**GPU specifics** (the hard case, per R2): script must **dynamically
discover** the card (`/sys/class/drm/card*` whose `device/driver` symlink
resolves to `xe`) and hwmon index (scan `hwmon*/name` for `xe`) — never
hardcode `card1`/`hwmon3`, both are boot-order-dependent. Busy % comes from
summing `/proc/*/fdinfo` DRM engine busy-time counters for processes using
this GPU's device, delta'd between ticks in QML (same technique nvtop and
`gputop` use internally — see R2 §5). Power draw comes from the
`energy1_input` cumulative-microjoule counter, delta'd the same way. No
sysfs source exists for GPU busy% or VRAM as a direct percentage/total —
confirmed absent on the `xe` driver.

## Shared theme components (`shared/theme/`)

Per R3, matched to what real Plasma 6 TUI-style widgets (knvtop, konky)
converge on independently:

- **`ColorScale.qml`** — singleton/component with `colorForValue(value, max)`
  and threshold properties (`goodMax: 0.5`, `warnMax: 0.8` defaults),
  green→yellow→red interpolation. Single source of truth for "what does
  yellow mean" across all five widgets.
- **`BarMeter.qml`** — stacked `Rectangle`s (background track + value-bound
  fill), gradient stops driven by `ColorScale`. **No `Canvas`** — a bound
  `Rectangle.width`/`gradient` is strictly cheaper for a solid bar and this
  is the only component type used for CPU/Mem/GPU/VRAM/Disk % meters.
- **`Sparkline.qml`** — braille-character rolling history graph (superseded
  the original `Canvas`-based version; see `research/r4-terminal-graph-
  rendering.md` for why). Renders the WHOLE dot grid as one `Text` item
  with one `Text.StyledText` string (never one `Text` item per glyph via a
  `Repeater` — a hard rule, see `AGENTS.md`). Re-renders only from
  `pushValue()`/`setHistory()` (i.e. only on a real data tick), never from
  a timer or animation loop — the same battery-drain rule that used to be
  phrased around `Canvas.requestPaint()` still applies to calling
  `_render()`. As of the GPU metric-row refactor (below), also colors each
  historical sample by its OWN value (not just the latest sample) via
  per-column `<font color>` runs inside that same single string.
- **`AsciiBox.qml`** — Unicode box-drawing frame, title inset into the top
  border. Supports an optional `trailingText`/`trailingColor` pair
  (right-aligned in that same top border row, before the closing corner)
  for a piece of header-level identity info like a frequency readout —
  added for `plasmatop-gpu`'s R6 layout pass, `""` (default) is a no-op
  for any existing usage.
- **`MetricRow.qml`** — generic, config-driven "one row per metric"
  component; see its own file header for the full descriptor-shape doc.
  Added during `plasmatop-gpu`'s Epic 1.6 refactor (R5/R6) specifically so
  the next widget (`plasmatop-cpu`) doesn't have to hand-write per-metric
  `Label`+`BarMeter`/`Sparkline` blocks the way `plasmatop-gpu` originally
  did. Summary for a new widget's `main.qml`:
  - Build a plain JS array of metric descriptor objects (`{key, label,
    style: "bar"|"graph"|"text", value, maxValue, unit, decimals, goodMax,
    warnMax, history, displayOverride}`) from whatever properties your
    delta-math already populates.
  - Declare one `Theme.MetricRow { metric: root.metrics[i] }` per
    descriptor, **by fixed index, not via `Repeater { model: ... }`** —
    found empirically that Repeater does not reliably refresh an existing
    delegate's `modelData` when a new same-length JS array is reassigned
    to `model` every tick, even though the property value itself updates
    correctly (see `MetricRow.qml`'s header for the full diagnosis). A
    genuinely variable-length list (e.g. per-core CPU rows) needs a real
    `ListModel` behind its `Repeater` instead, not a reassigned array.
  - For a "graph"-style row, call `someRow.pushValue(v)` on every new
    sample from your data handler (same pattern as the old direct
    `sparkline.pushValue()` call, just routed through the row).
  - `BarMeter`/`Sparkline`/`ColorScale` themselves needed ZERO changes to
    support this (per R5) — `MetricRow` is a thin composition layer over
    them, using a `Loader` internally so only the ONE style actually in
    use per row gets instantiated (not all three, toggled by `visible`).
- **Per-metric configurable thresholds**: `goodMax`/`warnMax` were
  originally hardcoded `readonly property real` constants per metric in
  `main.qml`. `plasmatop-gpu` now exposes these as KConfigXT `Double`
  entries (one good/warn pair per metric that meaningfully varies by user
  preference — not necessarily every metric an widget shows) wired through
  to each metric descriptor's `goodMax`/`warnMax` fields, with `||
  <old default>` fallbacks for the async-config-load race (same pattern as
  every other `Plasmoid.configuration.*` read in this project). Good/warn/
  bad *colors* remain one shared set per widget (not per-metric) — only
  the threshold *values* are per-metric.
- **Font**: `font.family` fallback list ending in generic `"monospace"`
  (resolves to the user's system monospace via fontconfig) for everything
  except `Sparkline`'s braille glyphs, which need a bundled font with real
  braille coverage (`shared/theme/fonts/AdwaitaMono-Regular.ttf` — see R4).

## Dev / test workflow

- `kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-<name>` (first
  install) / `-u` (upgrade after changes) / `-r <Id>` (remove) / `-l` (list).
- Fast-iteration option: `plasma-sdk` (provides `plasmoidviewer`, standalone
  preview without touching the live panel) is available via `sudo dnf install
  plasma-sdk` but **requires the product owner to run it themselves** — this
  machine has no passwordless sudo, so an agent cannot run it non-interactively.
  Not a blocker: `kpackagetool6 -u` + re-adding the widget (or
  `plasmashell --replace` for a full reload) works without it, just slower.
- Per `AGENTS.md`: a widget isn't "done" until installed via `kpackagetool6`
  and actually rendered on this machine's panel, values cross-checked live.
  **Cross-check GPU values against `nvtop` and `sensors`, not
  `intel_gpu_top`** (confirmed non-functional against this machine's `xe`
  driver — R2 §4) or `gputop` (no machine-readable output to diff against
  easily, but fine as a manual sanity check).

## Sprint 1 scope decision

Epic 1 (`plasmatop-gpu`) backlog lists VRAM used/total and a full config
panel as separate stories. **Sprint 1 MVP** = utilization %, temperature,
frequency, power draw, with basic poll-interval config — the four metrics
with a clean direct data path. VRAM used/total has no sysfs source on `xe`
(R2 §2) and would need either a hardcoded capacity fallback or a small
ioctl-based helper; deferred to its own story rather than blocking the
GPU widget's first working version.
