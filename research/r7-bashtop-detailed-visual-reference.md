# R7 — bashtop detailed visual reference (supersedes R6 on visual/behavioral depth)

Driving questions are Epic 1.7's four open items in `BACKLOG.md`:
segmented bar meters (fixed vs. scaling segment count), whether the CPU/GPU
graph is a mirrored-single-value display or two different values, filled
area vs. stroked line, and — the important one for the flicker bug — how
bashtop keeps a graph's colors stable frame over frame.

## 0. Method (stronger than R6's: image + ground-truth source, not just image)

R6 looked only at the three README screenshots. That is insufficient to
answer Q2 and Q4 with confidence — "is the color of a fixed history point
determined once or recomputed" and "is this a mirrored duplicate or two
independent series" are **algorithm** questions, not things a single static
frame can prove beyond reasonable doubt. So this pass did two things:

1. **Re-inspected `Imgs/main.png`** (from a fresh clone of
   `github.com/aristocratos/bashtop`) at high zoom — cropped and
   nearest-neighbor-upscaled specific regions (the CPU graph's left edge,
   a steady mid-graph band, the mem/swap/disk bar meters, the net box, the
   per-core mini-sparklines, the CPU summary line) with Python/Pillow via
   `convert`/`PIL`, to see individual glyph cells and their exact colors —
   well beyond what's visible at the screenshot's native display size.
2. **Cloned the actual bashtop source** (`aristocratos/bashtop`, the real
   program — it is a single ~206 KB **bash script** named `bashtop`, not
   Python; `src/bashtop.psutil.py` is a legacy/alternate source not what
   ships) and read the exact functions that draw meters and graphs:
   `create_meter` (bar meters), `create_graph` (block-glyph graph, legacy/
   low-res mode), `create_graph_hires` (braille graph, what the screenshot
   actually shows), and the color-gradient generator that builds
   `color_cpu_graph`/`color_used_graph`/etc. This turns "what does the
   picture look like" into "here is the exact code that produced the
   picture," which is decisive for Q2 and Q4 in particular.

`btop` (the C++ successor, available via `dnf` but not installed on this
machine per R6) was **not installed** for this pass — it wasn't needed.
Having bashtop's own literal source is strictly better evidence than
eyeballing a live `btop` session would have been for exactly the two
questions (Q2, Q4) that are about internal state/algorithm, not appearance;
and bashtop, not btop, is what R6/the backlog have been referencing by
name throughout. Flagging for the record: if a future spike wants to
confirm `btop`'s C++ implementation still works identically (it's a
rewrite, not a fork, so it's not guaranteed to match bashtop's bash
implementation line-for-line), installing it read-only is still a
reasonable fast follow-up — just not required to answer these four
questions.

All code line numbers below refer to the cloned `bashtop` script as of this
research pass (`/tmp/bashtop-src/bashtop`, HEAD of `master`).

---

## 1. Q1 — Bar meters: segmented blocks, and does segment count scale?

**Yes, unambiguously segmented — never a smooth/continuous fill.** Zoomed
crops of three different bars in `main.png` (swap-used, disk-free, and the
CPU summary line's inline meter) all show the same thing: a row of
individual square glyphs (`■`, U+25A0 BLACK SQUARE) placed one per
character cell, each with a visible dark gap around it. At 6-8x
nearest-neighbor zoom the gap is clearly the glyph's own padding within its
monospace cell (there is no separate "gap" character being printed between
blocks) — but visually, at normal terminal size, it reads exactly like a
segmented/chunky meter, not a bar with a continuous edge.

**Segment count is not a fixed small number (not "5 or 10") — it equals the
meter's width in terminal columns, and that is computed from the box's
actual measured width at render/resize time.** This is provable directly
from `create_meter`'s source (`bashtop:1131-1183`):

```bash
create_meter() {
    ...
    width=${width:-10}
    ...
    for((i=1;i<=width;i++)); do
        ...
        if ((val>=i*100/width)); then
            print -v meter_var -fg ${colors[$((i*100/width))]} -t "${block}"
        elif ((fill_empty==1)); then
            ...
            print -v meter_var -fg $bg_color -rp $((1+width-i)) -t "${block}"; break
        ...
```

The `for` loop runs exactly `width` times and emits exactly one `■` glyph
per iteration — **one segment per character column of the meter's track**,
full stop. Callers compute that `width` from the box's live size, e.g. the
mem/disk bar call sites:

```bash
create_meter -v ${type}_${value}_meter -w $((m_width-7-meter_mod_w)) -f -c color_${value}_graph ${type_name[${value}_percent]}
create_meter -v disk_${disk_num}_${value}_meter -w $((m_width-7-meter_mod_w)) -f -c color_${value}_graph ${disk_value_percent[disk_num]}
```

`m_width` is the box's actual current terminal-column width; `meter_mod_w`
is a small width-dependent modifier. So segment count is **continuous with
box width**, not two discrete tiers (small=5, wide=10) — it's "as many
1-character segments as physically fit," recalculated whenever the box is
resized. Measured directly from crops: the ~245px-wide disk box's "Free"
bar shows **15 segments** (12 filled at 82%); the wider mem/swap box's bar
shows **~25 segments** (the CPU summary line's short ~18-char-wide inline
meter shows **~10 segments**, matching R6's estimate for that specific
element). All three are literally the same `create_meter` function called
with three different `width` values — direct visual confirmation of the
"more width -> more segments" rule.

**Exact color-per-segment behavior**: each filled segment gets its **own**
color, looked up as `colors[i*100/width]` where `i` is that segment's
1-based index — i.e., a segment's color depends on *its position along the
bar*, indexed into a precomputed 0-100 percentage-gradient array (see §4
below for how that array itself is built). This produces the visible
left-to-right color ramp inside the filled portion in every zoomed crop
(e.g. the swap-used bar: dark brick-red at the leftmost filled segment,
brightening step by step to a lighter salmon/orange at the rightmost filled
segment, then a hard cutoff into unfilled territory). **Unfilled segments,
when the caller passes `-f`/`-fill-empty` (all the bars observed in
`main.png` do), are drawn too** — not left blank — but in one single flat
muted color (`bg_color=${theme[inactive_fg]}`, a dim blue-gray), not a
gradient and not transparent. Without `-f` the unfilled tail would just be
plain spaces instead of dim blocks.

---

## 2. Q2 — Is the CPU graph mirrored (same value) or two different values?

**For the CPU box specifically: mirrored duplicate of the SAME single
value, drawn twice — once upward from a center line, once downward — purely
for visual density/symmetry. It is not two different metrics.** This is
provable directly from the call sites that build the CPU box's graph
(`bashtop:2999-3000` for the initial draw, `3018-3019` for each new sample):

```bash
create_graph -o cpu_graph_a -d ${line} ${col} ${graph_a_size} $((width-p_width-2)) -c color_cpu_graph -n cpu_history
create_graph -o cpu_graph_b -d $((line+graph_a_size)) ${col} ${graph_b_size} $((width-p_width-2)) -c color_cpu_graph -i -n cpu_history
...
create_graph -add-last cpu_graph_a cpu_history
create_graph -i -add-last cpu_graph_b cpu_history
```

Both `cpu_graph_a` (the upper half, normal orientation) and `cpu_graph_b`
(the lower half, `-i`/`-invert` flag) are fed from **the exact same source
array, `cpu_history`**. There is only one number per timestep (overall CPU
utilization); it is rendered once growing up from the box's vertical center
and once growing down from the same center, using the identical value each
time. The two halves are then concatenated for output at draw time
(`bashtop:3092`: `draw_out+="${cpu_graph_a[*]}${cpu_graph_b[*]}${cpu_out_var}"`).

Visually, this matches the zoomed crop of `main.png`'s CPU graph exactly:
a spike near the left edge and another near the right edge both extend
**the same number of rows above and below the center line**, with an
identical dot-density/shape pattern mirrored top-to-bottom (confirmed at
pixel level — the top spike's silhouette, read row by row from the center
outward, is the same width-per-row as the bottom spike's, row by row). The
steady middle portion of the timeline is a thin, uniform-height band both
above and below center — again identical thickness on both sides at every
column, which would not happen if the two halves were plotting independent
noisy series.

**Important contrast — the mirror mechanism is generic, and bashtop reuses
it for genuinely different values elsewhere.** The `net` box uses the exact
same "-i for the lower half" call pattern, but feeds each half a
**different** source array (`bashtop:3520-3527`):

```bash
create_graph -o download_graph -d $line $col ${net[graph_a_size]} $((width-n_width-2)) -c color_download_graph -n -max "${net[download_graph_max]}" net_history_download
create_graph -o upload_graph -d $((line+net[graph_a_size])) $col ${net[graph_b_size]} $((width-n_width-2)) -c color_upload_graph -i -n -max "${net[upload_graph_max]}" net_history_upload
```

Here the top half is `net_history_download` and the bottom half (inverted)
is `net_history_upload` — two independently-scaled, independently-colored
real series (confirmed visually too: the zoomed net-box crop shows the top
half in a warm orange/red palette and the bottom half in a cool blue/violet
palette, with visibly different silhouettes column-to-column — download
has a tall block on the left that upload doesn't share). So: **the
top/bottom-split-graph widget is a single reusable primitive that can be
used either way** — same-value mirror (CPU, and also the per-process
"detail" CPU graph at `bashtop:3267`, which is single-value/non-split) or
two-different-values split (net download vs. upload). For an aggregate
CPU/GPU utilization box specifically, the reference behavior to copy is the
**mirror-same-value** case, not the net box's two-series case — there is
only one utilization number to show, so mirroring it top/bottom is purely a
"fill more vertical space with one value" trick, exactly as Epic 1.7's item
already assumes ("utilization as peaks (up), VRAM use as valleys (down)"
would actually be closer to the **net-box pattern** — two genuinely
different values sharing the split — worth noting since it's a *different*
one of bashtop's two patterns, not the CPU box's own pattern; see
Recommendations below).

---

## 3. Q3 — Filled area or stroked line?

**Solid filled area under the curve, not a stroked/outlined line.** This is
explicit in `create_graph`'s per-row drawing loop (`bashtop:1332-1360`,
identical logic in the braille `create_graph_hires`):

```bash
#* Print empty space if current value is less than percentage for current line
while ((x<value_width & input_array[x]*virt_height/100<next_value)); do
    ((++count)); ((++x))
done
if ((count>0)); then print -v graph_array[y] -rp ${count} -t " "; count=0; fi

#* Print current value in percent relative to graph size if ... (the exact boundary row)
while ((x<value_width & input_array[x]*virt_height/100<cur_value & input_array[x]*virt_height/100>=next_value)); do
    print -v graph_array[y] -t "${graph_symbol[${invert:+-}$(( (input_array[x]*virt_height/100)-next_value ))]}"
    ((++x))
done

#* Print full block if current value is greater than percentage for current line
while ((x<value_width & input_array[x]*virt_height/100>=cur_value)); do
    ((++count)); ((++x))
done
if ((count>0)); then print -v graph_array[y] -rp ${count} -t "${graph_symbol[10]}"; count=0; fi
```

For each row `y` (each terminal line of the graph, working from the
baseline upward): a column is **blank** if the value doesn't reach that
row at all, **fully solid** (`graph_symbol[10]` = `⣿`, a completely filled
braille cell) if the value is well past that row, and gets one
**transitional partial-fill glyph** exactly at the row where the value's
top edge falls. `graph_symbol` (`bashtop:238-239`) is a 21-entry lookup
table running from a blank cell through progressively fuller dot patterns
(`⡀ ⣀ ⣄ ⣤ ⣦ ⣴ ⣶ ⣷ ⣾ ⣿` for the "up" direction) to fully solid — i.e. this
is a **filled-column-height encoding**, not a "plot a dot/line at exactly
this y-value and leave everything else blank" encoding. Everything from the
graph's baseline up to the current value is opaque/solid; everything above
it is empty background. The high-resolution braille variant additionally
uses a small 2D lookup table (`graph_symbol_up`/`graph_symbol_down`,
`bashtop:240-253`, keyed by two sub-cell axes `[row_4][col_4]`) purely to
get sub-character-cell antialiasing on the *diagonal edge* between two
adjacent columns of different height — this is edge smoothing on the top
boundary of the fill, not evidence of a stroked outline; the interior below
the edge is still the same flat, fully-solid `⣿` fill.

**No gradient-of-transparency and no separate "line" glyph drawn on top of
the fill** — the fill IS the graph. Color varies by row (see §4), which
from a distance can look like "the line is thick and colorful" but
structurally it is solid fill colored per-row, confirmed by the zoomed
mid-graph crop of `main.png`: the entire vertical span from the center
line out to each column's peak is opaque dot-pattern with no visible gap or
outline-only edge.

---

## 4. Q4 — Color stability over time: does bashtop repaint history, and how does it avoid the flicker plasmatop has?

**Bashtop's mechanism categorically cannot flicker, because color is never
tied to "when" a column was drawn or to a live/current value at all — it is
tied to a static, precomputed row-position lookup table set up once and
never touched again except on an explicit resize.** This is the single most
load-bearing finding for the plasmatop bug and is fully traceable in the
source.

**Step 1 — the color tables themselves are a static 0-100 gradient, built
once at theme load** (`bashtop:538-577`, comment at 538: *"Create color
arrays from one, two or three color gradient, 100 values in each"*). For
each metric family (`temp`, `cpu`, `upload`, `download`, `used`,
`available`, `cached`, `free`) bashtop interpolates the theme's
start/mid/end RGB colors across exactly 101 entries (`color_cpu_graph[0]`
through `color_cpu_graph[100]`) and stores them as a plain indexed array.
This happens when the theme is (re)loaded, not per-frame, not per-poll, and
is **not** a function of anything currently on screen (not the current
max/min in the visible window, not "how long ago" a sample was taken) — it
is purely `percentage-value -> fixed RGB`, decided once.

**Step 2 — a graph row's color is assigned once, at graph
creation/resize time, indexed by that row's fixed vertical position, never
by the data.** In both `create_graph` (`bashtop:1269-1273`) and
`create_graph_hires` (`bashtop:1585-1588`), the color-setting code runs
**only inside the `if [[ -z $add ]]` branch** — i.e. only on the initial
draw or a resize-triggered full rebuild, never on the routine "add one new
sample" path:

```bash
print -v graph_array[0] ... -fg ${colors[100]}
for((i=1;i<height;i++)); do
    print -v graph_array[i] -m $((line+g_index[i])) ${col} ... -fg ${colors[$((100-i*100/height))]}
done
```

Row `i`'s ANSI foreground-color escape code is written into that row's
string literally once, computed from `100 - i*100/height` — i.e., **purely
from the row's own fixed distance from the graph's top edge**, nothing to
do with any sample value. This is exactly what the zoomed screenshot crops
show directly: every spike in the CPU graph, regardless of *when* it
occurs in the timeline, shows the identical color banding read outward from
center — green nearest the center line, then yellow/olive, then red only in
the outermost rows — because every column that happens to reach a given row
lights up that row's one fixed, pre-baked color. A tall spike from 5
minutes ago and a tall spike from right now, if they reach the same row,
render in the exact same shade, because the shade was never a property of
the sample — it's a property of the row.

**Step 3 — adding a new sample only pushes glyphs into the already-colored
rows; it never re-touches color.** The "scroll left, append new column"
path (`bashtop:1225-1245` and `1546-1560`) strips off the leftmost
character(s) from each row's string and appends the new column's glyph —
but the color-setting code (`if [[ -z $add ]]`) is skipped entirely on this
path, so the newly appended glyph simply inherits whichever `-fg` escape
code is already sitting earlier in that row's string from Step 2. **No
frame ever recomputes or reassigns color for any row or any historical
column.** The only event that would ever change a row's color is a full
graph reinitialization (terminal resize), which is a legitimate, rare,
user-driven event — not something that happens on every poll/redraw.

**Direct contrast with plasmatop's suspected bug** (Epic 1.7: *"Sparkline
color is unstable/flickery — suspected cause: resampling onto a small dot
grid makes the line (and its per-point color) jump between polls even when
the real value barely changed"*): bashtop's design sidesteps this class of
bug entirely by **not deriving color from the resampled/rendered geometry
at all**. It never asks "what value does this rendered dot/column
represent, so what color should I give it" on every frame — it asks once,
at layout time, "what color does row N always get," and then just decides
per-frame whether a given column is tall enough to *reach* row N (a boolean
threshold test, `input_array[x]*virt_height/100 >= cur_value`), which is
comparatively insensitive to small resampling jitter because it only
flips the glyph choice within one row's fixed color, not the color itself.
Two consecutive polls of a barely-changed value can therefore only ever
differ in *how many* rows near the boundary get partial-vs-full glyphs
(and, at most, whether the boundary row's fixed color is used at all) —
they can never cause an already-drawn, already-scrolled-past column's color
to change, because that column's color was baked in when it was first
drawn and is never revisited. If plasmatop's `Sparkline.qml` currently
computes a color from `colorForFraction(value)` at render/paint time for
each visible sample on every repaint (recall R6 §5 item 2: *"`root.lineColor`
... painted the whole rolling trace that one flat color"* — i.e. plasmatop
currently colors the whole trace from the *latest* value, an even more
aggressive form of "recompute every frame" than per-sample recoloring would
be), **the fix suggested by this reference implementation is specifically:
stop deriving any color from a value at paint/resample time; instead
assign each row (or, if keeping a value-based scheme, each sample) a color
exactly once when that pixel/row is first established, from a static
percentage-to-color LUT, and never recompute it on subsequent frames** —
not "smooth the resampling," which treats a symptom, not the mechanism
described here.

---

## 5. Bonus finding not covered by R6: the CPU summary line has more on it than described

Zooming into the CPU box's top-right stats corner (`main.png`, the `CPU
[bar] 47% ... 68°C` row) shows **five** elements left to right, not four:
`CPU` label, the inline bar meter, `47%`, **a small dense braille dot-block
(~10 columns x 2 rows, a miniature history sparkline)**, then `68°C`. R6's
description of this row only mentioned label/bar/percentage/temperature.
The per-core rows below it (`Core1`...`Core8`) have this same small
braille block in the same position (R6 did note this one, calling it a
"tiny inline sparkline"). So: **the overall-CPU line and every per-core
line both get their own tiny history sparkline**, positioned between the
percentage and the temperature — not just the per-core rows. Worth knowing
if `plasmatop-gpu`'s per-metric row ever wants a "recent trend" micro-glyph
next to a plain-text stat (e.g. the power-draw line) without going as far
as a full graph.

---

## 6. Answers at a glance

| Question | Answer | Evidence |
|---|---|---|
| Q1: segmented bars | Yes, discrete 1-char-cell `■` blocks, never smooth. Segment count = meter's actual character width, computed live from box size — continuous scaling (15 segments in a narrow disk box, ~25 in a wider mem box, ~10 in an 18-char inline meter), not two fixed tiers. Each filled segment individually colored by its position (`colors[i*100/width]`); unfilled segments (when `-f` used) drawn flat-dim, not gradient, not blank. | `create_meter`, `bashtop:1131-1183`; caller widths at `3057/3147/3200`; zoomed crops of swap/disk/CPU-line bars |
| Q2: mirrored or two values | The CPU box mirrors ONE value (`cpu_history`) both up and down from center — pure visual-density trick, confirmed by both halves reading from the identical source array. The *same* split-graph mechanism is reused by the net box to show two genuinely different values (download up, upload down, different arrays, different color palettes) — so the primitive is generic, but the CPU/aggregate-utilization use case specifically is same-value mirroring. | `create_graph` calls at `2999-3000`/`3018-3019` (CPU, same array) vs. `3520-3527` (net, different arrays); zoomed CPU graph shows identical top/bottom silhouette per column |
| Q3: filled or stroked | Solid filled area from baseline to current value; blank above it. One transitional glyph exactly at the value's boundary row for sub-cell antialiasing (2D braille lookup table), not a separate outline. No transparency gradient. | `create_graph`/`create_graph_hires` fill loop, `bashtop:1332-1360`; `graph_symbol`/`graph_symbol_up`/`graph_symbol_down` tables, `1237-253` |
| Q4: color stability | Colors are a static 0-100 RGB LUT built once at theme load (not per-frame, not relative to on-screen min/max). Each graph ROW gets one fixed color from that LUT, assigned once at graph creation/resize — never on the routine per-sample update path. New samples only append glyphs into already-colored rows. Result: a historical column's rendered color can never change after the fact, because color was never a function of the sample or the moment it was drawn — only of fixed row position. | Gradient build: `bashtop:538-577`. Row-color-once-at-init: `create_graph` `1269-1273`, `create_graph_hires` `1585-1588`, guarded by `if [[ -z $add ]]` so the "add one sample" path (`1225-1245`/`1546-1560`) never re-touches color |

## 7. Implication for Epic 1.7's four items

1. **Segmented bars**: implement segment count as `floor(track_width_px /
   segment_cell_width_px)` (or the QML equivalent — as many discrete
   `Rectangle`s as fit the available width), recomputed on resize, not a
   hardcoded 5-vs-10 branch. Color each segment individually from the
   existing `ColorScale`-style percentage LUT indexed by *that segment's
   position*, not by the current overall value.
2. **Mirrored sparkline**: bashtop's own CPU box mirrors one value; its net
   box splits two different values across the same up/down primitive. If
   plasmatop wants utilization-up/VRAM-down as two genuinely different
   series in one graph, that is bashtop's **net-box pattern**, not its
   CPU-box pattern — worth being explicit about which one is being copied,
   since they're visually similar but semantically different (one series
   mirrored vs. two independent series sharing a split).
3. **Filled area, not line**: confirmed as the correct reference behavior —
   fill from baseline to value, one boundary transition glyph/pixel for
   antialiasing, nothing stroked.
4. **Color flicker fix**: the mechanism to copy is "assign color once, from
   a static value-to-color LUT, at the moment a row/column is first
   established; never recompute color on a later frame for
   already-existing history," not any form of smoothing/damping of the
   resampled geometry itself.
