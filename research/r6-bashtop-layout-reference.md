# R6 — bashtop layout reference: making "mimic bashtop more" concrete

Question: the product owner reviewed `plasmatop-gpu` live and said it should
"mimic bashtop a bit more." This spike gets real visual reference (actual
screenshots, not memory) for bashtop's layout, cross-references gtop/vtop
(the project's other two named references), and translates the result into
specific layout changes for `plasmatop-gpu`.

Read alongside `research/r3-tui-aesthetic-rendering.md` (rendering technique:
`Rectangle`-based `BarMeter`, `Canvas`→now-braille `Sparkline`) and
`research/r4-terminal-graph-rendering.md` (font/glyph choice: braille via
bundled Adwaita Mono for the graph, system monospace for everything else).
**Neither of those decisions is revisited here** — this is purely about
visual layout, density, and proportion.

## 0. What was actually inspected (not memory/paraphrase)

- **bashtop**: downloaded the three real screenshots linked from
  `github.com/aristocratos/bashtop`'s own README —
  `Imgs/main.png`, `Imgs/menu.png`, `Imgs/options.png` — and looked at them
  directly (not just README prose, which is very thin on layout detail).
- **gtop**: `github.com/aksakalli/gtop`'s README links a demo GIF
  (`img/demo.gif`); extracted a representative frame with `ffmpeg` and
  looked at it directly.
- **vtop**: `github.com/MrRio/vtop`'s README links a demo GIF
  (`docs/example.gif`); same treatment.
- **Local install check (read-only, per instructions — nothing installed
  without sign-off)**: neither `bashtop`, `btop`, `gtop`, nor `vtop` is
  currently installed on this machine. `bashtop` itself is not packaged for
  Fedora at all (`dnf search bashtop` — no hits). Its C++ successor **`btop`
  IS available via `dnf` on this Fedora 44 box** (`btop.x86_64` — "Modern and
  colorful command line resource monitor") but is not installed. **Flagging
  this for product-owner/PM sign-off**: installing `btop` (`sudo dnf install
  btop`) would let a future spike drive the actual live TUI instead of static
  screenshots — recommended as a fast follow-up if more layout fidelity is
  ever needed, but not done here since it wasn't pre-approved and the
  screenshots below were sufficient to answer this task's question. `gtop`/
  `vtop` are npm packages, not checked against a Node package manager since
  the GitHub-hosted demo media already gave direct visual confirmation.

## 1. bashtop — detailed observation of `Imgs/main.png`

Overall screen is a grid of bordered boxes, each with a title inset into the
top border line (`┤title├`-style) rather than a title bar above the box.
Layout, top to bottom:

- **Row 1 — `cpu` box, full width of the screen**, tallest single element on
  screen (~40% of total height). Two small tab-like labels sit in its top
  border (`cpu` / `menu`) — these are the box's own selectable "expand for
  detail" tabs, not separate boxes.
- **Row 2 — three boxes side by side**: `mem` (left), `disks` (middle), and a
  wide **process-detail panel** (right) that spans rows 2+3 combined (i.e.
  it's one tall box occupying the whole right column while mem/disks stack
  as two shorter boxes on the left).
- **Row 3 — `net` box, bottom-left**, same width as mem/disks above it; the
  process-detail panel's lower portion becomes a **process list table**
  (same box, different content region, not a new bordered box).

So: **5 logical content areas, 4 visible box borders** (cpu; mem; disks;
net; the 5th "box" — process detail + process list — is one border split
into two content regions by a horizontal rule, not two boxes).

### The `cpu` box specifically (the box most comparable to `plasmatop-gpu`)

This is the single most important observation for this task. The box is
**not** "graph, then stats below it" or "stats, then graph below." It is:

- **One full-width, full-box-height history graph as the background of the
  entire box** — an area-style graph of overall CPU utilization over time,
  color-coded **bottom-to-top by each point's own historical value**
  (mostly green/olive across the low/steady baseline, shifting to
  yellow/orange/red exactly at the visible spikes in the trace, e.g. an
  orange spike around the 20% mark of the timeline and again near the
  right edge). This is a genuine per-point color gradient baked into the
  history, not a single flat color for the whole line.
- **A floating, unbordered text block overlaid in the top-right corner of
  that same graph**, not a separate section below it:
  - Line 1: CPU model name, left-aligned within the block (`i7-5775C`).
  - Line 1, right-aligned same row: current clock speed (`3.6 GHz`).
  - Line 2: `CPU` label + a **short, single-line, low-height bar meter**
    (not full-box-width — maybe 15-18 characters wide) + the percentage
    (`47%`) + the temperature (`68°C`), **all four on one text row**.
  - Lines 3-10: one row per core (`Core1`…`Core8`), each row again a single
    line containing: label, a **tiny inline sparkline** (a few characters
    wide, one glyph's worth of history resolution, not the big graph),
    percentage, and temperature — four pieces of information packed into
    one ~30-character-wide row, repeated 8 times, stacked with **no blank
    line between rows**.
- The background graph is visibly still there and un-obscured *around* this
  text block (you can see the graph's peaks/dots to the left of and below
  the stats column) — the stats column is a corner overlay on translucent/
  transparent background, not an opaque panel that hides part of the graph.

**Key structural fact: there is exactly one graphical representation of
overall CPU utilization (the big background graph) and the small inline bar
next to "CPU 47%" is a compact *current-value* meter, not a second
independent trend visualization.** Bashtop does not stack "label, then bar,
then graph" vertically the way `plasmatop-gpu` currently does — bar and
graph occupy the *same physical region*, layered, with the bar being a
short one-line meter for "what is it right now" and the graph being the
full-box canvas for "what has it been doing."

**Temperature** is shown purely as a plain color-coded number
(`68°C`, `100°C` etc. — color shifts toward red at high core loads/temps)
directly inline after the percentage. **There is no dedicated bar or graph
for temperature anywhere in the cpu box** — temperature rides along on the
same line as the utilization stat, as a suffix, not as its own row.

**Frequency** is shown exactly once, at the very top of the box, next to the
CPU model name — it's part of the box's header/identity line, not a
per-core or repeated stat, and not grouped with the "readouts at the
bottom" the way `plasmatop-gpu` currently does with power/frequency.

### `mem`/`disks` boxes — the "stack of single-line meters" pattern

Unlike the cpu box, `mem` and `disks` genuinely do use one-line bar meters,
several of them stacked — but note the packing:

```
Memory:                       15.2 GiB      <- total, no bar (plain text)
Used:      6.36 GiB      41%
[███████████████████░░░░░░░░░░░░░░░░░░░]    <- thin bar, own line, no repeated label
Available: 8.96 GiB      58%
[█████████████████████████░░░░░░░░░░░░░]
Cached:    8.84 GiB      57%
[████████████████████████░░░░░░░░░░░░░░]
Free:      433 MiB        2%
[█░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
```

So it *is* "label line, then bar line" for these — but each bar is a single
terminal row tall (not a chunky multi-row-tall bar), there's **no blank
line** between one stat's bar and the next stat's label, and each bar spans
the full box width. `disks` follows the identical pattern per disk
(`Used:`/bar/`Free:`/bar, repeated per mount point, no gaps).

### Information density and whitespace

Every box is packed edge to edge — no blank padding rows are used to
separate one stat group from the next; the only vertical whitespace is the
graph's own empty background above/below the trace line. Text columns are
narrow and abbreviated (`Used:`, not `Used space:`). The process-detail
panel on the right crams status/elapsed/parent/user/threads into one row,
command path text wraps to fit rather than truncating aggressively, and the
process table below it uses inline mini bar-graphs directly in the `%Cpu`
column cells rather than a separate graph area.

### Color usage

Notably more saturated and more varied-by-hue than plasmatop's current
palette: green baseline shifting through yellow/orange to red for high
load/temp (severity gradient, matches plasmatop's existing `ColorScale`
concept) **plus** distinct base hues assigned per box/metric-type
independent of severity — pink/magenta for network download, blue for
network upload and disk free space, cyan/white for borders and the
process-detail highlight. Two color dimensions are in play simultaneously:
"how severe" (green→yellow→red) and "which metric family" (hue per box).
`menu.png`/`options.png` (the popup screens) confirm the same look
persists in overlay/dialog states: bold red block-letter ASCII-art
logo/menu titles on the black background — much bolder/higher-contrast
than anything in plasmatop's currently muted default theme.

## 2. Cross-reference: gtop (`aksakalli/gtop`, via `blessed-contrib`)

Frame extracted from the README's demo GIF shows 5 boxes: a wide
`CPU History` box (top, full width) with a **floating legend box** in its
top-right corner (not a stats block like bashtop's — just a small bordered
inset listing `CPU1 16.2%` / `CPU2 10.2%` / etc., each line colored to match
that core's line in the shared multi-series graph below it); a `Memory and
Swap History` box (same "big graph + floating corner legend" pattern,
legend here only labels which color is Memory vs Swap, not a numeric
value); then, notably, **separate small boxes for `Memory`, `Swap`, and
`Disk usage`** that each show **only a circular "donut"/ring gauge with the
percentage in the center and a one-line text caption below** (`10%` /
`1.47 GB of 15.14 GB`) — no bar, no graph, in that smaller box, because the
history graph above already covers the trend.

Two takeaways not present in bashtop's screenshot:

- **A single metric can legitimately get both a history graph (in one box)
  and a separate snapshot gauge (in another box)** — gtop does this for
  memory — but the snapshot representation is a **ring/donut**, never a
  second bar or second line graph. gtop never duplicates the *same* chart
  type for the *same* metric.
- **Network stats here are much more compact than bashtop's**: `Network
  History` box is mostly text (`Receiving: 0.00 B/s` / `Total received:
  1.50 GB:`) with a short, low, single-row-height bar/sparkline strip
  underneath each direction — visually more like plasmatop's current
  `BarMeter` scale than bashtop's tall braille area-graph.

## 3. Cross-reference: vtop (`MrRio/vtop`)

Frame extracted from the README's demo GIF shows the sparsest, most
minimal layout of the three: a `CPU Usage` box and a `Memory Usage` box,
each **just a bordered box, a title in the top border, a single current
percentage number in the top-right corner of the box (`19%`, `86%` — no
label, no unit prefix, no bar), and the braille history graph filling the
entire remaining box area**. There is no bar meter anywhere in this
screenshot for CPU or Memory — the numeric readout is a **text overlay
directly on the graph's own corner**, nothing more. A `Process List` box
sits alongside, plain columns (`Command`/`CPU %`/`Count`/`Memory %`), no
inline graphics in the table at all (unlike bashtop's process table).

This is the cleanest example of the exact pattern named in the task brief:
**"the graph has the current numeric value overlaid directly on top of it
in the corner."** vtop does this with *zero* redundant bar meter — graph
and single-value readout are the same visual unit, at the cost of not
showing a temperature/frequency-style secondary stat at all (vtop has none
to show).

## 4. Synthesis: three tools, one shared structural rule

Despite differing a lot in polish/color, all three tools agree on one rule
`plasmatop-gpu` currently violates: **one chart type per metric, not two.**

- vtop: graph only, current value overlaid as text in the corner.
- bashtop: graph as the box's canvas, current value as a short *inline*
  one-line meter overlaid in a corner text block (bar + number together,
  but still just one graphical meter, not "big bar below label, then also
  a graph below that").
- gtop: graph for history, **or** ring gauge for a snapshot-only box — but
  never both a bar and a graph for the identical metric in the identical
  box.

`plasmatop-gpu` today stacks a full-width `BarMeter` **and** a `Sparkline`
vertically for the *same* utilization value — a redundancy none of the
three references do.

## 5. Concrete recommendations for `plasmatop-gpu`

Current layout (confirmed by reading
`widgets/plasmatop-gpu/contents/ui/main.qml`): a `ColumnLayout` of —
`Label("Utilization")` → full-width `BarMeter` → `Sparkline` →
`Label("Package temperature")` → full-width `BarMeter` →
`Label("VRAM temperature")` → full-width `BarMeter` →
`GridLayout` (2×2: `Frequency:`/value, `Power draw:`/value), each pair
separated by `Kirigami.Units.smallSpacing`.

Changes to make, most-impactful first:

1. **Remove the utilization `BarMeter` as a separate stacked row; fold its
   information into the `Sparkline` instead.** This is the single biggest,
   most literal match to all three references (§4): pick one visual per
   metric. Make `Sparkline` the sole utilization visual, give it more
   height than it has today (bashtop's/vtop's graphs dominate their boxes —
   easily 40%+ of box height), and overlay the current utilization
   percentage as a `Text` item anchored to the graph's own top-right corner
   (matching vtop exactly), with a subtle outline/shadow (the project
   already uses `style: Text.Outline` elsewhere in this file) so it reads
   over the graph's dot pattern. `ColorScale`/font choices from R3/R4 are
   unaffected — this is a layout-only change (remove one `BarMeter`
   instance, add one small `Text` positioned inside/over `Sparkline`'s
   `Item`).

2. **Color the sparkline's history by each point's own value, not a single
   flat "current value" color.** `Sparkline.qml` currently sets
   `root.lineColor` once from the *latest* pushed value (`colorForFraction`
   called on `last`, lines ~183/203) and paints the whole rolling trace
   that one flat color. bashtop's graph instead colors each column by
   *that column's own* historical value (§1: old steady baseline stays
   green even while a later spike renders orange/red in the same trace).
   This is bashtop's most visually distinctive and nameable trick and is
   currently the largest visual gap between plasmatop's implementation and
   the reference — worth a follow-up story on its own (per-sample color,
   not per-graph color) if the coder has bandwidth; flagging it here rather
   than folding it silently into item 1 since it's a `Sparkline.qml`
   internals change, not just a `main.qml` layout change.

3. **Merge each temperature's label + bar onto a single line; drop bashtop's
   now-established precedent that temperature itself never gets a
   dedicated bar.** Bashtop shows temperature as a bare color-coded number
   suffixed onto the *utilization* line, never as its own bar (§1). Fully
   matching that would mean deleting the pkg/VRAM temperature `BarMeter`s
   outright and rendering them as plain color-coded text. That is a bigger
   change than needed and throws away a working, useful `BarMeter`/
   `ColorScale` investment for two metrics (pkg temp, VRAM temp) bashtop's
   single-GPU-less CPU box never had to represent in the first place —
   **recommended compromise**: keep one `BarMeter` per temperature (still
   useful, still matches mem/disks' bar-per-stat pattern from §1), but
   collapse each temperature's separate `Label` line into the `BarMeter`'s
   own inline label (the component already renders a label — see
   `label: root.tempPkgC.toFixed(1) + "°C"` — so the fix is deleting the
   preceding `QQC2.Label { text: i18n("Package temperature") }` /
   `"VRAM temperature"` lines and instead setting a short prefix directly
   via `BarMeter`'s existing label mechanism, e.g. `"PKG  62.0°C"` /
   `"VRAM 58.0°C"`, one line per metric instead of two). This mirrors
   bashtop's actual per-row density (`CPU [bar] 47% 68°C` is one line, not
   a label line followed by a bar line) while keeping the bar.

4. **Move Frequency into the box header, next to the title — drop it from
   the bottom stats grid.** Bashtop shows clock speed once, top-right of
   the box next to the CPU model name (§1), i.e. as part of the box's
   *identity*, not a repeated/tabular stat. `shared/theme/AsciiBox.qml`
   already renders a `title` in the border; the concrete change is adding
   a second, right-aligned text slot in that same border row (or directly
   below it) showing `Math.round(root.freqMhz) + " MHz"`, and removing
   `Frequency:`/value from the bottom `GridLayout`.

5. **Drop the 2-column `GridLayout` once Frequency moves to the header —
   Power draw becomes the one remaining bottom stat and doesn't need a
   grid.** A `GridLayout` with a single populated row is unnecessary
   layout machinery; render Power draw as one plain `Label` line ("Power:
   `nn.n` W"), matching gtop's/bashtop's single-line plain-text stat
   convention for values that don't get a bar (bashtop's process-detail
   panel's `Status:`/`Elapsed:`/`Parent:` fields are exactly this pattern —
   one label, one line, no bar, no grid).

6. **Tighten vertical spacing between rows once labels are merged inline.**
   With items 1 and 3 done, the `ColumnLayout` goes from 8 stacked
   children (label, bar, sparkline, label, bar, label, bar, grid) down to
   4 (sparkline-with-overlay, pkg-temp-bar, vram-temp-bar, power-label) —
   at that point re-examine whether `Kirigami.Units.smallSpacing` between
   every child still reads as "tight" per §1's observation that reference
   tools use near-zero gap between stat rows within one box; if the result
   still looks loose once there are only 4 children, reducing the spacing
   further (or setting it per-child rather than uniformly) is worth a
   quick visual check on the real panel, consistent with this project's
   own established "verify live, not just `plasmoidviewer`" rule (R4 §5).

7. **Leave the color palette (`ColorScale`'s green/yellow/red severity
   triplet) architecturally alone — this is not what "mimic bashtop" should
   mean here.** §1 found bashtop layers a second color dimension (hue per
   metric-family: green CPU, blue disk, magenta network) on top of its
   severity gradient, but that pattern exists to distinguish *multiple
   boxes on one screen* — it doesn't map cleanly onto `plasmatop-gpu`,
   which is a single box (the project already handles "distinguish
   metrics" by being five separate plasmoids, per `README.md`'s locked-in
   scope). Recommend **not** chasing per-metric hue inside this one widget;
   if a distinct-hue treatment is wanted, it belongs at the whole-widget
   level (e.g. `plasmatop-net` could get a different accent hue from
   `plasmatop-cpu`) — worth a note for a future cross-widget theming story,
   out of scope for this GPU-box layout pass. The one thing genuinely worth
   tuning to close the "feels more muted than bashtop" gap: bashtop's
   colors read more saturated/higher-contrast against pure black than
   plasmatop's current `goodColor`/`warnColor`/`badColor` defaults
   (`#77ca9b`/`#cbc06c`/`#dc4c4c`, per `ColorScale.qml`) — a small
   saturation bump to those three defaults would close some of the gap
   without restructuring anything; treat as a minor tuning pass, not a
   blocking item.

## Summary table: what changes vs. what plasmatop already has right

| Element | Reference pattern (§1-3) | plasmatop-gpu today | Recommended change |
|---|---|---|---|
| Utilization | one visual only (graph, or graph+inline meter) | separate `BarMeter` row *and* `Sparkline` row for the same value | drop the standalone bar; overlay current % as text on the graph (#1) |
| Sparkline coloring | per-point color by that point's own historical value | flat single color from the latest value only | color each sample by its own value at push-time (#2) |
| Temperature | bare inline number, no dedicated bar, riding on the utilization line | separate label line + separate full-width bar, own row | keep the bar (useful, not wrong) but merge label into it, one line per temp (#3) |
| Frequency | shown once, in the box header/title area | shown in a bottom 2-column stats grid | move to the `AsciiBox` title row (#4) |
| Power draw | single plain-text line (closest analog: bashtop's process-detail plain stat fields) | one cell of a 2-column grid (now half-empty once Frequency moves) | single `Label` line, no grid (#5) |
| Row spacing/density | near-zero gap between stat lines within a box | uniform `smallSpacing` between every child, more of them than needed | re-tighten once child count drops (#6) |
| Color model | severity gradient *plus* per-box hue | severity gradient only, single accent set | keep severity-only (right for a single-box widget); minor saturation bump only (#7) |
| Bar meter rendering, graph rendering, font | *(settled in R3/R4)* | `Rectangle`-based `BarMeter`, braille `Sparkline` via bundled Adwaita Mono | **no change** — out of scope for this spike |
