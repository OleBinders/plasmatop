/*
    plasmatop-net — main.qml

    btop-style network monitor for the primary (default-route) interface.
    Data sourcing follows ARCHITECTURE.md's pattern for all five plasmatop
    widgets: Plasma5Support.DataSource (executable engine) running
    contents/scripts/net-stats.sh on a QML Timer, JSON-parsed in onNewData.
    The script is stateless (prints the raw current rx/tx byte counters for
    whichever interface currently holds the default route) — all delta math
    (bytes/sec up and down) happens here in QML, using the previous tick's
    raw values and the actual elapsed wall time between ticks, exactly like
    plasmatop-gpu's energy/busy-time deltas.

    Scope decision (product owner, see AGENTS.md task brief): show
    throughput for the PRIMARY (default-route) interface only — not
    per-interface, not an aggregate across all interfaces. One mirrored
    graph: upload as the peak (upper half), download as the valley (lower
    half) — matches the product owner's explicitly picked "up top, down at
    bottom" orientation, same mirrored peak/valley mechanism
    plasmatop-gpu's utilization/VRAM row uses (shared/theme/MetricRow.qml +
    Sparkline.qml), just with dynamically-scaled throughput units instead
    of fixed percent/decimals — see formatRate() and MetricRow.qml's new
    valleyDisplayOverride field.
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

    // --- Live metrics, updated from applyStats() below ---------------------
    property string interfaceName: ""
    property real rxBytesPerSec: 0
    property real txBytesPerSec: 0
    property bool haveData: false

    // Raw stats from the previous tick, for delta computation. null until
    // the first sample arrives, and deliberately RESET to null whenever the
    // default route disappears (see onNewData's !stats.ok branch) so that a
    // later reconnect starts a fresh baseline instead of delta-ing across
    // the gap.
    property var _prevStats: null

    // Up/down throughput history kept at the root so it survives the full
    // representation being destroyed/recreated when the popup closes and
    // reopens (see Theme.Sparkline.setHistory()). Index-aligned — pushed
    // together every tick in applyStats() below (mirrored up-peak/
    // down-valley graph, same mechanism as plasmatop-gpu's utilization/
    // VRAM row).
    property var _upHistory: []
    property var _downHistory: []
    readonly property int historyLength: 60

    // --- Auto-scaling graph ceiling ------------------------------------------
    // Throughput has no fixed natural maximum the way utilization (0-100%)
    // or temperature (0-100 C) do, so the graph's maxValue can't be a fixed
    // constant — a 0-vs-100Mbps fixed scale would make idle traffic
    // invisible, while a 0-vs-1KB/s scale would clip the very next burst.
    // Reference (per AGENTS.md task brief, a quick look rather than a full
    // spike — no btop/bashtop binary available on this machine to trace
    // exactly): terminal system monitors generally solve this with an
    // auto-scaling ceiling that adapts to recent peak throughput rather
    // than a fixed constant, so the graph stays readably filled at both
    // idle and bursty rates.
    //
    // Approximation implemented here, in updateScaleMax(): _scaleMax snaps
    // UP instantly to whatever the current tick's peak actually is (so a
    // real burst is never clipped even for one frame), but only decays
    // DOWN slowly afterwards (multiplied by _scaleDecay each tick it isn't
    // re-raised) — so the graph doesn't "flatten to noise" the instant a
    // single burst ends, while still eventually re-zooming to a quieter
    // scale once sustained traffic actually drops. _scaleFloor keeps a
    // genuinely idle connection from zooming all the way down to near-zero
    // (which would make its own tiny noise look artificially saturated).
    readonly property real _scaleFloor: 64 * 1024 // 64 KB/s floor
    readonly property real _scaleDecay: 0.97      // per-tick multiplicative decay
    property real _scaleMax: _scaleFloor

    function updateScaleMax(txBps, rxBps) {
        const sampleMax = Math.max(txBps, rxBps, root._scaleFloor);
        root._scaleMax = Math.max(sampleMax, root._scaleMax * root._scaleDecay);
    }

    // fullRepresentation is instantiated lazily by Plasma in a separate QML
    // context (same reasoning as plasmatop-gpu's identical property — see
    // its comment for the full explanation of why a plain id reference
    // doesn't reach across that boundary).
    property Item _activeFullItem: null

    // --- Graph color thresholds ----------------------------------------------
    // Deliberately set so the graph always renders in the single "good"
    // color, not a real green/yellow/red split like GPU/CPU's fixed-scale
    // metrics — see contents/config/main.xml's doc comment for the
    // "no per-metric threshold config" reasoning, and this comment for why
    // even a FIXED good/warn split (originally 0.6/0.85, matching the
    // other widgets) turned out actively misleading once tried live:
    // _scaleMax auto-scales to snap UP to match whatever the newest sample
    // is (see updateScaleMax() above), so a genuinely ordinary traffic
    // burst that sets a new recent-peak is, by construction, always at or
    // extremely close to fraction 1.0 of its own just-updated ceiling —
    // confirmed on a live plasmoidviewer screenshot during this widget's
    // verification pass, where perfectly normal ~40 KB/s upload painted
    // solid badColor (#dc4c4c) for this exact reason, on nearly every
    // tick that set a new peak (i.e. most ticks, especially early on).
    // A relative-to-recent-peak severity color is fundamentally at odds
    // with a relative-to-recent-peak SCALE: the tallest bar on screen is
    // near-tautologically "at ~100% of the axis" without that meaning
    // anything is actually wrong. Per the task brief's own suggested
    // fallback ("tie the color scale to the auto-scaling max, e.g. always
    // mid-green, since it's relative"), goodMax is set to 1.0 here so
    // colorForFraction() (shared/theme/ColorScale.qml) always returns
    // goodColor — the auto-scaling AXIS still does the actual "how busy is
    // this" signaling (a full-height bar already reads as "near recent
    // peak"), color just stops trying to double as a second, misleading
    // severity signal on top of it.
    readonly property real throughputGoodMax: 1.0
    readonly property real throughputWarnMax: 1.0

    // --- Generic metric-row model (see shared/theme/MetricRow.qml) ---------
    // Just ONE descriptor: the mirrored up(peak)/down(valley) graph. Unlike
    // GPU/CPU's percent/temperature metrics, both readouts need
    // dynamically-scaled unit labels ("842 KB/s", "2.4 MB/s") rather than a
    // fixed decimals+unit suffix, hence routing BOTH through
    // displayOverride/valleyDisplayOverride (formatRate() below) instead of
    // leaving unit/decimals for MetricRow to apply directly.
    readonly property var metrics: [
        {
            key: "throughput", label: "UP", style: "graph",
            value: root.txBytesPerSec, maxValue: root._scaleMax, unit: "", decimals: 0,
            goodMax: root.throughputGoodMax, warnMax: root.throughputWarnMax,
            history: root._upHistory,
            displayOverride: root.interfaceName ? root.formatRate(root.txBytesPerSec) : "—",

            valleyLabel: "DOWN",
            valleyValue: root.rxBytesPerSec, valleyMaxValue: root._scaleMax, valleyUnit: "", valleyDecimals: 0,
            valleyGoodMax: root.throughputGoodMax, valleyWarnMax: root.throughputWarnMax,
            valleyHistory: root._downHistory,
            valleyDisplayOverride: root.interfaceName ? root.formatRate(root.rxBytesPerSec) : "—"
        }
    ]

    // --- User-configurable text/frame colors --------------------------------
    // Same meaning/defaults as every other plasmatop widget's identical
    // properties — see plasmatop-gpu/contents/ui/main.qml's equivalents for
    // the full rationale (kept brief here to avoid duplicating that essay).
    readonly property color fontColor: Plasmoid.configuration.fontColor || "#eeeeee"
    readonly property color frameColor: Plasmoid.configuration.frameColor || "#606060"
    readonly property color meterBackgroundColor: Plasmoid.configuration.meterBackgroundColor || "#404040"

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    toolTipMainText: Plasmoid.title
    toolTipSubText: root.haveData
        ? "↑ %1  •  ↓ %2".arg(root.formatRate(root.txBytesPerSec)).arg(root.formatRate(root.rxBytesPerSec))
        : "Waiting for data…"

    // --- Dynamic unit-scaled throughput formatting --------------------------
    // Unlike GPU/CPU's fixed-unit metrics (a percent or a temperature always
    // gets the same suffix), throughput needs its UNIT to change with
    // magnitude ("12 B/s" at idle, "842 KB/s" browsing, "2.4 MB/s" during a
    // download) — this is what MetricRow.qml's new valleyDisplayOverride
    // field (mirroring the existing displayOverride) exists to carry for
    // the valley (down) readout, alongside displayOverride for the peak
    // (up) one.
    function formatRate(bytesPerSec) {
        let v = bytesPerSec;
        if (!isFinite(v) || v < 0) {
            v = 0;
        }
        if (v < 1024) {
            return Math.round(v) + " B/s";
        }
        if (v < 1024 * 1024) {
            return (v / 1024).toFixed(1) + " KB/s";
        }
        if (v < 1024 * 1024 * 1024) {
            return (v / (1024 * 1024)).toFixed(1) + " MB/s";
        }
        return (v / (1024 * 1024 * 1024)).toFixed(1) + " GB/s";
    }

    // --- Data source: run net-stats.sh, parse its one-line JSON ------------
    Plasma5Support.DataSource {
        id: statsSource
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);

            const exitCode = data["exit code"];
            if (exitCode !== 0) {
                console.warn("plasmatop-net: net-stats.sh exited with code", exitCode, data["stderr"]);
                return;
            }

            let stats;
            try {
                stats = JSON.parse(data["stdout"]);
            } catch (e) {
                console.warn("plasmatop-net: failed to parse stats JSON:", e, data["stdout"]);
                return;
            }

            if (!stats.ok) {
                // No default route right now (offline, networking still
                // coming up) or the detected interface vanished from
                // /proc/net/dev between the script's two reads — both are
                // legitimate "no data right now" states, not crashes. Reset
                // to the waiting sentinel ("—", same convention as every
                // other plasmatop widget's haveData/displayOverride
                // pattern) rather than freezing on stale numbers, and clear
                // _prevStats so a later reconnect starts a fresh baseline
                // instead of computing a delta across the outage.
                console.warn("plasmatop-net: net-stats.sh reported no data:", stats.error);
                root.haveData = false;
                root.interfaceName = "";
                root.rxBytesPerSec = 0;
                root.txBytesPerSec = 0;
                root._prevStats = null;
                return;
            }

            root.applyStats(stats);
        }

        function poll() {
            // main.qml lives in contents/ui/; the script lives in
            // contents/scripts/ (ARCHITECTURE.md's package layout), hence ../.
            const scriptPath = Qt.resolvedUrl("../scripts/net-stats.sh").toString().replace("file://", "");
            connectSource(scriptPath);
        }
    }

    Timer {
        id: pollTimer
        // Fallback avoids a transient NaN interval during the async
        // KConfigXT load race — same pattern/reasoning as every other
        // Plasmoid.configuration.* read in this project.
        interval: (Plasmoid.configuration.pollInterval || 1.5) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsSource.poll()
    }

    // --- Delta math: raw byte counters -> bytes/sec -------------------------
    function applyStats(stats) {
        const prev = root._prevStats;
        root.interfaceName = stats.interface;

        if (prev !== null && prev.interface === stats.interface) {
            const dtMs = stats.timestamp_ms - prev.timestamp_ms;

            if (dtMs > 0) {
                const dRx = stats.rx_bytes - prev.rx_bytes;
                const dTx = stats.tx_bytes - prev.tx_bytes;

                // Guards against this interface's counters having reset
                // (e.g. the NIC was reset/replugged between polls, which
                // zeroes /proc/net/dev's counters for it) -- skip this
                // tick's math rather than showing a negative or
                // nonsensical rate, same spirit as plasmatop-gpu's
                // "dTotal <= 0" guard in engineBusyPercent().
                if (dRx >= 0 && dTx >= 0) {
                    root.rxBytesPerSec = dRx / (dtMs / 1000);
                    root.txBytesPerSec = dTx / (dtMs / 1000);

                    root._upHistory.push(root.txBytesPerSec);
                    root._downHistory.push(root.rxBytesPerSec);
                    while (root._upHistory.length > root.historyLength) {
                        root._upHistory.shift();
                        root._downHistory.shift();
                    }

                    root.updateScaleMax(root.txBytesPerSec, root.rxBytesPerSec);

                    if (root._activeFullItem) {
                        root._activeFullItem.pushThroughputSample(root.txBytesPerSec, root.rxBytesPerSec);
                    }

                    root.haveData = true;
                }
            }
        }
        // else: either the very first sample ever, or the default-route
        // interface changed since the last tick (wifi reconnect, docking/
        // undocking, VPN up/down) -- deliberately do NOT compute a delta
        // across two DIFFERENT interfaces' independent byte counters, which
        // would produce a meaningless (often huge, or negative) spike. Just
        // adopt this tick's counters as the new baseline below and wait for
        // the NEXT tick to produce a valid same-interface delta -- same
        // "a fresh baseline is fine, a cross-baseline delta is not" spirit
        // as plasmatop-gpu's per-client busy-time tracking.

        root._prevStats = stats;
    }

    // --- Compact (panel) representation -------------------------------------
    // Throughput has no natural 0-100% ceiling the way utilization does, so
    // there's no obvious single bar/percentage to show at panel size (see
    // AGENTS.md task brief). Chosen instead: both up and down rates as
    // compact bracketed text, "[↑842K ↓12K]" -- keeps the "up top, down"
    // duality legible even in the small panel view rather than collapsing
    // it to one combined total, while staying simple enough to fit.
    compactRepresentation: MouseArea {
        id: compactRoot

        Layout.minimumWidth: Kirigami.Units.gridUnit * 5
        Layout.preferredWidth: Kirigami.Units.gridUnit * 7
        Layout.minimumHeight: Kirigami.Units.gridUnit
        Layout.fillHeight: true

        onClicked: root.expanded = !root.expanded

        Row {
            anchors.centerIn: parent
            spacing: 2

            Text {
                text: "["
                font.family: "monospace"
                font.bold: true
                color: root.frameColor
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.interfaceName
                    ? ("↑" + root.formatRate(root.txBytesPerSec) + " ↓" + root.formatRate(root.rxBytesPerSec))
                    : "—"
                font.family: "monospace"
                font.pixelSize: Math.max(9, Math.min(compactRoot.height - 4, 13))
                color: root.fontColor
                style: Text.Outline
                styleColor: "#000000"
                anchors.verticalCenter: parent.verticalCenter
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

        // Portrait-friendly default, matching plasmatop-gpu's own default
        // (its primary target is a portrait-rotated desktop monitor) --
        // shorter than GPU's since this widget has only one metric row
        // instead of four.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Kirigami.Units.gridUnit * 10

        // Estimated (not yet cross-checked with a PySide6 offscreen harness
        // the way plasmatop-gpu's minimums were, per its own dated comment
        // -- flagged as unverified-by-measurement in this widget's report):
        // one graph row's implicitHeight (Kirigami.Units.gridUnit * 3.6)
        // plus AsciiBox's frame overhead (~43px measured for GPU, same
        // AsciiBox instance) plus a small buffer. Cross-checked instead by
        // live plasmoidviewer/desktop screenshot for visible clipping or
        // excess dead space -- see this widget's verification notes.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6.5

        // Exposed so applyStats() above can push live up/down samples
        // straight into the throughput MetricRow's mirrored Sparkline.
        function pushThroughputSample(upV, downV) {
            netRow.pushValue(upV, downV);
        }

        Component.onCompleted: root._activeFullItem = fullRoot
        Component.onDestruction: {
            if (root._activeFullItem === fullRoot) {
                root._activeFullItem = null;
            }
        }

        Theme.AsciiBox {
            anchors.fill: parent
            title: i18n("NET")
            backgroundColor: Qt.rgba(0, 0, 0, Plasmoid.configuration.backgroundOpacity || 0.0)
            borderColor: root.frameColor

            // Detected primary interface name in the box header, next to
            // the title -- mirrors plasmatop-gpu's frequency-in-header
            // pattern (R6 item 4), gives an at-a-glance "which interface is
            // this" without a dedicated row, per the task brief.
            trailingText: root.interfaceName || "—"
            trailingColor: root.fontColor

            ColumnLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing / 2

                Theme.MetricRow {
                    id: netRow
                    Layout.fillWidth: true
                    // Epic 7: graph row now grows vertically with the
                    // widget instead of leaving the trailing filler Item
                    // (removed below) to eat all the extra resize space.
                    // Floor matches MetricRow's own internal
                    // graphMinimumHeight (3.6 gridUnit) so this row can't
                    // be squeezed thinner than its pre-Epic-7 fixed size.
                    Layout.fillHeight: true
                    Layout.minimumHeight: netRow.graphMinimumHeight
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
