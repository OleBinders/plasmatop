# R4 — Terminal graph rendering spike

Question: how do real terminal system-monitor tools (vtop, bashtop, gtop)
actually render their graphs, is braille more font-metrics-reliable than
block elements (the earlier failure mode), does a reusable
library/algorithm already exist, and should plasmatop retry a
character-based graph in QML.

Read alongside `research/r3-tui-aesthetic-rendering.md` (the original
Canvas/Rectangle recommendation) and `SPRINTS.md` Sprint 1 (the character-
based `BarMeter`/`Sparkline` rewrite that was tried and reverted — see the
comments left in place in `shared/theme/BarMeter.qml` and
`shared/theme/Sparkline.qml`, which already document the revert and its
suspected cause).

Sources: shallow `git clone` of the actual upstream repos (not memory,
not paraphrase) — `aristocratos/bashtop`, `MrRio/vtop`,
`madbence/node-drawille`, `yaronn/blessed-contrib`, `aksakalli/gtop` — plus
`fc-list`/`fc-match` and a PySide6 (Qt 6.11.2, matching this project's Qt
version) script on this actual Fedora 44 machine.

## 1. How the three tools actually render graphs

### vtop (MrRio/vtop, Node.js — confirmed correct project: README literally
says "It uses drawille to draw CPU and Memory charts with Unicode braille
characters, helping you visualize spikes", matching this project's own
"braille character line graphs, retro feel" framing)

- Depends on **`drawille` (madbence/node-drawille)**, `"drawille": "1.1.0"`
  in `package.json`, plus `blessed` for the terminal UI shell.
- `vtop/app.js` does `const Canvas = require('drawille')` and constructs
  `new Canvas(width, height)` per chart, where `width`/`height` are the
  chart's pixel-equivalent dimensions.
- **`node-drawille`'s entire algorithm** (verbatim from `index.js`, 60
  lines total):
  ```js
  const map = [
    [0x1, 0x8],
    [0x2, 0x10],
    [0x4, 0x20],
    [0x40, 0x80]
  ];
  // Canvas width defaults to `process.stdout.columns * 2 - 2`
  // Canvas height defaults to `process.stdout.rows * 4`
  // .set(x, y) turns on one "pixel":
  //   nx = floor(x/2), ny = floor(y/4)   -> which braille CHARACTER cell
  //   mask = map[y % 4][x % 2]           -> which of the 8 dots inside that cell
  //   content[nx + (width/2)*ny] |= mask
  // .frame() renders the whole buffer to a string:
  //   String.fromCharCode(0x2800 + cur)  for each cell byte `cur`
  ```
  This is the textbook braille-graphics technique: each visible character
  cell is treated as a virtual **2-wide × 4-tall dot sub-grid** (8 dots =
  1 byte), giving 2x horizontal and 4x vertical resolution versus one
  glyph per data sample. Unicode codepoint = `0x2800 + bitmask`, i.e. the
  entire "Braille Patterns" block **U+2800–U+28FF** is used purely as a
  256-symbol dot-matrix alphabet — the code has no linguistic awareness of
  braille as a writing system, it's repurposed as a bitmap font.
- Critically: **the canvas's pixel dimensions are derived directly from
  the terminal's own character-cell grid** (`stdout.columns`/`stdout.rows`),
  not from any font-metrics measurement. There is no analog of
  `FontMetrics.advanceWidth()` anywhere in this code path.

### bashtop (aristocratos/bashtop, pure Bash — predecessor to btop)

- Two distinct meter/graph code paths, both in the single `bashtop` script
  (5320 lines, no `.sh` extension):
  - **`create_meter()`** (line 1131) — simple percentage bar. Uses a
    single hardcoded glyph, `block="■"` (U+25A0 BLACK SQUARE, "Geometric
    Shapes" block), one glyph per terminal column, colored per-column from
    a 0–100-indexed color array. No block-elements/eighths characters here
    at all — the "chunky" look comes from repeating one solid square, not
    a gradient of partial-fill glyphs.
  - **`create_graph()`** (line 1185) — low-res history graph, and
    **`create_graph_hires()`** (line 1491) — the braille version, selected
    at runtime via `graph[hires]`. The hires path uses a literal lookup
    table (line 237-239):
    ```bash
    graph_symbol=(" " "⡀" "⣀" "⣄" "⣤" "⣦" "⣴" "⣶" "⣷" "⣾" "⣿")
    graph_symbol+=(" " "⣿" "⢿" "⡿" "⠿" "⠻" "⠟" "⠛" "⠙" "⠉" "⠈")
    ```
    plus two associative arrays `graph_symbol_up`/`graph_symbol_down` keyed
    by `"${prev_level}_${cur_level}"` pairs (levels 0-8) — i.e. **the glyph
    chosen for column N encodes the transition between column N-1's fill
    level and column N's fill level**, not just column N's level in
    isolation. This is what makes bashtop's/btop's braille line graphs read
    as one continuous diagonal line rather than a discrete staircase — the
    same 2-wide braille sub-grid gives one glyph two independent vertical
    "positions" (left dot-column = where the line was, right dot-column =
    where it's going), and the lookup table encodes every
    `(prev, cur)` pair as one precomputed literal character. No bit-math
    at draw time at all — it's a flat table indexed by two small integers.
- **Same structural point as vtop**: `width`/`height` passed into these
  functions are **terminal column/row counts** (`is_int` checked, plain
  bash integers), not pixel measurements. `((width<3)); then width=3`
  and similar are bounds-checks on an integer column count. There is no
  font-metrics call anywhere in this codebase — bash has no concept of a
  font at all.
- **bashtop's README explicitly documents a font requirement** (this
  directly answers research question 2's font-bundling angle): it lists
  three required Unicode blocks — `"Braille Patterns" U+2800-U+28FF`,
  `"Geometric Shapes" U+25A0-U+25FF`, `"Box Drawing" and "Block Elements"
  U+2500-U+259F` — and states plainly: **"Also needs a UTF8 locale and a
  font that covers"** those ranges. It does **not bundle a font** — it
  pushes the requirement onto the user's terminal/font configuration and
  documents it as a precondition, rather than solving it in code.

### gtop (aksakalli/gtop, Node.js, built on blessed-contrib)

- `gtop`'s own source (`lib/gtop.js`) contains **zero custom rendering
  code**. It is purely a `blessed-contrib` grid layout wiring together
  five stock widgets: `contrib.line` (CPU/mem history),
  `contrib.donut` (mem/swap/disk %), `contrib.sparkline` (network), and
  `contrib.table` (processes). All actual character-drawing logic lives in
  `blessed-contrib` itself — gtop-specific code is entirely business logic
  (polling `systeminformation`, formatting numbers).
- **`blessed-contrib`'s `line` chart** (`lib/widget/charts/canvas.js` +
  `lib/widget/charts/line.js`) is, again, **braille via drawille**: its
  `package.json` depends on `"drawille-canvas-blessed-contrib"` (a fork of
  the same node-drawille adapted to blessed's rendering pipeline), and
  `canvas.js`'s constructor does `new InnerCanvas(width, height, canvasType)`
  from that package — same 2×4-dot-per-cell, `0x2800`-offset technique as
  vtop, just repackaged as a reusable "draw arbitrary lines/text on a
  braille-backed canvas" abstraction that `line.js` then calls with plain
  x/y pixel coordinates computed from a straightforward linear scale
  (`getXPixel`/`getYPixel` — ordinary point-to-pixel interpolation, no
  novelty there).
- **`blessed-contrib`'s `sparkline` widget** (`lib/widget/sparkline.js`) is
  a *different, non-braille* code path: it depends on the separate npm
  package `"sparkline": "^0.1.1"` and calls
  `sparkline(datasets[i].slice(0, this.width - 2))` — a block-element
  (`▁▂▃▄▅▆▇█`-style) one-glyph-per-sample renderer, width-limited to
  `this.width - 2` **terminal columns** (again: an integer column budget,
  not a pixel measurement).
- So blessed-contrib itself independently demonstrates **both** techniques
  side by side (braille for line/gauge-style charts wanting sub-cell
  resolution, block-elements for compact single-row sparklines) — it isn't
  a single "one true technique," it's two techniques picked per widget
  shape, and the underlying npm packages that implement them are already
  the "existing library" answer to research question 3 for the JS
  ecosystem.

## 2. The font-metrics question

### What's installed / what "monospace" resolves to on this machine

```
$ fc-match monospace
NotoSansMono-Regular.ttf: "Noto Sans Mono" "Regular"
```

Fontconfig's generic `monospace` alias resolves to **Noto Sans Mono** on
this Fedora 44 box — not DejaVu Sans Mono (not installed at all — checked,
zero hits). Fonts flagged `spacing=100` (fontconfig's own "this is
monospaced" property) that are actually installed: **Adwaita Mono, Hack,
Liberation Mono, Nimbus Mono PS** (plus Noto Color Emoji, irrelevant here).
Noto Sans Mono itself isn't tagged `spacing=100` in fontconfig's metadata
but is still what the `monospace` generic name maps to by family-name
substitution rule on this system — worth knowing because it means "ask for
`font.family: "monospace"`" and "ask for a `spacing=100`-flagged family"
are not quite the same query here, in a way that could matter to a future
implementer.

### Empirical test performed

PySide6 6.11.2 is installed on this machine (confirmed: exact Qt version
this project targets) and was used — via `QT_QPA_PLATFORM=offscreen` — to
run `QFontMetricsF` checks directly, no `qmlscene`/`plasmoidviewer` needed
for this. The throwaway script (`research/scratch_font_probe.py`, deleted
after use per the "don't leave scratch files" norm — this doc is the
permanent record) measured, for `Noto Sans Mono`, `Hack`, `Liberation
Mono`, `Adwaita Mono`, `Nimbus Mono PS`, and the generic `monospace` alias:

**(a) Glyph coverage — this is the headline finding, not advance width.**

| Font | full block █ | eighths ▁▂▃▄▅▆▇ (all 7) | light shade ░ | braille (any) |
|---|---|---|---|---|
| Noto Sans Mono (= "monospace" on this box) | yes | **yes, all 7** | yes | **no** |
| Hack | yes | **yes, all 7** | yes | **no** |
| Adwaita Mono | yes | **yes, all 7** | yes | **yes** |
| Liberation Mono | yes | **no — missing ▁ and ▇ specifically** | yes | **no** |
| Nimbus Mono PS | yes | **no — missing ▁ and ▇ specifically** | yes | **no** |

Checked via `QFontMetricsF.inFontUcs4()` with `QFont::NoFontMerging` set
(forces Qt to report whether *that exact font file* has the glyph, rather
than silently letting fallback substitution mask a missing glyph).

This flatly contradicts the framing in the task brief that braille might
be the *safer* choice: **on this exact machine, with this exact Qt
version, the system's own `"monospace"` generic alias (Noto Sans Mono) has
zero braille coverage**, while it has full 8-level block-element coverage.
Of the five real fonts checked, only Adwaita Mono (a Fedora/GNOME-specific
font, not universally installed on other distros) has braille glyphs at
all. Requesting `font.family: "monospace"` and drawing braille characters
on this system would silently trigger Qt's font-fallback machinery for
*every single glyph*, handing rendering off to whatever the platform
substitutes for uncovered codepoints — the opposite of a "more reliable"
situation. This is a materially different, more fundamental problem than
the width-measurement bug that sank the block-element attempt: it's not
"the width is wrong," it's "the requested font can't draw this character
at all," on the very system this widget targets.

Separately, and this is a real risk for the *block* approach too even
though this project already validated it works on this machine: the two
non-Noto/non-Hack/non-Adwaita fonts tested (Liberation Mono, Nimbus Mono
PS — both very common on other Linux distros/KDE installs) are missing
*some* of the 8 eighths glyphs specifically (▁ and ▇), which would silently
degrade an 8-level sparkline to a smaller effective palette on a user's
machine with a different default monospace font than this one, via the
same fallback-substitution mechanism. Worth flagging even though it's not
this machine's problem today.

**(b) Advance width, once a font is confirmed to have the glyph, is exactly
as reliable as the task brief suspected it wasn't — measured, not assumed.**

For every font/character pair where the glyph genuinely exists in that
font, `QFontMetricsF.horizontalAdvance()` returned **the identical value**
as `horizontalAdvance("M")` in that same font, to the fourth decimal place,
across ASCII and every block-element character tested. A follow-up test
comparing `horizontalAdvance(ch) * N` (the naive "cells × per-cell-width"
math the reverted implementation used) against
`horizontalAdvance(ch.repeat(N))` (the whole-string measurement) for
N=40 showed **zero difference** in every font tested, for both ASCII and
block characters. At the `QFontMetrics` API level, on this Qt version,
advance width is not the mechanism that broke — this reproduces the "it's
not a bug, it's how advance width is defined" clarification from Qt's own
docs/forum guidance (horizontal advance intentionally includes
bearing/whitespace and is defined to be the correct quantity for laying
strings end-to-end; it is `tightBoundingRect`/ink-box width, a different
quantity, that legitimately differs from it — see Qt Center thread
"QFontMetrics boundingRect vs horizontalAdvance with monospaced fonts").

**(c) Where a real, measured discrepancy *does* show up: ink overshoot on
block glyphs specifically.** `tightBoundingRect(ch).width()` for block
elements (█▁▄▇ etc.) measured **~0.8–1px wider than the character's own
advance width**, consistently, in every font that has the glyphs (e.g.
Noto Sans Mono: advance 19.19px, ink bounding box 20.0px for `█`). ASCII
characters showed no such overshoot (ink box ≤ advance). This is not a Qt
bug — block-drawing glyphs are *designed* to paint edge-to-edge inside
their cell (so adjacent solid blocks tile without a visible seam), which
some fonts implement by letting the glyph's ink slightly exceed its
nominal advance box on one or both sides. Per-glyph this is small (under
1px) and doesn't compound across a row (each glyph's *origin* still
advances by the correct, uniform amount — only the very edge of the ink
can bleed past the last glyph's nominal boundary), but it is a genuine,
measured, non-hypothetical reason a row of block glyphs can paint
fractionally past a container computed as `count * advanceWidth` — just
not by anywhere near enough, on its own, to explain a bug described as
visibly overflowing the widget's container.

**(d) What this probe could *not* rule out, stated plainly:** this test
ran under `QT_QPA_PLATFORM=offscreen` with an assumed 1.0 device pixel
ratio and no live QML scene graph / `Text`-item-per-glyph layout — it is
not a reproduction of the actual failure, which happened inside a live
Plasma panel (real desktop, real compositor, `plasmoidviewer` confirmed
this machine's panel uses fractional-scaling-capable Plasma 6.7.5/Qt
6.11.2) using **one QML `Text` item per glyph inside a `Row`/manual
layout** — a meaningfully different code path than a single measured
string, because each `Text` item's own `implicitWidth`/`contentWidth` goes
through Qt Quick's separate text-node layout and rasterization pipeline,
not `QFontMetrics` directly, and per-item devicePixelRatio-driven pixel
rounding is a documented category of QML text-layout bug independent of
font choice: KDE bug 479891 ("Some text glyphs in QML software are
vertically mis-aligned or squished when using a fractional scale factor")
and QTBUG-55856 (FreeType + `NativeRendering` + non-1.0 scale factor
causing text clipping/scaling errors) both document exactly this class of
problem — per-glyph rounding drift under fractional display scaling,
independent of whether the glyph is ASCII, block, or anything else. This
is a **plausible compounding contributor to the original bug that this
research could not confirm or rule out empirically** (would need to
reproduce inside an actual running `plasmoidviewer`/panel session with a
`Repeater { Text { ... } }` layout at this machine's actual panel scale
factor, which was out of scope for this offscreen probe) — flagged here
as unconfirmed, per the task's own instruction to say so plainly rather
than overclaim.

### Do the reference tools bundle a font because of this exact problem?

**No — none of the three bundles a font.** But bashtop's README **does**
explicitly document the Unicode-block/font-coverage requirement as a
precondition the user must satisfy themselves (quoted above): "needs...a
font that covers" braille + geometric shapes + box-drawing/block-elements.
vtop and gtop's documentation say nothing about font requirements at all
(gtop's README only troubleshoots a locale/`TERM` issue for garbled
characters, not a font-coverage issue). Read together, this is a weak but
real signal: **the one tool whose docs discuss font coverage discusses it
as a glyph-coverage problem the terminal/font must solve ahead of time,
not a width-measurement problem the app's own layout code has to solve at
draw time** — because in a terminal, there is no draw-time width math to
get wrong (see §4).

## 3. Does a reusable library/algorithm already exist?

Yes, for the *algorithm*, no, for anything QML-native.

- **`node-drawille`** (JS) — the ~60-line reference implementation of the
  braille bitmask/offset technique, MIT-licensed, small enough to read in
  full (quoted almost entirely in §1 above) and trivial to port to
  QML/JavaScript logic directly — this is genuinely "read it once, you
  understand the whole algorithm," not a black box worth treating as a
  dependency.
- **`drawille-canvas-blessed-contrib`** — same algorithm, wrapped as a
  generic drawing-primitives canvas (lines, points, text) for
  `blessed-contrib`'s charts; more machinery than plasmatop would need
  (it targets arbitrary vector drawing, not just a rolling value history).
- **`sparkline` (npm, `johnpolacek`/`shiwano`-style packages)** — the
  block-element one-glyph-per-sample technique, small utility packages;
  algorithmically trivial (`Math.floor(value / max * (levels.length - 1))`
  indexing into a fixed glyph array) — not worth taking a dependency on
  even in JS-land, let alone porting.
- **Nothing QML-native was found.** Searched for existing QML/Qt Quick
  components implementing either technique (braille-canvas or
  block-sparkline) — none exist as a reusable library. `QtGraphs`/`QtCharts`
  (Qt's own charting modules, already ruled out in R3 for being
  architecturally heavier than needed) have no character-cell rendering
  mode; they draw vector/pixel graphics, not Unicode text-as-pixels. **A
  custom QML component would be required either way** if this is
  retried — this confirms rather than merely assumes the task brief's
  premise on that point.

## 4. Why the terminal tools don't have this bug at all — the structural insight

This is the single most load-bearing finding of this spike, and it's
worth stating plainly rather than leaving implicit: **every width/sizing
computation in all three tools' actual source is done in units of
terminal character-cell counts (plain integers — `stdout.columns`,
`stdout.rows`, a `width` argument bounds-checked with `is_int`) — never in
pixels, and never via anything resembling a font-metrics query.** grep
across all six cloned repositories (bashtop, vtop, node-drawille,
blessed-contrib, gtop, sparkline) found **zero** calls to any font-metrics
API, anywhere. This isn't an oversight in those tools — it's structurally
impossible for it to be a problem for them, because a terminal emulator's
fundamental contract with every application running inside it is that
*one printable character (outside explicit wide-CJK/emoji handling) occupies
exactly one fixed-width cell*, enforced by the terminal emulator itself,
not by the application. `create_meter()`'s `width` and `node-drawille`'s
`Canvas(width, height)` are already talking in a coordinate space (cells,
or 2×/4× subdivisions of cells) where "how wide is this glyph" is a
question with a contractually fixed, universally-true answer of exactly 1
(or, for drawille, exactly 1/2 or 1/4) — there is no font, no
`FontMetrics`, no measurement step, because the display layer itself
guarantees the grid.

**A QML/Plasma widget has no such contract.** QML's `Text`/`Canvas`
render into an arbitrary pixel-addressed surface where glyph advance width
is *only* as reliable as whatever `FontMetrics` (or the text layout
engine) reports for the specific font actually resolved at runtime — and
per §2, that resolution can (a) silently substitute a different font
per-glyph when the primary font lacks a codepoint, changing the
effective advance/rendered geometry per character with no signal to the
caller, and (b) go through Qt Quick's separate per-`Text`-item layout and
device-pixel-rounding path rather than a single clean `QFontMetrics`
string measurement, especially under fractional display scaling (§2d).
**The earlier plasmatop bug wasn't "block characters have unreliable
advance width" in the abstract — the measured data here says a real
monospace font's advance width for block glyphs is exactly as reliable as
for ASCII, on this Qt version.** The bug was attempting to recreate a
terminal's fixed-grid guarantee inside a rendering environment that
doesn't provide one, using a per-glyph layout technique (one `Text` item
per cell) that is more exposed to Qt Quick's own known
fractional-scaling/rounding rough edges (§2d) than the single-measurement
API-level test performed here.

## 5. Recommendation

**Retry, but narrowly, and only for the specific glyph set already proven
safe on this machine — not braille.**

- **Don't use braille.** The task brief's premise that braille might be
  the safer choice is not supported by this system's actual font
  situation: this machine's `"monospace"` alias has *zero* braille
  coverage, versus full block-element coverage. Braille would immediately
  reintroduce an even more basic failure mode than the one being fixed —
  missing glyphs entirely, silently substituted by fallback — for no
  offsetting reliability benefit, since advance width was never actually
  the unreliable part (§2b). Braille's real advantage (2×4 sub-cell
  resolution, continuous-looking lines via the transition-glyph lookup
  table technique bashtop/btop use) is a genuine visual upgrade over
  block-per-sample, but it's not worth taking on a glyph-availability
  regression to get it, and it isn't what caused or would fix the
  original bug.
- **Do retry block elements (`█░▁▂▃▄▅▆▇`)** specifically, since (a) full
  coverage plus correct, non-drifting advance width for exactly this
  glyph set was empirically confirmed on this machine's resolved
  `"monospace"` font (Noto Sans Mono) in this project's actual Qt version,
  and (b) it's the visual language the product owner explicitly asked
  for. A custom QML component is required regardless (§3 confirms nothing
  QML-native exists) — this was already correctly assumed by the earlier
  implementation and by the task brief, and stands confirmed.
- **The concrete precaution, to specifically not repeat the original
  bug:** stop trusting a single `FontMetrics.advanceWidth(oneChar) × N`
  computation as the source of truth for total row width, and instead
  size the row using **one whole-string measurement** —
  `FontMetrics.advanceWidth(charSequence.repeat(N))` (proven exactly
  equal to the per-char sum at the `QFontMetrics` level in §2b, so this
  isn't about correcting a math error) — combined with **not laying the
  row out as N independent QML `Text` items each trusting its own
  `implicitWidth`**, which is the part this research could not rule out
  as the real, more insidious culprit (§2d, KDE bug 479891/QTBUG-55856).
  Concretely: render the whole visible glyph sequence as **one `Text`
  item with one `text` string** (`"█▓▓░░░░░"`-style, built via JS string
  concatenation, not a `Repeater`), and size/clip the *container* to that
  single item's own `contentWidth`/`paintedWidth` after the fact, rather
  than pre-computing how many characters "should" fit from a per-glyph
  width estimate and hoping the render matches the estimate. This
  sidesteps both (a) any residual per-glyph ink-overshoot (§2c) — which
  only matters if you're trying to predict width in advance, not if you
  measure the assembled string directly — and (b) the per-`Text`-item
  fractional-scaling rounding class of bug, since there's only one text
  node's layout to worry about, not N independently-rounded ones. If a
  gradient per-character color is still wanted (the original design
  intent, matching bashtop's/btop's per-column coloring), that requires
  either (i) accepting a coarser granularity — a handful of colored
  `Text` runs via rich text/`StyledText`, each run short enough that
  inter-run rounding error stays visually negligible, rather than N
  single-character items, or (ii) reverting to the already-proven-cheap
  `Rectangle`-per-segment approach from R3 for the color ramp and
  layering monospace block-character *text* on top purely as a cosmetic
  overlay whose width is allowed to be approximate/clipped, rather than
  the layout-authoritative element. Either way: **before calling it done,
  verify empirically on the real panel** (per this project's own
  `AGENTS.md` rule) with the widget genuinely narrow/constrained, not just
  a clean `plasmoidviewer` load — the original bug was specifically an
  overflow that only showed up "on the real desktop," which this
  project's own history has now demonstrated twice (the `AsciiBox` font
  duplicate-property bug in Sprint 1 also passed automated
  `plasmoidviewer` checks and only broke live) is a real, recurring gap in
  this project's own verification process, not just a font-metrics
  quirk — treat that as the actual process fix, independent of which
  glyph technique is chosen.

## 6. Follow-up: could bundling/using a real braille-covering font change the recommendation?

Product owner's question: since braille would match vtop/bashtop/gtop's
actual technique (§1), why not just use or bundle a font with real
braille coverage instead of relying on this machine's default (Noto Sans
Mono, confirmed in §2 to have none)? Re-ran with the same empirical
rigor: real font files probed on this machine, not assumption, including
a genuine QML `FontLoader` test (not just Python `QFontMetricsF`) this
time.

### 6.1 Is a good braille-covering monospace font already installed?

Checked the candidates named in the follow-up via `fc-list`: **DejaVu Sans
Mono, JetBrains Mono, Cascadia Code/Mono, Fira Code, and any Nerd Font
variant are not installed on this machine at all** — every `fc-list`
query returned zero matches. So none of those specific suggestions are
usable here without bundling.

**However, one font from the *first* pass's own test set already covers
braille and was overlooked as "the answer" until this follow-up: Adwaita
Mono** (package `adwaita-mono-fonts`, already confirmed present in §2's
table). Re-checking that table: Adwaita Mono is the *only* one of the five
fonts tested in §2 with `in_font=True` for every braille codepoint tried,
alongside full block-element coverage and a consistent advance-width ratio
of exactly `1.0000` across ASCII, block, and braille glyphs alike. It's
installed on this Fedora 44 machine already (`rpm -q adwaita-mono-fonts`
→ present, part of the GNOME/Adwaita design system Fedora ships by
default), license `SIL OFL-1.1` (permissive, redistributable, standard
font-bundling license — no issue either way).

**Surprise finding that corrects a premise in the question:** DejaVu Sans
Mono's reputation for "historically excellent" Unicode coverage does
**not** extend to Braille Patterns. Verified two independent ways after
downloading the actual font file (via `dnf download dejavu-sans-mono-fonts`
— fetched without installing it system-wide, then extracted with
`rpm2cpio`/`cpio`, so this didn't touch this machine's font configuration):
(a) `fc-scan --format '%{charset}'` directly on the `.ttf` file shows
coverage of `2500-262f` (box drawing + block elements + geometric shapes)
but **no `28xx` range at all**; (b) loading the same file into a live Qt
process via `QFontDatabase.addApplicationFont()` and querying
`QFontMetricsF.inFontUcs4()` for five different braille codepoints
returned `False` for every one. Both checks agree: **DejaVu Sans Mono
(the standalone Mono family specifically, not necessarily the full DejaVu
Sans coverage some other DejaVu variants may have) does not have braille
glyphs.** Bundling it would not have solved the product owner's ask —
worth stating plainly since it was named as the presumed safe default.
License, for the record since it was asked about anyway: Fedora's package
metadata lists `Bitstream-Vera AND LicenseRef-Fedora-Public-Domain`; the
actual `LICENSE` file is the classic Bitstream Vera font license —
permissive, allows reproduction/distribution/bundling, with the one
standard restriction that a *modified* font can't keep the "Bitstream" or
"Vera" name. Fine to bundle, just moot here since it lacks the glyphs.

### 6.2 Advance-width consistency for braille, under a font that actually has it

Ran the same two checks as §2 (per-glyph advance vs. the font's own `M`
baseline, and whole-string-vs-naive-sum for a 40-character run), this time
against Adwaita Mono specifically, via **two separate mechanisms** for
extra rigor: the Python `QFontMetricsF` probe from pass 1, and — new this
pass — a genuine **QML `FontLoader` + `FontMetrics` test**, run through a
real `QQmlApplicationEngine` (PySide6 6.11.2, matching this project's Qt
6.11.2), because the follow-up specifically asked not to trust
general-docs knowledge for the QML-level mechanism.

The QML test loaded the font from a local file, exactly the pattern a
bundled `contents/ui/fonts/<file>.ttf` + `Qt.resolvedUrl()` reference
would use in the actual plasmoid:

```qml
FontLoader { id: bundledFont; source: "file:///usr/share/fonts/adwaita-mono-fonts/AdwaitaMono-Regular.ttf" }
FontMetrics { id: fm; font.family: bundledFont.name; font.pixelSize: 20 }
```

Live result (`bundledFont.name` resolved to `"Adwaita Mono"`,
`fm.font.family` picked it up correctly):

```
'M' advanceWidth=11.984375
ascii M            advanceWidth=11.984375 ratio=1.0000
block full U+2588  advanceWidth=11.984375 ratio=1.0000
braille dot1 U+2801 advanceWidth=11.984375 ratio=1.0000
braille full U+28FF advanceWidth=11.984375 ratio=1.0000
braille mid U+283F  advanceWidth=11.984375 ratio=1.0000
row(8 braille) advanceWidth=95.875  naive(single*8)=95.8750   <- exact match, zero drift
```

This directly confirms, via the real QML API a component would actually
call (not just the C++/Python `QFontMetricsF` equivalent): **once a font
genuinely contains the braille glyphs, braille's advance width is exactly
as reliable as block elements' — identical per-glyph ratio to the ASCII
baseline, and zero cumulative drift across an 8-glyph row.** This matches
§2b's finding for block elements under Noto Sans Mono; braille under
Adwaita Mono behaves the same way. The Python-level tight-bounding-box
check from pass 1 additionally showed braille glyphs render *narrower*
than their advance box in Adwaita Mono (dot1 ≈ 6px ink in a ~19px cell at
32px test size) rather than block elements' slight *overshoot* (§2c) — so
if anything, braille carries less overflow risk than block elements once
the font actually has the glyphs, not more.

### 6.3 Bundling feasibility (for portability beyond this machine)

Not strictly needed on *this* machine (Adwaita Mono is already present),
but the underlying concern — this widget running on a KDE/Fedora install
that didn't happen to pull in the GNOME/Adwaita font stack, or a non-
Fedora distro entirely — is legitimate, so this was checked anyway:

- **License is not a blocker** for any of the candidates discussed
  (Adwaita Mono: OFL-1.1; DejaVu Sans Mono: Bitstream Vera license) —
  both are standard, redistribution-friendly font licenses already
  described as fine for bundling in R3 §3's discussion of JetBrains
  Mono/Nerd Fonts.
- **The `FontLoader` mechanism itself works correctly** for this exact use
  case, confirmed empirically in §6.2 above via a real QML engine, not
  assumed from documentation: a `file://`-sourced `FontLoader` resolves
  `.name` correctly, and binding a `FontMetrics`/`Text.font.family` to
  that resolved name produces correct, consistent metrics including for
  characters outside the font's ASCII baseline. This project already
  established the identical local-file-path resolution pattern for
  bundled *scripts* (`Qt.resolvedUrl("scripts/gpu-stats.sh").toString()
  .replace("file://", "")`, per `ARCHITECTURE.md`) — the same mechanism
  applies to a bundled font file under `contents/ui/fonts/`, referenced as
  `FontLoader { source: Qt.resolvedUrl("fonts/AdwaitaMono-Regular.ttf") }`
  with no `file://`-stripping needed since `FontLoader.source` accepts a
  URL directly. **What this research did not test** is the fully-packaged
  case specifically inside `plasmoidviewer`/a live Plasma panel (package
  asset resolution inside Plasma's own packaging layer, as opposed to a
  bare `QQmlApplicationEngine`) — flagged as the one remaining
  not-yet-verified step before treating this as fully proven, consistent
  with this project's own repeated lesson (§5, Sprint 1) that
  `plasmoidviewer`-clean is not the same as live-panel-clean.
- **Practical cost**: Adwaita Mono's regular-weight file is small (a
  single `.ttf`, roughly the size of any other system monospace font,
  sub-1MB), so package-size impact of bundling would be negligible if it
  ever became necessary; one-time load cost is a single `FontLoader`
  parse at widget startup, not a per-frame cost.

### 6.4 Updated recommendation

**Yes — this changes the recommendation.** Braille is now the better
choice, specifically *because* a real, currently-installed,
permissively-licensed font (Adwaita Mono) has full coverage and
confirmed-reliable, non-overflowing advance width for it on this exact
machine, and the same font is trivially bundleable for portability if a
future target machine lacks it. This isn't a reversal driven by new doubt
about block elements (§2b/§2c still stand — block elements under Noto
Sans Mono are also safe on this machine) — it's that braille via Adwaita
Mono is safe **and** strictly better on every axis that mattered for the
original bug and for matching the product owner's actual stated
reference (vtop/bashtop/gtop all use braille, not block elements, for
their *history graphs* specifically — see §1's bashtop `create_graph_hires`
and vtop/gtop's shared `drawille` dependency):

- **Resolution/density**: braille's 2×4 sub-cell dot grid gives 8x the
  data points per character cell versus one glyph per sample — a sparkline
  showing the same time window renders visibly smoother/denser, or the
  same visual density fits in a narrower panel widget. This is a real,
  concrete visual upgrade block elements structurally cannot match (block
  elements can vary height in 8 steps per glyph but each glyph is still
  exactly one time-sample; braille varies both height *and* packs two
  time-samples' worth of horizontal sub-position into one glyph via the
  transition-glyph lookup technique bashtop uses, §1).
- **No font-metrics regression**: §6.2's live QML test found braille
  exactly as advance-width-stable as block elements, under a font that
  actually has the glyphs — so retrying braille via Adwaita Mono carries
  no more of the original risk than retrying block elements via Noto Sans
  Mono would.
- **Legibility caveat, stated honestly**: braille dots are visually
  smaller/finer than a solid block fill at the same pixel cell size (§6.2's
  ink-width note: dots render narrower than their advance box, meaning at
  very small panel font sizes — this project's panel/compact
  representation runs at a notably smaller pixel size than the full
  desktop representation — individual dots risk being nearly
  imperceptible or anti-aliasing into a grey smear rather than reading as
  a crisp graph line. This is a real tradeoff visual-QA needs to check at
  the actual compact-panel size on the real display, not something this
  research can settle from font metrics alone. Block elements' larger,
  solid fill areas are inherently more robust at small sizes.
- **Practical recommendation**: use **braille (via `Adwaita Mono`,
  bundled under `contents/ui/fonts/` for portability rather than relying
  on it happening to be pre-installed) for the `Sparkline`/history-graph
  component specifically** — where the density upgrade matters and
  matches the reference tools' own actual choice for that exact widget
  shape — while **keeping block elements (or the already-safe
  `Rectangle`-fill approach) for `BarMeter`'s single-value percentage
  bar**, where braille's sub-cell resolution buys nothing (a percentage
  meter has one value, not a time series) and a solid fill reads more
  clearly at a glance regardless of font. This mirrors blessed-contrib's
  own split (§1: braille-via-drawille for its `line` chart, plain block
  characters for its simpler `sparkline` widget) rather than forcing one
  technique to do both jobs. Whichever glyph is used for the sparkline,
  the layout precaution from §5 still applies unchanged: one whole-string
  `Text` measurement, not one `Text` item per glyph, and a real on-panel
  visual check before calling it done — the glyph choice made here did
  not change that part of the answer.
