/*
    Sparkline.qml — shared/theme

    Braille-character rolling history graph, per research/r4-terminal-
    graph-rendering.md §6 (the "should we bundle a braille-covering font"
    follow-up) and reworked per Epic 1.7 (research/r7-bashtop-detailed-
    visual-reference.md) into a MIRRORED, DUAL-VALUE, FILLED-AREA graph:

    - Two independent series share one graph area, split at a horizontal
      center line: "peak" grows UP from center, "valley" grows DOWN from
      center. This is bashtop's own NET-BOX pattern (two genuinely
      different values sharing one mirrored primitive), not its CPU-box
      pattern (one value mirrored against itself) -- confirmed as a real
      bashtop pattern by R7 §2, chosen deliberately for plasmatop-gpu's
      utilization (peak)/VRAM% (valley) pairing since those are two
      different metrics, not one value shown twice.
    - Both halves are SOLID FILLED areas from the center line out to each
      column's value (R7 §3: bashtop's graph is a filled area, never a
      stroked/outlined line) -- not the old line-tracing-a-boundary
      approach.
    - Each half still renders via the same braille dot-grid technique as
      before (Unicode 0x2800 + 8-bit dot bitmask, 2x4 sub-pixel resolution
      per character cell) -- vtop/gtop/bashtop's actual rendering
      technique (R4), just now filling a half-height region per column
      instead of marking one boundary dot.

    Font: this machine's default "monospace" (Noto Sans Mono, confirmed in
    R4 §2) has ZERO braille glyph coverage -- would silently font-fallback
    per glyph. Adwaita Mono (bundled at shared/theme/fonts/, OFL-1.1) has
    full braille coverage and measured advance-width-identical to ASCII/
    block glyphs in a real QML FontLoader+FontMetrics test (R4 §6.2), so it
    is used HERE ONLY, via FontLoader -- BarMeter and every other label in
    this project deliberately keep the system "monospace" family.

    Per R4 §5's hard-won precaution (this is the second time a character-
    based graph was attempted in this project -- see git history/SPRINTS.md
    for the first, reverted attempt): render the WHOLE dot grid as ONE Text
    item with ONE string (rows newline/<br>-joined), never one Text item
    per glyph/row-cell via a Repeater -- that per-item layout path is what's
    suspected (KDE#479891 / QTBUG-55856) to have caused the original
    overflow bug, not font-metrics unreliability (measured reliable both
    times now).

    --- Color-flicker fix (Epic 1.7, root cause confirmed by R7 §4) -------

    R7 read bashtop's actual source: it colors each graph ROW once, at
    graph creation/resize, from a static value-to-color LUT, and NEVER
    recomputes color on the routine per-sample "add one column" path --
    only geometry (which rows a new column's glyph reaches) changes per
    sample. plasmatop's previous implementation recomputed color from
    resampled/rescaled history on EVERY render call, which is the actual
    flicker mechanism (not just "small dot grid resampling jitter" as
    originally suspected in BACKLOG.md).

    The fix applied here: each history sample's color is computed EXACTLY
    ONCE, at the moment it's pushed (pushValue()) or bulk-hydrated
    (setHistory()), from that sample's OWN value against the *current*
    goodMax/warnMax/color settings -- and stored alongside the raw value
    in that sample's history slot (`{v, colorHex}`). Height-band thresholds
    still come from the EXISTING configurable ColorScale goodMax/warnMax
    mechanism (one instance per channel -- see peakColorScale/
    valleyColorScale below), not a new/second threshold system, per Epic
    1.7's explicit instruction. Render-time (_buildBrailleText) NEVER calls
    colorForFraction() again -- it only ever READS a previously-stored
    colorHex. The one thing render-time still resamples is which stored
    sample a given screen COLUMN currently points at (nearest-sample
    lookup, same as before) and the smooth interpolated FILL HEIGHT
    boundary between neighboring samples (plain numeric interpolation of
    `.v`, not of color) -- neither of those re-derives a color from a
    value, so a given sample's color, once assigned, cannot change on a
    later render no matter how its on-screen column position shifts as
    history scrolls.

    Granularity is per CHARACTER COLUMN (not per individual dot): all rows
    within one column's peak half share that column's one peak color, and
    all rows within its valley half share that column's one valley color --
    the finest unit a color change could usefully read as at this glyph
    size.

    Usage:
        Sparkline {
            id: utilVramGraph
            maxValue: 100          // peak (utilization) scale
            valleyMaxValue: 100    // valley (VRAM%) scale
            goodMax: 0.6; warnMax: 0.85             // peak thresholds
            valleyGoodMax: 0.6; valleyWarnMax: 0.85 // valley thresholds
            width: 140; height: 48
        }
        // on each new data tick (both values together -- see pushValue()):
        utilVramGraph.pushValue(utilizationPercent, vramUsedPercent)
        // bulk hydration (e.g. Component.onCompleted after a popup
        // reopen), same shape:
        utilVramGraph.setHistory(utilHistoryArray, vramHistoryArray)
*/

import QtQuick

Item {
    id: root

    // How many samples to keep/display. Peak and valley histories are
    // always the same length -- pushValue()/setHistory() keep them in
    // lockstep, index-for-index (slot i's peak/valley sample were always
    // supplied together in one call).
    property int historyLength: 60

    // --- Peak (upper half) series: scale + thresholds -----------------------
    property real maxValue: 100
    property alias goodMax: peakColorScale.goodMax
    property alias warnMax: peakColorScale.warnMax

    // --- Valley (lower half) series: scale + thresholds ----------------------
    // Independent metric, independent scale/thresholds -- e.g. utilization
    // (peak, 0-100%) mirrored against VRAM% (valley, 0-100%) can still want
    // different good/warn cutoffs even though both happen to be percents.
    property real valleyMaxValue: 100
    property alias valleyGoodMax: valleyColorScale.goodMax
    property alias valleyWarnMax: valleyColorScale.warnMax

    // Shared good/warn/bad COLORS across both channels -- ARCHITECTURE.md's
    // "one shared color set per widget, only threshold VALUES are
    // per-metric" rule. Plain bindings (not property alias) below, since a
    // QML alias can only ever target one underlying property and both
    // ColorScale instances need to track the same three colors.
    property color goodColor: "#77ca9b"
    property color warnColor: "#cbc06c"
    property color badColor: "#dc4c4c"

    // Fallback color for the rare case _brailleText is empty markup (no
    // data pushed yet) -- the Text item's plain `color:` property, almost
    // never actually visible since real content is always emitted as
    // per-run <font color> markup.
    property color fallbackColor: goodColor

    // Background track, matching BarMeter's visual language, so the
    // sparkline reads as a bounded graph area even when both traces hug
    // the center (e.g. idle utilization and idle VRAM%, few samples yet).
    property color trackColor: "#2a2a2a"

    // Pixel size for the braille glyphs. Deliberately NOT tied to any
    // other font size in this widget (BarMeter/AsciiBox use the system
    // "monospace" family, this uses the bundled font) -- smaller values
    // pack more character rows/cols (= more dot resolution) into the same
    // item size at the cost of legibility.
    property int braillePixelSize: 12

    // Parallel rolling histories, index-aligned. Each entry is
    // `{v: <raw value>, colorHex: <"#rrggbb" computed once at push time>}`
    // -- see file header for why colorHex is never recomputed later.
    property var _peakHistory: []
    property var _valleyHistory: []
    property string _brailleText: ""

    implicitWidth: 72
    implicitHeight: 24

    ColorScale {
        id: peakColorScale
        goodColor: root.goodColor
        warnColor: root.warnColor
        badColor: root.badColor
    }
    ColorScale {
        id: valleyColorScale
        goodColor: root.goodColor
        warnColor: root.warnColor
        badColor: root.badColor
    }

    // Bundled font -- see file header. Path is relative to THIS file
    // (shared/theme/Sparkline.qml, symlinked as contents/ui/theme/ in
    // every widget package per ARCHITECTURE.md's layout), so the font
    // lives once at shared/theme/fonts/ and is automatically available to
    // every widget that uses Sparkline, with no per-widget copy needed.
    FontLoader {
        id: brailleFontLoader
        source: Qt.resolvedUrl("fonts/AdwaitaMono-Regular.ttf")
        onStatusChanged: if (status === FontLoader.Error) {
            console.warn("Sparkline: failed to load bundled braille font from", source);
        }
    }

    // fontFamily falls back to "monospace" if the bundled font hasn't
    // finished loading yet (KConfigXT-style async-load race, same shape as
    // every Plasmoid.configuration read elsewhere in this project) --
    // "monospace" has no braille coverage on this machine (R4 §2), so this
    // fallback is a "don't crash/blank" safety net, not a real braille
    // rendering path; brailleFontMetrics is what actually drives the grid
    // math and is recomputed once the real font resolves.
    readonly property string _fontFamily: brailleFontLoader.name || "monospace"

    FontMetrics {
        id: fm
        font.family: root._fontFamily
        font.pixelSize: root.braillePixelSize
    }

    // Whole-glyph advance width/row height, used to plan the dot grid.
    // Per R4 §2b/§6.2, single-glyph FontMetrics.advanceWidth() is exactly
    // as reliable as a whole-string measurement for a real monospace font.
    readonly property real _charAdvance: Math.max(1, fm.advanceWidth("⣿"))
    readonly property real _lineHeight: Math.max(1, fm.height)

    readonly property int _charCols: Math.max(0, Math.floor(width / _charAdvance))
    readonly property int _charRows: Math.max(0, Math.floor(height / _lineHeight))
    readonly property int _dotCols: _charCols * 2

    Rectangle {
        anchors.fill: parent
        radius: 0
        color: root.trackColor
    }

    // Center-line hint: a thin divider exactly where the peak half meets
    // the valley half, so a near-zero reading on both channels still reads
    // as "a graph with two sides" rather than an empty box. Purely
    // cosmetic, drawn UNDER the braille text.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: root._charRows > 0 ? Math.ceil(root._charRows / 2) * root._lineHeight : 0
        height: 1
        color: Qt.rgba(1, 1, 1, 0.08)
    }

    Text {
        id: brailleDisplay
        anchors.left: parent.left
        anchors.top: parent.top
        width: root._charCols * root._charAdvance
        height: root._charRows * root._lineHeight
        // Safety net (not the structural fix -- the grid math above is)
        // against ever painting past the container, per this project's
        // repeated real-desktop-overflow history (R4 §5).
        clip: true
        font.family: root._fontFamily
        font.pixelSize: root.braillePixelSize
        // Explicit fixed row height, matching exactly what _charRows/
        // _lineHeight above assumed when planning the grid, rather than
        // trusting the font's own natural multi-line leading to match.
        lineHeight: root._lineHeight
        lineHeightMode: Text.FixedHeight
        color: root.fallbackColor
        // StyledText (not plain text): _brailleText carries inline
        // <font color="#rrggbb"> runs for per-column coloring (see file
        // header) -- StyledText is Qt's fast, restricted rich-text subset
        // that supports exactly this, without the cost of full HTML
        // parsing. Still ONE Text item, ONE string -- no Repeater, per the
        // file header's hard rule.
        textFormat: Text.StyledText
        text: root._brailleText
        style: Text.Outline
        styleColor: "#000000"
    }

    onWidthChanged: _render()
    onHeightChanged: _render()

    // Two-hex-digit clamp/round helper for _colorToHex() below.
    function _hex2(n) {
        const s = Math.round(Math.max(0, Math.min(255, n * 255))).toString(16);
        return s.length < 2 ? "0" + s : s;
    }

    function _colorToHex(c) {
        return "#" + _hex2(c.r) + _hex2(c.g) + _hex2(c.b);
    }

    // The ONLY two places colorForFraction() is ever called -- both at
    // push/hydrate time, never at render time. See file header.
    function _peakColorHexFor(value) {
        return _colorToHex(peakColorScale.colorForFraction(root.maxValue > 0 ? value / root.maxValue : 0));
    }
    function _valleyColorHexFor(value) {
        return _colorToHex(valleyColorScale.colorForFraction(root.valleyMaxValue > 0 ? value / root.valleyMaxValue : 0));
    }

    /*!
        Append one new sample to BOTH rolling histories (dropping the
        oldest pair once historyLength is exceeded) and re-render.
        \a valleyValue defaults to 0 if omitted, for a caller that only
        ever wants a peak-only graph (mirrors to an empty valley half).
    */
    function pushValue(peakValue, valleyValue) {
        if (valleyValue === undefined) {
            valleyValue = 0;
        }
        root._peakHistory.push({ v: peakValue, colorHex: root._peakColorHexFor(peakValue) });
        root._valleyHistory.push({ v: valleyValue, colorHex: root._valleyColorHexFor(valleyValue) });
        while (root._peakHistory.length > root.historyLength) {
            root._peakHistory.shift();
            root._valleyHistory.shift();
        }
        _render();
    }

    function clear() {
        root._peakHistory = [];
        root._valleyHistory = [];
        _render();
    }

    /*!
        Replace both histories in one go (trimmed to the most recent
        historyLength samples) and re-render once -- for
        Component.onCompleted hydration when the full representation is
        recreated (e.g. popup close/reopen). \a valleyValues may be
        shorter/omitted; missing valley samples default to 0.
    */
    function setHistory(peakValues, valleyValues) {
        const pv = (peakValues || []).slice(-root.historyLength);
        const vvFull = valleyValues || [];
        const vv = vvFull.slice(-pv.length);
        root._peakHistory = pv.map(v => ({ v: v, colorHex: root._peakColorHexFor(v) }));
        root._valleyHistory = pv.map((_, i) => {
            const vy = vv[i] !== undefined ? vv[i] : 0;
            return { v: vy, colorHex: root._valleyColorHexFor(vy) };
        });
        _render();
    }

    // --- Braille dot-grid rendering -----------------------------------------

    function _render() {
        root._brailleText = _buildBrailleText();
    }

    /*!
        Renders the mirrored dual-value filled-area graph: the top
        ceil(charRows/2) character rows are the PEAK half (fills upward
        from the center line), the bottom rows are the VALLEY half (fills
        downward from the center line). Returns the whole grid as one
        newline(<br>)-joined StyledText string -- one Text item, one
        string, per the file header's hard rule.
    */
    function _buildBrailleText() {
        const charCols = root._charCols;
        const charRows = root._charRows;
        const dotCols = root._dotCols;
        const peak = root._peakHistory;
        const valley = root._valleyHistory;

        if (charCols < 1 || charRows < 1 || peak.length < 1) {
            return "";
        }

        const charRowsPeak = Math.ceil(charRows / 2);
        const charRowsValley = charRows - charRowsPeak;
        const dotRowsPeak = charRowsPeak * 4;
        const dotRowsValley = charRowsValley * 4;

        const cells = new Array(charCols * charRows).fill(0);
        const cellColors = new Array(charCols * charRows).fill(null);
        // Dot numbering matches the real Unicode braille layout (verified
        // against node-drawille's map, R4 §1):
        //   dot1 0x01  dot4 0x08      1 4
        //   dot2 0x02  dot5 0x10      2 5
        //   dot3 0x04  dot6 0x20      3 6
        //   dot7 0x40  dot8 0x80      7 8
        const dotBit = [
            [0x01, 0x08],
            [0x02, 0x10],
            [0x04, 0x20],
            [0x40, 0x80]
        ];

        function setDot(cellRow, cellCol, subRow, subCol) {
            if (cellRow < 0 || cellRow >= charRows || cellCol < 0 || cellCol >= charCols) {
                return;
            }
            cells[cellRow * charCols + cellCol] |= dotBit[subRow][subCol];
        }

        // Right-align a partially-filled buffer to the right edge (newest
        // sample at the right, growing in from the right as history
        // accumulates) -- same visual behavior as before, generalized from
        // "slot index" to continuous dot-column space.
        const totalSlots = Math.max(root.historyLength, peak.length);
        const startSlot = totalSlots - peak.length;

        function slotPosForDotX(x) {
            return totalSlots > 1 ? (x / Math.max(1, dotCols - 1)) * (totalSlots - 1) : startSlot;
        }

        // Linearly interpolates a smooth FILL BOUNDARY between neighboring
        // samples' raw values -- geometry only, never touches color (see
        // file header: color is a separate, nearest-sample, stored-value
        // lookup below).
        function interpolatedValue(history, slotPos) {
            const hPos = slotPos - startSlot;
            const i0 = Math.max(0, Math.min(history.length - 1, Math.floor(hPos)));
            const i1 = Math.max(0, Math.min(history.length - 1, Math.ceil(hPos)));
            const t = hPos - Math.floor(hPos);
            return history[i0].v + (history[i1].v - history[i0].v) * t;
        }

        // --- Fill boundary heights, per dot-column --------------------------
        for (let x = 0; x < dotCols; x++) {
            const slotPos = slotPosForDotX(x);
            const cellCol = Math.floor(x / 2);
            const subCol = x % 2;

            if (dotRowsPeak > 0) {
                const v = interpolatedValue(peak, slotPos);
                const frac = root.maxValue > 0 ? Math.max(0, Math.min(1, v / root.maxValue)) : 0;
                const filled = Math.round(frac * dotRowsPeak);
                for (let d = 0; d < filled; d++) {
                    // d = distance from the center line (0 = row nearest
                    // center); dotRowTop = row index within the peak half,
                    // measured from the TOP of that half.
                    const dotRowTop = dotRowsPeak - 1 - d;
                    setDot(Math.floor(dotRowTop / 4), cellCol, dotRowTop % 4, subCol);
                }
            }

            if (dotRowsValley > 0) {
                const v = interpolatedValue(valley, slotPos);
                const frac = root.valleyMaxValue > 0 ? Math.max(0, Math.min(1, v / root.valleyMaxValue)) : 0;
                const filled = Math.round(frac * dotRowsValley);
                for (let e = 0; e < filled; e++) {
                    // e = distance from the center line (0 = row nearest
                    // center, i.e. the TOP row of the valley half).
                    setDot(charRowsPeak + Math.floor(e / 4), cellCol, e % 4, subCol);
                }
            }
        }

        // --- Per-CHARACTER-COLUMN color, nearest-sample, already stored ----
        // (computed once at push/setHistory time -- see file header). Every
        // row within a column's peak half shares that column's peak color;
        // every row within its valley half shares that column's valley
        // color.
        for (let cx = 0; cx < charCols; cx++) {
            const centerDotX = cx * 2 + 0.5;
            const slotPos = slotPosForDotX(centerDotX);
            let hIndex = Math.round(slotPos - startSlot);
            hIndex = Math.max(0, Math.min(peak.length - 1, hIndex));
            const peakHex = peak[hIndex].colorHex;
            const valleyHex = valley[hIndex] ? valley[hIndex].colorHex : peakHex;
            for (let cy = 0; cy < charRowsPeak; cy++) {
                cellColors[cy * charCols + cx] = peakHex;
            }
            for (let cy = charRowsPeak; cy < charRows; cy++) {
                cellColors[cy * charCols + cx] = valleyHex;
            }
        }

        // --- Emit ONE StyledText string, colored via <font> runs ------------
        // Consecutive same-color columns in a row are grouped into a
        // single run to keep the markup compact.
        const rows = new Array(charRows);
        for (let ry = 0; ry < charRows; ry++) {
            let rowMarkup = "";
            let runColor = null;
            let runText = "";
            for (let rx = 0; rx < charCols; rx++) {
                const idx = ry * charCols + rx;
                const glyph = String.fromCodePoint(0x2800 + cells[idx]);
                const hex = cellColors[idx];
                if (hex === runColor) {
                    runText += glyph;
                } else {
                    if (runColor !== null) {
                        rowMarkup += '<font color="' + runColor + '">' + runText + '</font>';
                    }
                    runColor = hex;
                    runText = glyph;
                }
            }
            if (runColor !== null) {
                rowMarkup += '<font color="' + runColor + '">' + runText + '</font>';
            }
            rows[ry] = rowMarkup;
        }
        return rows.join("<br>");
    }
}
