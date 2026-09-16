/*
    BarMeter.qml — shared/theme

    btop-style SEGMENTED bar meter: a background "track" Rectangle plus a
    row of small discrete Rectangle segments, each individually colored via
    ColorScale by its own position along the bar. No Canvas -- bound
    Rectangle geometry is strictly cheaper than immediate-mode drawing, and
    it's reliable across fonts (unlike a character-cell meter, where
    box-drawing/block glyphs don't render at a consistent width across
    monospace fonts -- tried that approach and it overflowed its container
    on the real desktop).

    Segmented, not smooth gradient (Epic 1.7, research/r7-bashtop-detailed-
    visual-reference.md §1): real bashtop's `create_meter` emits one
    discrete `■` block per terminal COLUMN of the meter's actual width --
    segment count is `floor(track_width / segment_pitch)`, continuously
    proportional to the bar's real pixel width (R7 measured 10/15/25
    segments across three differently-sized real bars), NOT a fixed
    "5 when small, 10 when large" switch. Reproduced here via
    `segmentWidth`/`segmentGap` (defaults 6px/2px, i.e. an 8px pitch --
    picked as a reasonable middle ground; not tuned to any specific
    hardcoded breakpoint) and `Math.floor(width / pitch)`, so the segment
    count naturally falls out of however wide this instance's track ends up
    being, recomputed live on resize via ordinary QML width bindings.

    Each segment's color comes from `colorForFraction((index + 1) / count)`
    -- colored by ITS OWN POSITION along the bar, exactly like bashtop's
    `colors[i*100/width]` lookup (R7 §1), not by the bar's current overall
    value. Unfilled segments are simply not drawn (the track Rectangle
    behind them already reads as the "dim/inactive" fill bashtop draws
    there, so a second explicit dim-colored Rectangle per unfilled segment
    would be a redundant layer for no visible difference at this size).

    The `Repeater { model: segments.count }` below is a plain INTEGER
    model, not a JS array -- this is unrelated to the Repeater/modelData
    staleness bug documented in MetricRow.qml/AGENTS.md (that bug is
    specifically about Repeater failing to notice a NEW array object of
    the same length reassigned to `model` every tick). Every delegate
    binding here reads Repeater's own built-in `index` role plus ordinary
    reactive `root`/`segments` properties directly -- no external modelData
    array is involved, so normal QML change propagation applies, the same
    as every other bound property in this project.

    Usage:
        BarMeter {
            value: gpuUtilPercent   // 0..100
            maxValue: 100
            label: gpuUtilPercent.toFixed(0) + "%"
        }
*/

import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: root

    // Raw value and its maximum; the bar fills to value/maxValue, clamped to
    // [0,1]. For already-normalized data, pass value in [0,1] and leave
    // maxValue at its default of 1.
    property real value: 0
    property real maxValue: 1
    readonly property real ratio: maxValue > 0 ? Math.max(0, Math.min(1, value / maxValue)) : 0

    // Monospace readout shown to the right of the bar, e.g. "42%" or "67°C".
    property string label: ""

    // Optional fixed width for the label column, in px. -1 (default) keeps
    // the original behavior: the track shrinks to make room for exactly
    // this instance's own label width, so a lone BarMeter still looks
    // right with no caller changes needed. When a caller sets this (e.g.
    // to the widest label used across several BarMeter/Sparkline instances
    // in one widget), the label is right-aligned within that fixed column
    // instead, so every instance's track/graph ends at the same x
    // regardless of how wide its own label text happens to be -- fixes
    // BarMeter tracks not lining up with each other or with Sparkline.
    property real labelColumnWidth: -1

    property int trackHeight: 14
    // btop's real meter_bg -- opaque solid dark gray, not a translucent
    // overlay (translucent-over-wallpaper was the original cause of low
    // meter contrast).
    property color trackColor: "#404040"

    // Segment geometry -- see file header for why this is a target pitch
    // (not a fixed segment count). segmentWidth is each lit block's own
    // width; segmentGap is the dark gap between adjacent blocks.
    property real segmentWidth: 6
    property real segmentGap: 2

    // Forwarded to the internal ColorScale so callers can tune thresholds
    // per-metric (e.g. a hotter goodMax for temperature vs. utilization).
    property alias goodMax: realColorScale.goodMax
    property alias warnMax: realColorScale.warnMax
    property alias goodColor: realColorScale.goodColor
    property alias warnColor: realColorScale.warnColor
    property alias badColor: realColorScale.badColor

    property int labelSpacing: Kirigami.Units.smallSpacing

    // Color of the value-readout label ("42%"/"51.0°C"). Defaults to the
    // Kirigami theme text color so this component still looks reasonable
    // used standalone/unconfigured; callers embedding it in a themed
    // widget (e.g. plasmatop-gpu binding this to its own fontColor config)
    // override it explicitly.
    property color labelColor: Kirigami.Theme.textColor

    implicitWidth: 140
    implicitHeight: Math.max(trackHeight, labelText.implicitHeight)

    ColorScale {
        id: realColorScale
    }

    Rectangle {
        id: track
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (root.label.length > 0 ? labelText.width + root.labelSpacing : 0)
        height: root.trackHeight
        // Sharp corners, deliberately -- a pill-shaped rounded bar is the
        // stock Plasma/Material progress-bar silhouette. Real terminal
        // meters are square-celled; radius: 0 reads as "terminal".
        radius: 0
        color: root.trackColor

        Item {
            id: segments
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            clip: true

            readonly property real pitch: root.segmentWidth + root.segmentGap
            readonly property int count: Math.max(1, Math.floor(width / pitch))
            // How many of `count` segments are lit at the current value --
            // the same "how many whole cells does this value reach" idea
            // as bashtop's create_meter loop (R7 §1), expressed as QML
            // Rectangles instead of terminal glyphs.
            //
            // Plain Math.round(ratio * count) rounds any ratio below
            // 0.5/count down to 0 lit segments. At a real bashtop-scale
            // track (R7 measured 10/15/25 segments across three actual
            // bars -- 10 was the narrowest ever observed) that dead zone is
            // a sliver right at true zero and is fine to leave alone: it's
            // exactly what Epic 1's pixel-exact 51%/54% verification
            // exercised (BACKLOG.md), at a ~22-segment track, and that
            // check must keep landing on exactly 11/12 lit segments with no
            // adjustment.
            //
            // But this project's minimum-resize widths can push `count`
            // down to 2-6 (labelColumnWidth eats most of the row at those
            // sizes -- see cross-cutting note in BACKLOG.md) -- well below
            // any real bashtop reference meter. There, the same dead zone
            // covers up to a quarter of the whole range (e.g. count=2 ->
            // anything under 25% rounds to 0), which reproduced as real
            // 13-28% CPU/GPU/MEM readings showing a completely empty
            // track, indistinguishable from idle. Below the bashtop-
            // observed ~10-segment floor, guarantee at least 1 lit segment
            // whenever the real value is nonzero, so "some load" always
            // reads as visually distinct from "idle" even when the track
            // is too narrow to show the exact fraction -- a coarser
            // reading beats an actively misleading empty one. Gated on
            // `count` (not applied unconditionally) so it can never touch
            // the already-verified precise behavior at normal/larger
            // widths.
            readonly property int minSegmentsForPreciseRounding: 10
            readonly property int rawLitCount: Math.round(root.ratio * count)
            readonly property int litCount: (root.ratio > 0 && rawLitCount === 0
                    && count < minSegmentsForPreciseRounding)
                ? 1
                : rawLitCount

            Repeater {
                // See file header -- plain integer model, not the
                // documented array-reassignment Repeater bug.
                model: segments.count

                delegate: Rectangle {
                    id: segmentDelegate
                    required property int index
                    visible: index < segments.litCount
                    x: index * segments.pitch
                    y: 0
                    width: root.segmentWidth
                    height: track.height
                    radius: 0
                    // Colored by this segment's OWN POSITION along the bar
                    // (index/count), not by the bar's current value --
                    // matches bashtop's create_meter exactly (R7 §1).
                    color: realColorScale.colorForFraction((segmentDelegate.index + 1) / segments.count)
                }
            }
        }
    }

    Text {
        id: labelText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Fixed-width column when the caller supplies one, so short labels
        // ("2%") right-align within the same column reserved for the
        // widest label used elsewhere in the widget ("100.0°C") -- see
        // root.labelColumnWidth above. Falls back to auto-sizing
        // (implicitWidth) when no override is given, matching the
        // original single-instance behavior exactly.
        width: root.labelColumnWidth >= 0 ? root.labelColumnWidth : implicitWidth
        visible: root.label.length > 0
        text: root.label
        font.family: "monospace"
        font.pixelSize: Math.max(10, root.trackHeight - 2)
        color: root.labelColor
        horizontalAlignment: Text.AlignRight
        // A transparent AsciiBox background (product-owner ask) means this
        // text can sit directly over an arbitrary desktop wallpaper, where
        // color alone isn't reliable contrast -- a thin dark outline was
        // already proven correct for this before the earlier revert.
        style: Text.Outline
        styleColor: "#000000"
    }
}
