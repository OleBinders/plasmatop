/*
    MetricRow.qml — shared/theme

    Generic, config-driven "one row per metric" component, per R5's
    recommended shape (B): each widget's main.qml keeps its own
    resource-specific delta math (applyStats()/engineBusyPercent() etc.)
    and just builds an array of plain-JS metric descriptor objects from the
    result; this component turns ONE descriptor into a rendered row,
    reusing BarMeter/Sparkline/ColorScale internally (none of the three
    change to support this -- their value/maxValue/goodMax/warnMax/color
    API was already fully metric-agnostic, confirmed by R5 reading all
    three files in full).

    Intended reuse: any future plasmatop widget (CPU/RAM/network/storage)
    builds its own descriptor array and drops a
    `Repeater { model: myMetrics; delegate: MetricRow { metric: modelData } }`
    into its fullRepresentation instead of hand-writing per-metric
    Label+BarMeter/Sparkline blocks. Nothing about this component is
    GPU-specific.

    Only ONE of the three style branches is ever actually instantiated per
    row, via a Loader keyed on metric.style -- deliberately NOT three
    sibling Items toggled by `visible`, which would construct a BarMeter
    (with its own ColorScale) AND a Sparkline (with its own ColorScale
    PLUS a bundled-font FontLoader, per Sparkline.qml) for every row
    regardless of which one is actually shown. With 4 rows and only one
    "graph" row, that would mean 3 wasted Sparkline+FontLoader instances
    per widget instance for no visual benefit -- exactly the kind of
    unnecessary rendering-cost multiplication this project has repeatedly
    had to walk back elsewhere (see Sparkline.qml's own header on the
    "requestPaint() only from data handlers" battery-drain rule).

    --- Metric descriptor shape (plain JS object, one per row) ---

    {
        key:        "utilization",   // stable id, unique per widget's metric
                                      // list. Used to look a row up later
                                      // (see metricRowByKey() pattern in
                                      // plasmatop-gpu/contents/ui/main.qml)
                                      // -- NOT rendered anywhere itself.
        label:      "PKG",           // short text prefix. Rendered inline
                                      // before the value for "bar"/"graph"
                                      // styles, or as "label: value" for
                                      // "text" style. "" is valid (e.g. a
                                      // lone graph in a box that already
                                      // has a title identifying the metric
                                      // -- see the vtop reference in R6).
        style:      "bar",           // "bar" | "graph" | "text" -- which
                                      // of BarMeter / Sparkline+overlay /
                                      // plain Text renders this row. Not
                                      // meant to change at runtime for a
                                      // given row's key -- the Loader
                                      // below only re-instantiates when
                                      // this value itself changes.
        value:      62.0,            // current numeric value.
        maxValue:   100,             // scale max; ratio = value/maxValue.
                                      // Ignored for "text" (no bar/graph to
                                      // scale), but still fine to pass.
        unit:       "%",             // suffix appended to the formatted
                                      // value, e.g. "%", "°C", " W".
        decimals:   0,               // toFixed() precision for the value.
        goodMax:    0.6,             // ColorScale threshold fractions
        warnMax:    0.85,            // (0..1), forwarded to the internal
                                      // BarMeter/Sparkline for this row
                                      // only -- these are genuinely
                                      // per-metric, per Epic 1.6's ask.
        history:    [...],           // "graph" style ONLY: raw sample
                                      // array (oldest..newest) for the
                                      // PEAK (upper-half) series, used once
                                      // at Component.onCompleted to
                                      // hydrate the internal Sparkline
                                      // (e.g. when the full representation
                                      // is recreated after the popup
                                      // closes/reopens). Live updates go
                                      // through pushValue() below, NOT
                                      // through reassigning this array --
                                      // see Sparkline.qml/this project's
                                      // history on why in-place array
                                      // mutation doesn't trigger QML
                                      // binding reactivity.

        // --- "graph" style ONLY, all OPTIONAL: a second, independent
        // VALLEY (lower-half) series mirrored below the center line, per
        // Epic 1.7 (research/r7's confirmed bashtop net-box pattern of two
        // different values sharing one mirrored graph primitive). Omit
        // valleyValue entirely for a peak-only graph row (mirrors to an
        // empty lower half) -- these fields have no effect on "bar"/"text"
        // style rows.
        valleyLabel: "VRAM",         // short text prefix for the valley
                                      // corner readout, same idea as
                                      // `label` above but for the second
                                      // series.
        valleyValue: 18.0,           // current valley value.
        valleyMaxValue: 100,         // valley scale max.
        valleyUnit:  "%",
        valleyDecimals: 0,
        valleyGoodMax: 0.6,          // valley's OWN ColorScale thresholds
        valleyWarnMax: 0.85,         // -- independent from goodMax/warnMax
                                      // above, since peak/valley are
                                      // different metrics that can want
                                      // different cutoffs even when both
                                      // happen to be percentages.
        valleyHistory: [...],        // same shape/purpose as `history`,
                                      // for the valley series.

        displayOverride: null        // optional string. When non-null,
                                      // shown verbatim instead of the
                                      // formatted value+unit (e.g. "—"
                                      // while waiting for the first
                                      // two-sample delta) -- same sentinel
                                      // convention this widget already
                                      // used for "no data yet" before this
                                      // refactor.

        valleyDisplayOverride: null  // "graph" style ONLY, optional string
                                      // -- same override behavior as
                                      // displayOverride above, but for the
                                      // valley corner readout instead of
                                      // the peak one. Added for
                                      // plasmatop-net (Epic 4): throughput
                                      // needs dynamically-scaled unit
                                      // labels ("842 KB/s", "2.4 MB/s")
                                      // rather than a fixed
                                      // value.toFixed(decimals)+unit for
                                      // BOTH the peak (up) and valley
                                      // (down) readouts, unlike GPU/CPU's
                                      // fixed-unit percent/temperature
                                      // metrics which only ever needed the
                                      // peak override (the "—" no-data
                                      // sentinel). null by default --
                                      // existing descriptors that don't
                                      // set this field are unaffected, see
                                      // _formattedValley() below.
    }

    For "graph" style rows, call metricRow.pushValue(v) on every new
    sample from the OWNING widget's onNewData/applyStats() handler --
    exactly like the old direct `sparkline.pushValue()` call this
    replaces, just routed through the row component. Rows with any other
    style ignore pushValue() calls (harmless no-op).

    Usage -- for a FIXED-length metric list (e.g. plasmatop-gpu's 4
    metrics), declare one MetricRow per descriptor and bind `metric` by
    INDEX into your descriptor array, NOT via a Repeater over that array:

        Theme.MetricRow {
            id: someRow
            Layout.fillWidth: true
            metric: root.metrics[0]   // NOT `Repeater { model: root.metrics }`
            goodColor: root.someGoodColor
            warnColor: root.someWarnColor
            badColor: root.someBadColor
            labelColor: root.someFontColor
            labelColumnWidth: root.someSharedColumnWidth   // bar rows only
        }

    Found empirically while building plasmatop-gpu's own metrics (live
    journalctl debug tracing): QML's Repeater does NOT reliably refresh an
    existing delegate's `modelData` when a brand-new JS array (same
    length) is reassigned to `model` on every tick -- confirmed the
    descriptor array's VALUES were genuinely updating every poll (a debug
    JSON.stringify of the array read back correct fresh values every
    tick), yet Repeater-rendered BarMeter labels stayed frozen at their
    initial values indefinitely. This is a real, documented Repeater +
    plain-JS-array limitation, not a general QML reactivity problem: an
    ordinary property expression like `root.metrics[0]` (no Repeater
    involved) DOES re-evaluate correctly on every change, exactly like any
    other bound property in this project. A genuinely variable-LENGTH
    metric list (e.g. a future CPU widget's per-core rows, where the
    number of rows itself can differ) should back its Repeater with a real
    Qt `ListModel` (`.get(i)`/`.setProperty()` updates, or `.append()`/
    `.remove()` for count changes) rather than a reassigned plain array,
    specifically because ListModel has real, granular change notification
    that Repeater is built to consume correctly -- a plain array is not.
*/

import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    property var metric: ({
        key: "", label: "", style: "text",
        value: 0, maxValue: 1, unit: "", decimals: 0,
        goodMax: 0.5, warnMax: 0.8,
        history: null, displayOverride: null, valleyDisplayOverride: null
    })

    // Forwarded straight through to the internal BarMeter/Sparkline, same
    // meaning as those components' own properties.
    property color goodColor: "#77ca9b"
    property color warnColor: "#cbc06c"
    property color badColor: "#dc4c4c"
    property color labelColor: Kirigami.Theme.textColor
    // Forwarded to the internal BarMeter's/Sparkline's own `trackColor`
    // (their background-track fill) -- one shared control for both,
    // per product-owner ask covering "the graph and the bars" together
    // (see main.xml's meterBackgroundColor doc comment). Defaults match
    // BarMeter's own hardcoded default so an un-configured widget's bar
    // rows look identical to before; Sparkline's background shifts
    // slightly from its own previous default (#2a2a2a) to this same
    // shared value -- an intentional, PM-approved trade for one control
    // instead of two.
    property color trackColor: "#404040"

    // Shared fixed label-column width for "bar" style rows, so several
    // MetricRow instances in the same widget line up their tracks at the
    // same x regardless of each row's own label text width -- same fix,
    // same rationale, as BarMeter.labelColumnWidth (see that file); this
    // just forwards it through.
    property real labelColumnWidth: -1

    implicitWidth: 140
    // "graph" rows (Epic 7) no longer size purely from their own content --
    // implicitHeight for a graph row is just the historical minimum floor
    // (3.6 gridUnit, unchanged from Epic 1 sprint 2's +20% tuning pass),
    // used as this row's Layout preferred/minimum-fallback size before any
    // Layout.fillHeight stretching happens. The row's ACTUAL rendered
    // height for a graph row tracks root.height once the owning widget's
    // ColumnLayout grants it fillHeight space -- see Loader.height below,
    // which is where that stretch actually gets applied. Bar/text rows are
    // unaffected: their implicitHeight still just mirrors the loaded
    // item's own natural size via loader.height, exactly as before Epic 7.
    readonly property real graphMinimumHeight: Kirigami.Units.gridUnit * 3.6
    implicitHeight: root.metric.style === "graph" ? root.graphMinimumHeight : loader.height

    // --- Value formatting, shared by all three styles -----------------------
    function _formattedValue() {
        if (metric.displayOverride !== undefined && metric.displayOverride !== null) {
            return metric.displayOverride;
        }
        const v = (metric.value !== undefined && metric.value !== null) ? metric.value : 0;
        const decimals = metric.decimals || 0;
        const unit = metric.unit || "";
        return v.toFixed(decimals) + unit;
    }

    /*!
        Route a new live sample pair into this row's graph, if it is one.
        \a valleyV is optional (defaults to 0 in Sparkline.pushValue()) for
        a peak-only graph row. No-op for "bar"/"text" style rows (they're
        driven by re-binding `metric` instead, not by a push stream).
    */
    function pushValue(peakV, valleyV) {
        if (metric.style === "graph" && loader.item && loader.item.pushValueTarget) {
            loader.item.pushValueTarget.pushValue(peakV, valleyV);
        }
    }

    Loader {
        id: loader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        // Width already flows from the anchors above; height needs an
        // explicit propagation path too (Epic 7 root cause): a "graph"
        // row's owning MetricRow instance gets `Layout.fillHeight: true`
        // from the widget's ColumnLayout, which sets root.height directly
        // to whatever extra vertical space is available -- but a Loader
        // does NOT automatically follow an ancestor's height the way
        // `anchors.fill` would, so without this explicit binding the
        // loaded Sparkline stayed pinned at graphMinimumHeight forever no
        // matter how tall root.height grew (confirmed: this, not
        // Sparkline's own grid math, was the actual blocker -- Sparkline
        // already reacted correctly to onHeightChanged once it actually
        // RECEIVED a taller height). Non-graph rows keep the exact old
        // auto-sizing behavior via loader.implicitHeight (mirrors the
        // loaded item's own implicitHeight, equivalent to leaving
        // Loader.height unset as before).
        height: root.metric.style === "graph"
            ? Math.max(root.height, root.graphMinimumHeight)
            : loader.implicitHeight
        // Only re-picks a component when metric.style itself changes (not
        // meant to happen at runtime for a fixed row key, see the
        // descriptor shape doc above) -- value/history/threshold updates
        // flow into the already-loaded item's bindings instead of
        // reloading it.
        sourceComponent: {
            switch (root.metric.style) {
                case "graph": return graphComponent;
                case "bar": return barComponent;
                default: return textComponent;
            }
        }
    }

    // --- "graph" style: Sparkline filling the row, current value(s) -------
    // overlaid in corner text blocks, per R6's vtop/bashtop reference (one
    // visual per row -- no separate bar for the same value) extended for
    // Epic 1.7's mirrored peak/valley design: peak's readout top-right,
    // valley's readout bottom-right (only shown when the descriptor
    // actually provides a valleyValue -- see MetricRow.qml's header doc).
    Component {
        id: graphComponent

        Item {
            id: graphArea
            // Loader now has an explicit width AND height (bound to
            // MetricRow's own width via anchors.left/right, and to
            // root.height for graph rows via the Loader's `height` binding
            // above -- see its comment for the Epic 7 root cause) -- per
            // Loader's documented behavior the loaded item does NOT
            // automatically stretch to fill it, so anchors.fill here is
            // what actually makes graphArea (and therefore the Sparkline
            // anchored to IT below) track that taller Loader height
            // instead of collapsing back to a fixed constant.
            anchors.fill: parent
            // Exposed so MetricRow.pushValue() can reach the real
            // Sparkline without hardcoding an id path through the Loader.
            readonly property alias pushValueTarget: sparklineItem
            readonly property bool _hasValley: root.metric.valleyValue !== undefined && root.metric.valleyValue !== null

            function _formattedValley() {
                if (root.metric.valleyDisplayOverride !== undefined && root.metric.valleyDisplayOverride !== null) {
                    return root.metric.valleyDisplayOverride;
                }
                const v = graphArea._hasValley ? root.metric.valleyValue : 0;
                const decimals = root.metric.valleyDecimals || 0;
                const unit = root.metric.valleyUnit || "";
                return v.toFixed(decimals) + unit;
            }

            Sparkline {
                id: sparklineItem
                anchors.fill: parent
                maxValue: root.metric.maxValue || 100
                goodMax: root.metric.goodMax !== undefined ? root.metric.goodMax : 0.5
                warnMax: root.metric.warnMax !== undefined ? root.metric.warnMax : 0.8
                valleyMaxValue: root.metric.valleyMaxValue || 100
                valleyGoodMax: root.metric.valleyGoodMax !== undefined ? root.metric.valleyGoodMax : 0.5
                valleyWarnMax: root.metric.valleyWarnMax !== undefined ? root.metric.valleyWarnMax : 0.8
                goodColor: root.goodColor
                warnColor: root.warnColor
                badColor: root.badColor
                trackColor: root.trackColor

                Component.onCompleted: {
                    if (root.metric.history) {
                        setHistory(root.metric.history, root.metric.valleyHistory || []);
                    }
                }
            }

            Text {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 2
                text: root.metric.label ? (root.metric.label + " " + root._formattedValue()) : root._formattedValue()
                font.family: "monospace"
                font.bold: true
                color: root.labelColor
                style: Text.Outline
                styleColor: "#000000"
            }

            Text {
                visible: graphArea._hasValley
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: 2
                text: (root.metric.valleyLabel || "") + " " + graphArea._formattedValley()
                font.family: "monospace"
                font.bold: true
                color: root.labelColor
                style: Text.Outline
                styleColor: "#000000"
            }
        }
    }

    // --- "bar" style: one BarMeter, name+value folded into its own label ----
    // slot (e.g. "PKG 62.0°C") instead of a separate Label line above it --
    // per R6 #3, merges what used to be two ColumnLayout children into one.
    Component {
        id: barComponent

        BarMeter {
            // See graphArea's comment above -- Loader doesn't auto-stretch
            // a loaded item's width when the Loader's own width is
            // explicitly set (as it is here, via anchors).
            width: parent.width
            value: root.metric.value || 0
            maxValue: root.metric.maxValue || 1
            label: root.metric.label ? (root.metric.label + " " + root._formattedValue()) : root._formattedValue()
            goodMax: root.metric.goodMax !== undefined ? root.metric.goodMax : 0.5
            warnMax: root.metric.warnMax !== undefined ? root.metric.warnMax : 0.8
            goodColor: root.goodColor
            warnColor: root.warnColor
            badColor: root.badColor
            trackColor: root.trackColor
            labelColor: root.labelColor
            labelColumnWidth: root.labelColumnWidth
        }
    }

    // --- "text" style: one plain label line, no bar/graph at all -- for a --
    // value that doesn't need a severity meter (e.g. power draw), per R6 #5.
    Component {
        id: textComponent

        QQC2.Label {
            // See graphArea's comment above -- same Loader width-stretch
            // fix.
            width: parent.width
            text: (root.metric.label ? root.metric.label + ": " : "") + root._formattedValue()
            font.family: "monospace"
            color: root.labelColor
            style: Text.Outline
            styleColor: "#000000"
        }
    }
}
