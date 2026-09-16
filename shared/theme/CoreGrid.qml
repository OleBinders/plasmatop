/*
    CoreGrid.qml — shared/theme

    Per-core utilization grid for a variable, runtime-unknown core count
    (`plasmatop-cpu`'s driving use case, see research/r8-cpu-telemetry.md
    §2/§5). This is a genuinely different shape of problem than
    MetricRow.qml's fixed 4-metric list: the count is fixed for the
    lifetime of the running plasmoid (core count doesn't change while the
    widget is running) but unknown at write-time (varies 4/6/8/12/16/...
    by machine) — so neither MetricRow's "N fixed-index declarations"
    trick (N isn't known until runtime) nor "reassign a plain array to
    Repeater.model every tick" (a confirmed-broken pattern in this
    codebase, see MetricRow.qml's header) work here.

    Confirmed-correct pattern instead (R8 §5): a real `ListModel`,
    populated ONCE via initCores(count) (one .append() per core), with a
    `Repeater` reading it. Per-tick updates go through
    setCoreValue(index, percent), which calls
    coreModel.setProperty(index, "value", ...) on an EXISTING row —
    ListModel.setProperty() on an already-appended row is a real,
    well-supported Qt Quick reactivity path (unlike rebinding `model` to a
    fresh JS array each tick), because it mutates a role of an existing
    model item in place rather than asking Repeater to reconcile "is this
    the same list or a different one" against a whole new array identity
    every time.

    Layout: a GridLayout whose column count is DERIVED from the core
    count (not hardcoded to 2/12) via a maxRowsPerColumn target — see
    `columns` below — so this scales sanely to a hypothetical
    higher-core-count machine (more columns, not an ever-taller single
    column) without code changes, while still landing on the 2-column,
    6-row layout R8 §2 recommends for this machine's 12 cores. Flow is
    LeftToRight (GridLayout's default), so cores fill row-major — core 0
    and 1 share row 0, 2 and 3 share row 1, etc. — matching R8's "C0/C1
    per row" recommendation.

    Each cell is a compact BarMeter (small trackHeight, since up to a
    dozen need to fit in one box alongside a package-temp row and the
    AsciiBox frame) — no per-core temp or sparkline, deliberately, per
    R8 §2/§6 (bashtop's own single-column 8-core reference doesn't fit
    this machine's 12-core density without dropping something; frequency
    and temperature already live in the box header elsewhere in this
    project's convention).

    Color thresholds/colors are forwarded component properties (goodMax/
    warnMax/goodColor/warnColor/badColor), same forwarding pattern
    MetricRow.qml already uses — one shared good/warn/bad set for every
    core cell, not 12 individual ones (BACKLOG/R8 explicitly call this out
    as a single shared pair, not per-core).

    Usage:
        Theme.CoreGrid {
            id: coreGrid
            Layout.fillWidth: true
            goodMax: root.utilGoodMax
            warnMax: root.utilWarnMax
            goodColor: ...
            warnColor: ...
            badColor: ...
            trackColor: root.meterBackgroundColor
            labelColor: root.fontColor
            Component.onCompleted: initCores(12)
        }
        // per tick, once per core:
        coreGrid.setCoreValue(i, busyPct)
*/

import QtQuick
import QtQuick.Layouts

Item {
    id: root

    // Forwarded straight through to each cell's internal BarMeter, same
    // meaning/defaults as BarMeter.qml's own properties.
    property color goodColor: "#77ca9b"
    property color warnColor: "#cbc06c"
    property color badColor: "#dc4c4c"
    property color trackColor: "#404040"
    property color labelColor: "#eeeeee"
    property real goodMax: 0.5
    property real warnMax: 0.8

    // Compact cell geometry -- deliberately smaller than BarMeter's own
    // 14px default trackHeight, since up to a dozen of these need to fit
    // in the same box height budget as the GPU widget's 4 full-size rows.
    property int cellTrackHeight: 8
    property int rowSpacing: 2
    property int columnSpacing: 6

    // Target upper bound on rows before adding another column -- this is
    // what makes `columns` scale with core count instead of being
    // hardcoded, per the file header. 6 was picked to land exactly on
    // R8 §2's 2-column/6-row recommendation for this machine's 12 cores
    // (ceil(12/6) = 2) while still widening to 3+ columns automatically
    // for a hypothetical higher-core-count machine rather than growing
    // the box unboundedly tall.
    property int maxRowsPerColumn: 6

    readonly property int coreCount: coreModel.count
    readonly property int columns: coreCount > 0
        ? Math.max(1, Math.ceil(coreCount / maxRowsPerColumn))
        : 1

    implicitWidth: grid.implicitWidth
    implicitHeight: grid.implicitHeight

    // Shared right-edge column for every per-core BarMeter's track -- same
    // bug/fix as plasmatop-gpu/main.qml's meterLabelColumnWidth (see that
    // file's doc comment and BarMeter.qml's labelColumnWidth property).
    // Without this, each BarMeter's track shrinks to leave room for
    // exactly ITS OWN label's width, so a core reading "C6 100%" (a longer
    // string than "C6 62%") gets a visibly shorter track than its
    // neighbors even though it IS fully lit at that narrower width --
    // product-owner-observed as "the bar shrinks at 100%". Sized once to
    // the widest label this grid can ever produce -- the highest 2-digit
    // core index (this project's target machines run 4-16 cores, never
    // 100+, per the file header) plus a 3-digit percent, e.g. "C11 100%"
    // on this machine's 12 cores -- and given identically to every
    // delegate below, so all tracks end at the same x regardless of their
    // current value's digit count.
    FontMetrics {
        id: coreLabelMetrics
        font.family: "monospace"
        // Mirrors BarMeter.qml's own label font-size formula, Math.max(10,
        // trackHeight - 2), for cellTrackHeight (the trackHeight every
        // delegate below actually uses) -- keep in sync if either changes.
        font.pixelSize: Math.max(10, root.cellTrackHeight - 2)
    }
    readonly property real labelColumnWidth: coreLabelMetrics.advanceWidth("C11 100%")

    ListModel {
        id: coreModel
    }

    /*!
        Populates the internal ListModel with \a count rows, each starting
        at value 0. Call ONCE, e.g. from the owning widget's
        Component.onCompleted after the first stats tick reports the real
        core count -- see file header for why this must not be called
        repeatedly or replaced with a reassigned array.
    */
    function initCores(count) {
        coreModel.clear();
        for (let i = 0; i < count; i++) {
            // Role deliberately NOT named "value" -- BarMeter (the
            // delegate's base type below) already has its own "value"
            // property, and a required property re-declared with that
            // same name on the delegate shadows it: QML resolves
            // externally-qualified reads (cellDelegate.value) to the new
            // shadow property, but BarMeter.qml's OWN internal bindings
            // (e.g. `ratio: value / maxValue`) keep resolving to the
            // original base-class property, which never gets the model
            // data. Net effect: the label showed a real number but every
            // bar stayed empty/0% (confirmed with an isolated PySide6
            // repro during the 2026-09-14 debugging session). Using a
            // non-colliding role name ("percent") avoids the shadowing
            // entirely.
            coreModel.append({ index: i, percent: 0 });
        }
    }

    /*!
        Updates one existing core row's value in place (percent, 0..100).
        Safe to call every poll tick -- this is the ListModel.setProperty()
        path Repeater reliably reacts to (see file header).
    */
    function setCoreValue(index, percent) {
        if (index >= 0 && index < coreModel.count) {
            coreModel.setProperty(index, "percent", percent);
        }
    }

    GridLayout {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        columns: root.columns
        flow: GridLayout.LeftToRight
        rowSpacing: root.rowSpacing
        columnSpacing: root.columnSpacing

        Repeater {
            // A real ListModel, not a reassigned plain JS array -- see
            // file header for why this is the correct choice here (a
            // genuinely variable-length list, unlike MetricRow's fixed 4).
            model: coreModel

            delegate: BarMeter {
                id: cellDelegate
                required property int index
                required property real percent

                Layout.fillWidth: true
                Layout.preferredWidth: 1

                value: cellDelegate.percent
                maxValue: 100
                label: "C" + cellDelegate.index + " " + Math.round(cellDelegate.percent) + "%"
                trackHeight: root.cellTrackHeight
                goodMax: root.goodMax
                warnMax: root.warnMax
                goodColor: root.goodColor
                warnColor: root.warnColor
                badColor: root.badColor
                trackColor: root.trackColor
                labelColor: root.labelColor
                labelColumnWidth: root.labelColumnWidth
            }
        }
    }
}
