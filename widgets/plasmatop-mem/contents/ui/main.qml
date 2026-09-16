/*
    plasmatop-mem — main.qml

    btop-style RAM/swap monitor. Data sourcing follows ARCHITECTURE.md's
    pattern for all five plasmatop widgets: Plasma5Support.DataSource
    (executable engine) running contents/scripts/mem-stats.sh on a QML
    Timer, JSON-parsed in onNewData. Unlike plasmatop-gpu/plasmatop-cpu,
    there is NO delta math anywhere here — every figure mem-stats.sh
    reports is an instantaneous gauge, so each tick's raw values are used
    directly with no previous-tick baseline at all. This is meant to be
    one of the simplest widgets in the project — one mirrored graph row
    (see Epic 7 note below), no per-client/per-core tracking.

    "Used" memory is computed as MemTotal - MemAvailable, NOT
    MemTotal - MemFree: MemFree alone excludes reclaimable page cache/
    buffers and wildly overstates "used" (the classic "why does Linux
    show no free RAM" confusion). MemAvailable is the kernel's own
    estimate of what's available for new allocations without swapping,
    and is what htop/`free`'s "available" column report — matches this
    project's btop-style aesthetic and was cross-checked live against
    `free -b` while building this widget (mem_total_bytes/swap_total_bytes/
    swap_free_bytes matched exactly; mem_available_bytes was within normal
    snapshot-to-snapshot drift of `free`'s own figure).

    Epic 7 (2026-09-15): RAM/SWAP converted from two separate "bar"-style
    MetricRows to ONE "graph"-style MetricRow, mirrored the same way
    plasmatop-gpu mirrors utilization/VRAM and plasmatop-net mirrors up/
    down -- RAM as the peak (upper) series, SWAP as the valley (lower)
    series, sharing one Sparkline via MetricRow.qml's existing mirrored-
    graph mechanism (no new mechanism built). Still no delta math: each
    tick's instantaneous ramUsedPercent/swapUsedPercent is pushed straight
    into the graph via pushValue(), same as GPU/NET push their own live
    samples.
*/

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

import "theme" as Theme

PlasmoidItem {
    id: root

    // --- Live metrics, updated straight from applyStats() below -- all four
    // are raw instantaneous gauges from mem-stats.sh, no delta math. -------
    property real memTotalBytes: 0
    property real memAvailableBytes: 0
    property real swapTotalBytes: 0
    property real swapFreeBytes: 0
    property bool haveData: false

    // Set/cleared by fullRepresentation's Component.onCompleted/
    // onDestruction below, same pattern as plasmatop-gpu/-net: the graph's
    // Sparkline only exists while the popup is actually open, so live
    // samples get routed to it conditionally rather than assuming it's
    // always there.
    property Item _activeFullItem: null

    // Rolling sample history for the mirrored RAM(peak)/SWAP(valley) graph
    // -- same shape/purpose as plasmatop-gpu's _utilHistory/_vramHistory
    // and plasmatop-net's _upHistory/_downHistory, used only to hydrate
    // the Sparkline via MetricRow's `history`/`valleyHistory` descriptor
    // fields when the full representation is recreated (popup reopened);
    // live updates go through pushValue(), not through reassigning these.
    property var _ramHistory: []
    property var _swapHistory: []
    readonly property int historyLength: 60

    readonly property real ramUsedBytes: Math.max(0, memTotalBytes - memAvailableBytes)
    readonly property real ramUsedPercent: memTotalBytes > 0 ? (ramUsedBytes / memTotalBytes) * 100 : 0
    readonly property real swapUsedBytes: Math.max(0, swapTotalBytes - swapFreeBytes)
    readonly property real swapUsedPercent: swapTotalBytes > 0 ? (swapUsedBytes / swapTotalBytes) * 100 : 0

    // Swap usage is generally worse news than the same % of RAM usage --
    // any nonzero swap means the kernel already decided it needed to push
    // pages out, whereas high RAM usage alone (cache-heavy) is normal and
    // often even desirable on Linux. Defaults set noticeably lower than
    // RAM's (0.3/0.6 vs 0.6/0.85) so the swap bar reads amber/red sooner.
    readonly property real ramGoodMax: Plasmoid.configuration.ramGoodMax || 0.6
    readonly property real ramWarnMax: Plasmoid.configuration.ramWarnMax || 0.85
    readonly property real swapGoodMax: Plasmoid.configuration.swapGoodMax || 0.3
    readonly property real swapWarnMax: Plasmoid.configuration.swapWarnMax || 0.6

    // --- User-configurable text/frame colors, same shape as plasmatop-gpu --
    readonly property color fontColor: Plasmoid.configuration.fontColor || "#eeeeee"
    readonly property color frameColor: Plasmoid.configuration.frameColor || "#606060"
    readonly property color meterBackgroundColor: Plasmoid.configuration.meterBackgroundColor || "#404040"

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    toolTipMainText: Plasmoid.title
    // Full used/total GiB detail lives here now instead of inline in the
    // bar labels (see formatMemPercent()'s comment) -- the tooltip has
    // room for it without fighting the fixed-width bar-label column.
    toolTipSubText: root.haveData
        ? "RAM " + root.formatMemDetail(root.ramUsedBytes, root.memTotalBytes) +
          "  •  Swap " + root.formatMemDetail(root.swapUsedBytes, root.swapTotalBytes)
        : "Waiting for data…"

    // Builds the "62% (10.1/16.3 GiB)" full-detail readout, used only for
    // the tooltip now (see below) -- GiB = bytes / 1024^3, matching this
    // project's existing VRAM convention (plasmatop-gpu's vramTotalGib),
    // not decimal GB.
    function formatMemDetail(usedBytes, totalBytes) {
        const pct = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0;
        const usedGib = usedBytes / (1024 * 1024 * 1024);
        const totalGib = totalBytes / (1024 * 1024 * 1024);
        return Math.round(pct) + "% (" + usedGib.toFixed(1) + "/" + totalGib.toFixed(1) + " GiB)";
    }

    // Short "62%" readout used for each row's own corner label
    // (displayOverride/valleyDisplayOverride below). Deliberately
    // percent-only, NOT the fuller "62% (10.1/16.3 GiB)" this widget
    // originally shipped with when it still used two "bar"-style
    // MetricRows: that longer string, at a worst-case width like
    // "SWAP 100% (999.9/999.9 GiB)", was too wide for this widget's box to
    // reserve as a shared labelColumnWidth without collapsing the
    // BarMeter's track to ~0px (a real bug, seen on the live desktop, from
    // before Epic 7's move to a single graph row -- the graph row's corner
    // readouts have no shared-column-width constraint to collapse, but the
    // short percent-only format is kept anyway for label brevity). The
    // full used/total GiB detail is still available in the tooltip
    // (toolTipSubText above), just not inline in the compact bar label.
    function formatMemPercent(usedBytes, totalBytes) {
        const pct = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0;
        return Math.round(pct) + "%";
    }

    // --- Generic metric-row model (see shared/theme/MetricRow.qml) ---------
    // Epic 7: ONE descriptor -- the mirrored RAM(peak)/SWAP(valley) graph,
    // same shape as plasmatop-net's single up/down throughput descriptor.
    // Percent scale (0..100) on both series, so unlike NET's dynamically-
    // scaled unit labels, a fixed unit ("%") + decimals would technically
    // work here -- displayOverride is still used anyway (formatMemPercent()
    // rounds instead of truncating via toFixed(), and keeps this row's
    // corner readouts textually identical to the pre-Epic-7 bar labels).
    readonly property var metrics: [
        {
            key: "ramswap", label: "RAM", style: "graph",
            value: root.ramUsedPercent, maxValue: 100, unit: "%", decimals: 0,
            goodMax: root.ramGoodMax, warnMax: root.ramWarnMax,
            history: root._ramHistory,
            displayOverride: root.haveData ? root.formatMemPercent(root.ramUsedBytes, root.memTotalBytes) : "—",

            valleyLabel: "SWAP",
            valleyValue: root.swapUsedPercent, valleyMaxValue: 100, valleyUnit: "%", valleyDecimals: 0,
            valleyGoodMax: root.swapGoodMax, valleyWarnMax: root.swapWarnMax,
            valleyHistory: root._swapHistory,
            valleyDisplayOverride: root.haveData ? root.formatMemPercent(root.swapUsedBytes, root.swapTotalBytes) : "—"
        }
    ]

    // --- Data source: run mem-stats.sh, parse its one-line JSON ------------
    Plasma5Support.DataSource {
        id: statsSource
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);

            const exitCode = data["exit code"];
            if (exitCode !== 0) {
                console.warn("plasmatop-mem: mem-stats.sh exited with code", exitCode, data["stderr"]);
                return;
            }

            let stats;
            try {
                stats = JSON.parse(data["stdout"]);
            } catch (e) {
                console.warn("plasmatop-mem: failed to parse stats JSON:", e, data["stdout"]);
                return;
            }

            if (!stats.ok) {
                console.warn("plasmatop-mem: mem-stats.sh reported an error");
                return;
            }

            root.applyStats(stats);
        }

        function poll() {
            // main.qml lives in contents/ui/; the script lives in
            // contents/scripts/ (ARCHITECTURE.md's package layout), hence ../.
            const scriptPath = Qt.resolvedUrl("../scripts/mem-stats.sh").toString().replace("file://", "");
            connectSource(scriptPath);
        }
    }

    Timer {
        id: pollTimer
        // Same async-config-load-race fallback as plasmatop-gpu's Timer --
        // Plasmoid.configuration.pollInterval reads back undefined for a
        // moment during applet startup, which would otherwise evaluate
        // interval to NaN and silently break repeat scheduling. Default
        // (2.0s) is slightly slower than GPU's 1.5s -- /proc/meminfo
        // doesn't need to track fast bursts the way GPU utilization does.
        interval: (Plasmoid.configuration.pollInterval || 2.0) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsSource.poll()
    }

    // Raw values straight from mem-stats.sh's stateless JSON -- no delta
    // math, no previous-tick baseline, unlike plasmatop-gpu/-cpu.
    function applyStats(stats) {
        memTotalBytes = stats.mem_total_bytes;
        memAvailableBytes = stats.mem_available_bytes;
        swapTotalBytes = stats.swap_total_bytes;
        swapFreeBytes = stats.swap_free_bytes;
        haveData = true;

        // ramUsedPercent/swapUsedPercent are readonly properties derived
        // from the values just assigned above, so they already reflect
        // this tick by the time we read them here.
        root._ramHistory.push(root.ramUsedPercent);
        root._swapHistory.push(root.swapUsedPercent);
        while (root._ramHistory.length > root.historyLength) {
            root._ramHistory.shift();
            root._swapHistory.shift();
        }
        if (root._activeFullItem) {
            root._activeFullItem.pushRamSwapSample(root.ramUsedPercent, root.swapUsedPercent);
        }
    }

    // --- Compact (panel) representation -------------------------------------
    // Single aggregate bar: RAM used % only (swap doesn't need panel-level
    // visibility per spec -- RAM is the primary at-a-glance stat). Same
    // bracket "[...]" + BarMeter style as GPU/CPU's panel views.
    compactRepresentation: MouseArea {
        id: compactRoot

        Layout.minimumWidth: Kirigami.Units.gridUnit * 4
        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
        Layout.minimumHeight: Kirigami.Units.gridUnit
        Layout.fillHeight: true

        onClicked: root.expanded = !root.expanded

        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: 2

            Text {
                text: "["
                font.family: "monospace"
                font.bold: true
                color: root.frameColor
                anchors.verticalCenter: parent.verticalCenter
            }
            Theme.BarMeter {
                width: parent.width - 24
                anchors.verticalCenter: parent.verticalCenter
                value: root.ramUsedPercent
                maxValue: 100
                label: Math.round(root.ramUsedPercent) + "%"
                goodMax: root.ramGoodMax
                warnMax: root.ramWarnMax
                trackHeight: Math.max(6, Math.min(compactRoot.height - 2 * Kirigami.Units.smallSpacing, 16))
                goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                trackColor: root.meterBackgroundColor
                labelColor: root.fontColor
            }
            Text {
                text: "]"
                font.family: "monospace"
                font.bold: true
                color: root.frameColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // --- Full (expanded) representation -------------------------------------
    fullRepresentation: Item {
        id: fullRoot

        // Epic 7: now a single mirrored RAM/SWAP graph row instead of two
        // "bar" rows, so width/height are sized to match plasmatop-net's
        // equivalent single-graph-row layout (same content shape) rather
        // than the old two-bar-row sizing this widget previously used.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Kirigami.Units.gridUnit * 10

        // Matches plasmatop-net's minimum exactly: one graph row's
        // graphMinimumHeight (MetricRow.qml, 3.6 gridUnit) plus AsciiBox's
        // frame overhead (~43px, measured for plasmatop-gpu, same AsciiBox
        // instance) plus a small buffer. Verified live on this machine's
        // desktop at this floor (see SPRINTS.md Epic 7 entry) rather than
        // left as an estimate the way net's own comment once flagged its
        // own value.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6.5

        // Exposed so applyStats() above can push live RAM/SWAP percent
        // samples straight into the graph MetricRow's mirrored Sparkline
        // -- same _activeFullItem pattern as plasmatop-gpu/pushUtilSample
        // and plasmatop-net/pushThroughputSample.
        function pushRamSwapSample(ramV, swapV) {
            ramSwapRow.pushValue(ramV, swapV);
        }

        Component.onCompleted: root._activeFullItem = fullRoot
        Component.onDestruction: {
            if (root._activeFullItem === fullRoot) {
                root._activeFullItem = null;
            }
        }

        Theme.AsciiBox {
            anchors.fill: parent
            title: i18n("MEM")
            backgroundColor: Qt.rgba(0, 0, 0, Plasmoid.configuration.backgroundOpacity || 0.0)
            borderColor: root.frameColor

            ColumnLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing / 2

                Theme.MetricRow {
                    id: ramSwapRow
                    Layout.fillWidth: true
                    // Epic 7: graph row grows vertically with the widget
                    // instead of the old two-bar layout's fixed row
                    // heights + trailing filler Item (both removed here).
                    // Floor matches MetricRow's own internal
                    // graphMinimumHeight (3.6 gridUnit).
                    Layout.fillHeight: true
                    Layout.minimumHeight: ramSwapRow.graphMinimumHeight
                    metric: root.metrics[0]
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                }
            }
        }
    }
}
