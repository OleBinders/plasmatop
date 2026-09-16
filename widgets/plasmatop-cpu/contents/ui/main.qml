/*
    plasmatop-cpu — main.qml

    btop-style CPU monitor: 12 logical cores (this machine's i5-10600K,
    research/r8-cpu-telemetry.md §0), package temperature, and aggregate
    frequency. Data sourcing follows ARCHITECTURE.md's pattern for all
    five plasmatop widgets: Plasma5Support.DataSource (executable engine)
    running contents/scripts/cpu-stats.sh on a QML Timer, JSON-parsed in
    onNewData. The script is stateless (prints raw current-state jiffie
    counters per core); busy% delta math happens here in QML using the
    previous tick's raw values -- the jiffie deltas already encode elapsed
    time, so (unlike GPU's watts/VRAM math) no wall-clock division is
    needed for the busy% formula itself (R8 §1).
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
    property int coreCount: 0              // discovered from the first tick
    property real tempPkgC: 0
    property real freqMhz: 0               // max across all logical cores
    property real avgUtilPercent: 0        // mean of all cores' busy%, for
                                            // the compact/panel view
    property bool haveData: false

    // Per-core busy% from the most recent tick, plain JS array index-
    // aligned with core number (0..coreCount-1). Reassigned wholesale each
    // tick and forwarded to the full representation's CoreGrid via an
    // explicit updateCores() call below -- NOT consumed by a Repeater
    // bound directly to this array, so the documented Repeater/array-
    // reassignment staleness bug (MetricRow.qml's header,
    // ARCHITECTURE.md) does not apply here. CoreGrid's own Repeater is
    // backed by a real ListModel instead (see shared/theme/CoreGrid.qml).
    property var _corePercents: []

    // Raw per-core jiffie counters from the previous tick, keyed by core
    // number string ("0".."11"), for delta computation. null until the
    // first sample arrives.
    property var _prevStats: null

    // fullRepresentation is instantiated lazily by Plasma in a separate
    // QML context, so it registers itself here (same pattern as
    // plasmatop-gpu's _activeFullItem) giving root a real object
    // reference it can push live per-core updates into.
    property Item _activeFullItem: null

    // Per-metric configurable thresholds (BACKLOG Epic 2 / GPU's Epic 1.6
    // precedent) -- utilization thresholds are ONE shared pair for every
    // per-core bar (not 12 individual ones, per spec), package
    // temperature gets its own pair.
    readonly property real tempScaleMax: 100
    readonly property real utilGoodMax: Plasmoid.configuration.utilGoodMax || 0.6
    readonly property real utilWarnMax: Plasmoid.configuration.utilWarnMax || 0.85
    readonly property real tempGoodMax: Plasmoid.configuration.tempGoodMax || 0.6
    readonly property real tempWarnMax: Plasmoid.configuration.tempWarnMax || 0.85

    // Single descriptor for the package-temperature MetricRow (the only
    // metric that needs the generic descriptor shape here -- the per-core
    // grid uses the dedicated CoreGrid component instead, since MetricRow
    // has no ListModel/variable-length machinery, per R8 §5).
    readonly property var tempMetric: ({
        key: "tempPkg", label: "PKG", style: "bar",
        value: root.tempPkgC, maxValue: root.tempScaleMax, unit: "°C", decimals: 1,
        goodMax: root.tempGoodMax, warnMax: root.tempWarnMax,
        displayOverride: root.haveData ? null : "—"
    })

    // --- User-configurable text/frame colors --------------------------------
    readonly property color fontColor: Plasmoid.configuration.fontColor || "#eeeeee"
    readonly property color secondaryFontColor: Qt.rgba(fontColor.r, fontColor.g, fontColor.b, 0.8)
    readonly property color frameColor: Plasmoid.configuration.frameColor || "#606060"
    readonly property color meterBackgroundColor: Plasmoid.configuration.meterBackgroundColor || "#404040"

    // NoBackground: draw our own opaque terminal-style frame (Theme.AsciiBox)
    // instead of Plasma's translucent default card, same rationale as
    // plasmatop-gpu.
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    toolTipMainText: Plasmoid.title
    toolTipSubText: root.haveData
        ? "Avg %1%  •  %2°C  •  %3 MHz".arg(Math.round(root.avgUtilPercent)).arg(root.tempPkgC.toFixed(0)).arg(Math.round(root.freqMhz))
        : "Waiting for data…"

    // --- Data source: run cpu-stats.sh, parse its one-line JSON ------------
    Plasma5Support.DataSource {
        id: statsSource
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);

            const exitCode = data["exit code"];
            if (exitCode !== 0) {
                console.warn("plasmatop-cpu: cpu-stats.sh exited with code", exitCode, data["stderr"]);
                return;
            }

            let stats;
            try {
                stats = JSON.parse(data["stdout"]);
            } catch (e) {
                console.warn("plasmatop-cpu: failed to parse stats JSON:", e, data["stdout"]);
                return;
            }

            if (!stats.ok) {
                console.warn("plasmatop-cpu: cpu-stats.sh reported an error");
                return;
            }

            root.applyStats(stats);
        }

        function poll() {
            // main.qml lives in contents/ui/; the script lives in
            // contents/scripts/ (ARCHITECTURE.md's package layout), hence ../.
            const scriptPath = Qt.resolvedUrl("../scripts/cpu-stats.sh").toString().replace("file://", "");
            connectSource(scriptPath);
        }
    }

    Timer {
        id: pollTimer
        // Fallback guards the async-config-load race at applet startup --
        // same pattern/rationale as plasmatop-gpu's identical Timer.
        interval: (Plasmoid.configuration.pollInterval || 1.5) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsSource.poll()
    }

    // --- Delta math: raw per-core jiffie counters -> busy% ------------------
    function applyStats(stats) {
        if (stats.temp_pkg_c !== null && stats.temp_pkg_c !== undefined) {
            tempPkgC = stats.temp_pkg_c;
        }

        let maxFreqKhz = 0;
        for (const k in stats.freq_khz) {
            if (stats.freq_khz[k] > maxFreqKhz) {
                maxFreqKhz = stats.freq_khz[k];
            }
        }
        freqMhz = maxFreqKhz / 1000;

        const coreKeys = Object.keys(stats.cpus).sort((a, b) => parseInt(a) - parseInt(b));

        if (root.coreCount === 0 && coreKeys.length > 0) {
            root.coreCount = coreKeys.length;
            if (root._activeFullItem) {
                root._activeFullItem.initCores(root.coreCount);
            }
        }

        const prev = root._prevStats;
        if (prev !== null) {
            const percents = [];
            let sumPercent = 0;

            for (const k of coreKeys) {
                const cur = stats.cpus[k];
                const prv = prev.cpus[k];
                if (!prv) {
                    percents.push(0);
                    continue;
                }

                // Busy% formula per R8 §1: sum ALL fields (including
                // steal) for total_delta; idle_delta is (idle+iowait)'s
                // own delta. Jiffie counters are monotonic across a
                // single boot, so dTotal <= 0 only happens on a genuine
                // counter reset/anomaly -- guarded to 0% rather than a
                // negative/divide-by-zero glitch.
                const idleCur = cur.idle + cur.iowait;
                const idlePrev = prv.idle + prv.iowait;
                const totalCur = cur.user + cur.nice + cur.system + cur.idle + cur.iowait + cur.irq + cur.softirq + cur.steal;
                const totalPrev = prv.user + prv.nice + prv.system + prv.idle + prv.iowait + prv.irq + prv.softirq + prv.steal;
                const dIdle = idleCur - idlePrev;
                const dTotal = totalCur - totalPrev;

                let pct = 0;
                if (dTotal > 0) {
                    pct = Math.max(0, Math.min(100, 100 * (1 - dIdle / dTotal)));
                }
                percents.push(pct);
                sumPercent += pct;
            }

            root._corePercents = percents;
            root.avgUtilPercent = percents.length > 0 ? sumPercent / percents.length : 0;

            if (root._activeFullItem) {
                root._activeFullItem.updateCores(percents);
            }

            haveData = true;
        }

        root._prevStats = stats;
    }

    // --- Compact (panel) representation -------------------------------------
    // A single aggregate bar (average utilization across all cores) in the
    // same bracket "[...]" + BarMeter style as plasmatop-gpu's panel view --
    // the 12-core grid doesn't fit a panel, so this is intentionally
    // simpler than the full view, same relationship GPU has between its
    // panel bar and full representation.
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
                value: root.avgUtilPercent
                maxValue: 100
                label: Math.round(root.avgUtilPercent) + "%"
                goodMax: root.utilGoodMax
                warnMax: root.utilWarnMax
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

        // Same portrait-friendly default footprint as plasmatop-gpu --
        // still just a default, user-resizable on the desktop.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Kirigami.Units.gridUnit * 14

        // Minimums measured the same way as plasmatop-gpu's (2026-09-14
        // debugging session, PySide6 offscreen harness rendering this
        // exact AsciiBox+ColumnLayout content tree with 12 populated
        // cores). Real numbers on this machine (gridUnit=18px):
        //   content ColumnLayout.implicitHeight = 117px (1 temp MetricRow
        //     ~17px + CoreGrid.topMargin smallSpacing=4 + CoreGrid's own
        //     implicitHeight=94px for 12 cores at 2 columns/6 rows)
        //   AsciiBox frame overhead = same ~43.4px as GPU's
        //   -> true minimum content height ~160px; minimumHeight below
        //      (9.5 gridUnit = 171px) adds a similar small buffer.
        //   Width is NOT as compressible as GPU's: the 12-core grid's 2
        //   columns each need room for a "C11 100%"-width label (~48px)
        //   plus a still-legible per-cell track, so the real width floor
        //   (~190px) sits close to the old 11-gridUnit/198px minimum --
        //   only a modest cut was possible here without visibly cramping
        //   the per-core bars, unlike GPU's much larger height slack.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10.5
        Layout.minimumHeight: Kirigami.Units.gridUnit * 9.5

        // Called from root.applyStats() the moment core count is first
        // known (or immediately below, on this item's own creation, if
        // root already knows it -- e.g. reopening the popup after the
        // first tick already happened).
        function initCores(count) {
            coreGrid.initCores(count);
        }

        // Called from root.applyStats() every tick with the freshly
        // computed per-core percentages.
        function updateCores(percents) {
            for (let i = 0; i < percents.length; i++) {
                coreGrid.setCoreValue(i, percents[i]);
            }
        }

        Component.onCompleted: {
            root._activeFullItem = fullRoot;
            // Reopening the popup after the widget has already been
            // running: root already knows the core count and has live
            // percentages, so hydrate immediately instead of waiting for
            // the next poll tick.
            if (root.coreCount > 0) {
                fullRoot.initCores(root.coreCount);
                fullRoot.updateCores(root._corePercents);
            }
        }
        Component.onDestruction: {
            if (root._activeFullItem === fullRoot) {
                root._activeFullItem = null;
            }
        }

        Theme.AsciiBox {
            anchors.fill: parent
            title: i18n("CPU")
            backgroundColor: Qt.rgba(0, 0, 0, Plasmoid.configuration.backgroundOpacity || 0.0)
            borderColor: root.frameColor

            // Aggregate (max) frequency in the box header, per R8 §4 --
            // matches GPU's trailingText slot for the same kind of
            // header-level identity readout.
            trailingText: root.haveData ? Math.round(root.freqMhz) + " MHz" : "—"
            trailingColor: root.fontColor

            ColumnLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing / 2

                Theme.MetricRow {
                    Layout.fillWidth: true
                    metric: root.tempMetric
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                }

                Theme.CoreGrid {
                    id: coreGrid
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    goodMax: root.utilGoodMax
                    warnMax: root.utilWarnMax
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                }

                Item { Layout.fillHeight: true }
            }
        }
    }
}
