# Customizing plasmatop widgets

Each widget has its own config dialog (right-click the widget → **Configure
plasmatop &lt;name&gt;…**). The five widgets share a common set of controls, but
their good/warn/bad thresholds are metric-specific and were not made
identical across widgets — this page documents each widget's real field
names, ranges, and defaults as they exist in
`widgets/plasmatop-<name>/contents/config/main.xml`, not an assumed shared
schema.

## The good/warn/bad threshold concept

Most meters (bar meters and graphs) are colored on a green → yellow → red
scale based on how far a value sits along its own 0–100% scale — e.g.
utilization's own 0–100%, or a temperature's own 0–100°C range. Each such
metric has a **"good up to"** and **"warn up to"** pair, both expressed in
the config dialog as whole percentages:

- Below "good up to": green (good).
- Between "good up to" and "warn up to": yellow (warning).
- Above "warn up to": red (bad).

These are stored internally as 0.0–1.0 fractions (e.g. `0.6` = "good up to
60%") but the config dialog presents them as 0–100 spinboxes.

## Common to all five widgets

| Control | Field name | Range | Default |
|---|---|---|---|
| Poll interval | `pollInterval` | widget-specific, see below | widget-specific |
| Background opacity (widget's frame fill) | `backgroundOpacity` | 0.0–1.0 (shown as 0–100%) | `0.0` (fully transparent) |
| Meter/graph background color | `meterBackgroundColor` | any color, alpha-capable | `#404040` |
| Good meter color | `meterGoodColor` | any color | `#77ca9b` |
| Warning meter color | `meterWarnColor` | any color | `#cbc06c` |
| Bad meter color | `meterBadColor` | any color | `#dc4c4c` |
| Text color | `fontColor` | any color | `#eeeeee` |
| ASCII frame/border color | `frameColor` | any color | `#606060` |

`meterBackgroundColor` carries an alpha channel (the color picker supports
transparency), so you can dial in both hue and see-through-ness for the bar
tracks and graph backgrounds in one control.

Poll interval is a spinbox in seconds with 0.1s resolution, but its allowed
range differs by widget (see each section below) — it's not a shared
0.5–10.0s range across all five.

## plasmatop GPU

Shows utilization (graph, peak) mirrored against VRAM used % (graph,
valley), plus package temperature and VRAM temperature as bar rows, and
power draw as a plain-text readout (no threshold — no natural good/bad
scale for watts).

- Poll interval: 0.5–10.0s, default **1.5s**.
- Threshold pairs (each "good up to" / "warn up to", default 0.6 / 0.85 —
  i.e. green under 60%, yellow 60–85%, red above 85%):
  - `utilGoodMax` / `utilWarnMax` — GPU utilization.
  - `tempPkgGoodMax` / `tempPkgWarnMax` — package temperature.
  - `tempVramGoodMax` / `tempVramWarnMax` — VRAM temperature.
  - `vramGoodMax` / `vramWarnMax` — VRAM used %.
- `vramTotalGib` (10–25600, default **11.93**): total VRAM capacity in GiB.
  This is a manual fallback, not auto-detected — there is no sysfs source
  for total VRAM capacity on the Intel Xe driver, so this figure has to be
  typed in. The default matches the reference machine's Arc B580; if you
  install this on different GPU hardware, change it to your card's actual
  VRAM size or the used-% readout will be wrong.

## plasmatop CPU

Full (desktop) view shows a per-core grid (one bar per logical core) plus a
package-temperature bar row. The compact panel view collapses this to a
single aggregate utilization bar — you don't get the per-core grid in the
panel.

- Poll interval: 0.5–10.0s, default **1.5s**.
- Threshold pairs:
  - `utilGoodMax` / `utilWarnMax` (default 0.6 / 0.85) — applies to
    **every** per-core bar via one shared pair, not a separate pair per
    core.
  - `tempGoodMax` / `tempWarnMax` (default 0.6 / 0.85) — package
    temperature.

## plasmatop Memory

Shows two bar rows: RAM used/total and swap used/total. RAM "used" is
computed as `MemTotal - MemAvailable` (matching `htop`/`free`'s convention),
not `MemTotal - MemFree` — the latter would count reclaimable page cache as
"used," which overstates real memory pressure.

- Poll interval: 0.5–10.0s, default **2.0s** (slower than GPU/CPU/NET since
  a single `/proc/meminfo` read is cheap and RAM/swap totals don't burst the
  way GPU/CPU utilization does).
- Threshold pairs:
  - `ramGoodMax` / `ramWarnMax` (default **0.6 / 0.85**).
  - `swapGoodMax` / `swapWarnMax` (default **0.3 / 0.6** — noticeably
    lower than RAM's). Any nonzero swap usage means the kernel already
    decided it needed to push pages out of RAM, which is worse news than
    the same percentage of RAM simply being in use (Linux uses "spare" RAM
    for page cache by design, so a high RAM% alone is normal).

## plasmatop NET

Shows one mirrored graph for the machine's primary (default-route)
interface: upload as peaks (top half), download as valleys (bottom half).
The interface is re-detected every poll tick from `/proc/net/route` (not
cached), so switching from wifi to ethernet is picked up live; the detected
interface name (e.g. "eno1") shows in the widget's header.

- Poll interval: 0.5–10.0s, default **1.5s**.
- **No threshold fields at all** — this is the one widget without
  `*GoodMax`/`*WarnMax` config entries, by design. Throughput has no fixed
  0–100% scale the way utilization or temperature does; the graph instead
  auto-scales its own ceiling to recent peak throughput (snapping up
  instantly on a new peak, decaying 3%/tick otherwise, floored at 64 KB/s
  so idle traffic doesn't over-zoom the graph). An earlier attempt to color
  the graph relative to that auto-scaling ceiling was tried and dropped —
  it painted an ordinary traffic burst "bad" red for no real reason, purely
  because it briefly was the peak. The graph always renders in the single
  "good" color (`meterGoodColor`) instead; the graph's own auto-scaling
  already conveys "how busy."
  - Note: the config dialog still shows warning/bad color pickers even
    though the graph can currently never render in either color — see
    "Known inconsistency" below.

## plasmatop Disk

Full view shows one bar row per real physical drive, auto-detected from
`/proc/mounts` (pseudo-filesystems filtered out, same underlying device
mounted at multiple points deduplicated to its shallowest mountpoint, and
anything under a 10GiB size floor dropped — this generically excludes
things like `/boot`/`/boot/efi` without hardcoding those paths). The compact
panel view shows only the root (`/`) mount.

- Poll interval: 0.5–30.0s, default **5.0s** — the widest range and
  slowest default of any plasmatop widget, since disk usage changes far
  more slowly than CPU/GPU/memory.
- Threshold pair: `diskGoodMax` / `diskWarnMax` (default **0.80 / 0.90**).
  One shared pair applies to **every** drive shown — there's no per-mount
  threshold, since the list of drives varies by machine and isn't known in
  advance. The defaults sit higher than CPU/RAM's 0.6/0.85: disk space is
  normally fine to run fairly full, so the amber/red bands are pushed out
  to the point where actually running out becomes a near-term concern.

## Known inconsistency worth knowing about

The NET widget's config dialog exposes `meterWarnColor` and `meterBadColor`
pickers identically to the other four widgets, but nothing in the widget
can ever actually render in those colors — the graph's internal thresholds
are hardcoded so it always falls in the "good" range (see above). This
isn't a bug in the sense of broken behavior, but it's a config-UI parity
gap: NET's dialog looks like it offers the same threshold-driven coloring
the other widgets do, when it structurally can't. If the shared config-UX
work (`BACKLOG.md` Epic 6) touches this, it may be worth either graying out
those two pickers on NET or adding a note in its dialog explaining why they
have no visible effect.
