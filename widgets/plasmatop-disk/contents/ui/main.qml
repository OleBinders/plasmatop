/*
    plasmatop-disk — main.qml

    btop-style disk usage monitor. Data sourcing follows ARCHITECTURE.md's
    pattern for all five plasmatop widgets: Plasma5Support.DataSource
    (executable engine) running contents/scripts/disk-stats.sh on a QML
    Timer, JSON-parsed in onNewData. Like plasmatop-mem, there is NO delta
    math anywhere here — every figure disk-stats.sh reports (used/total
    bytes per mount) is an instantaneous gauge, used directly with no
    previous-tick baseline.

    Unlike every other plasmatop widget so far, the NUMBER OF ROWS is not
    fixed at write-time: disk-stats.sh discovers however many real,
    non-tiny, deduplicated mounts exist on THIS machine (3 here — root,
    a games drive, an external drive — but genuinely variable across
    machines, and even run-to-run on the same machine as drives get
    plugged in/out). This is the same class of problem plasmatop-cpu's
    per-core rows solved with shared/theme/CoreGrid.qml (a ListModel-backed
    Repeater, not a reassigned plain-array Repeater.model — see that file's
    header for the full empirical diagnosis of why the latter silently
    fails to refresh). This widget uses a purpose-built sibling component,
    shared/theme/MountList.qml, rather than CoreGrid.qml itself — see that
    file's header for why a new component was the right call (single
    column, not a density grid; label text of unknown/variable length, not
    a small fixed "C0".."C11" vocabulary).
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

    // --- Live data, updated straight from applyStats() below -- raw
    // instantaneous gauges from disk-stats.sh, no delta math. Each element:
    // {mountpoint, source, label, usedBytes, totalBytes}. Rebuilt as a
    // fresh array every tick (not mutated in place) so every binding that
    // reads it (toolTipSubText, _rootMount below) re-evaluates correctly --
    // in-place mutation of a `property var` array's contents does NOT fire
    // QML's change notification on the outer property, the same
    // reactivity trap Sparkline/MetricRow's history handling documents
    // elsewhere in this project.
    property var _mounts: []
    property bool haveData: false

    // Single shared good/warn threshold pair applied to EVERY mount row --
    // not one pair per mount, which wouldn't scale to a variable,
    // runtime-unknown list of drives (see main.xml's diskGoodMax/
    // diskWarnMax doc comment for the 80%/90% default reasoning).
    readonly property real diskGoodMax: Plasmoid.configuration.diskGoodMax || 0.80
    readonly property real diskWarnMax: Plasmoid.configuration.diskWarnMax || 0.90

    // --- User-configurable text/frame colors, same shape as every other
    // plasmatop widget ------------------------------------------------------
    readonly property color fontColor: Plasmoid.configuration.fontColor || "#eeeeee"
    readonly property color frameColor: Plasmoid.configuration.frameColor || "#606060"
    readonly property color meterBackgroundColor: Plasmoid.configuration.meterBackgroundColor || "#404040"

    // The compactRepresentation shows a single bar for the ROOT mount only
    // (or the first surviving mount if this machine somehow has no "/" --
    // e.g. a container/chroot-like environment), matching CPU's
    // "compact = simplified single stat, full = complete list" pattern.
    // disk-stats.sh already sorts its output by mountpoint, so "/" (if
    // present) is always _mounts[0] -- this still searches explicitly
    // rather than assuming that, so a future change to the script's sort
    // order can't silently break the compact view.
    readonly property var _rootMount: root._findRootMount()
    readonly property real rootUsedBytes: root._rootMount ? root._rootMount.usedBytes : 0
    readonly property real rootTotalBytes: root._rootMount ? root._rootMount.totalBytes : 1
    readonly property string rootLabel: root._rootMount ? root._rootMount.label : "—"
    readonly property real rootUsedPercent: root.rootTotalBytes > 0
        ? (root.rootUsedBytes / root.rootTotalBytes) * 100 : 0

    function _findRootMount() {
        if (!root._mounts || root._mounts.length === 0) {
            return null;
        }
        for (let i = 0; i < root._mounts.length; i++) {
            if (root._mounts[i].mountpoint === "/") {
                return root._mounts[i];
            }
        }
        return root._mounts[0];
    }

    // fullRepresentation is instantiated lazily by Plasma in a separate QML
    // context, so it registers itself here (same pattern as plasmatop-gpu's
    // _activeFullItem) giving root a real object reference to push updates
    // into its Theme.MountList.
    property Item _activeFullItem: null

    // Short, generic, all-caps display label from a mount's basename --
    // "/" is a special case (basename of "/" is empty), everything else is
    // just "last non-empty path segment, uppercased". Not hardcoded to any
    // specific mount name -- verified against this machine's real three
    // mounts: "/" -> "ROOT", "/home/olebinders/Games" -> "GAMES",
    // "/run/media/olebinders/Lagring" -> "LAGRING".
    function deriveLabel(mountpoint) {
        if (mountpoint === "/") {
            return "ROOT";
        }
        const segments = mountpoint.split("/").filter(s => s.length > 0);
        const base = segments.length > 0 ? segments[segments.length - 1] : mountpoint;
        return base.toUpperCase();
    }

    // Adaptive-unit "62% (295.0/464.0 GiB)" detail string for the tooltip,
    // same idea as plasmatop-net's dynamically-scaled rate units but for a
    // static size instead of a rate: GiB for anything under 1 TiB, TiB
    // above that (this machine's ~1.9TB Games drive would render as an
    // awkward "519.0/1863.0 GiB" otherwise). Both used and total are shown
    // in the SAME unit (chosen by the total's own magnitude), not
    // independently, so the pair stays directly comparable at a glance.
    function formatMountDetail(usedBytes, totalBytes) {
        const pct = totalBytes > 0 ? Math.round((usedBytes / totalBytes) * 100) : 0;
        const GIB = 1024 * 1024 * 1024;
        const TIB = GIB * 1024;
        if (totalBytes >= TIB) {
            return pct + "% (" + (usedBytes / TIB).toFixed(2) + "/" + (totalBytes / TIB).toFixed(2) + " TiB)";
        }
        return pct + "% (" + (usedBytes / GIB).toFixed(1) + "/" + (totalBytes / GIB).toFixed(1) + " GiB)";
    }

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    toolTipMainText: Plasmoid.title
    // Full used/total detail per mount, same tooltip-detail-vs-inline-
    // percent split as plasmatop-mem (see that widget's formatMemPercent()
    // comment): each mount ROW's own inline label stays a short "ROOT 64%"
    // (see MountList.qml's header for why -- a fuller inline label
    // collapsed MEM's BarMeter track to ~0px on the real desktop), with
    // the full "64% (295.0/464.0 GiB)" detail available here instead,
    // for every mount at once.
    toolTipSubText: root.haveData && root._mounts.length > 0
        ? root._mounts.map(m => m.label + " " + root.formatMountDetail(m.usedBytes, m.totalBytes)).join("  •  ")
        : "Waiting for data…"

    // --- Data source: run disk-stats.sh, parse its one-line JSON ----------
    Plasma5Support.DataSource {
        id: statsSource
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);

            const exitCode = data["exit code"];
            if (exitCode !== 0) {
                console.warn("plasmatop-disk: disk-stats.sh exited with code", exitCode, data["stderr"]);
                return;
            }

            let stats;
            try {
                stats = JSON.parse(data["stdout"]);
            } catch (e) {
                console.warn("plasmatop-disk: failed to parse stats JSON:", e, data["stdout"]);
                return;
            }

            if (!stats.ok) {
                console.warn("plasmatop-disk: disk-stats.sh reported an error");
                return;
            }

            root.applyStats(stats);
        }

        function poll() {
            // main.qml lives in contents/ui/; the script lives in
            // contents/scripts/ (ARCHITECTURE.md's package layout), hence ../.
            const scriptPath = Qt.resolvedUrl("../scripts/disk-stats.sh").toString().replace("file://", "");
            connectSource(scriptPath);
        }
    }

    Timer {
        id: pollTimer
        // Same async-config-load-race fallback as every other plasmatop
        // widget's Timer -- Plasmoid.configuration.pollInterval reads back
        // undefined for a moment during applet startup, which would
        // otherwise evaluate interval to NaN and silently break repeat
        // scheduling. Default (5.0s) is the slowest of any plasmatop
        // widget's default -- disk space changes far more slowly than
        // CPU/GPU/memory, and each tick shells out to df once per
        // surviving mount, so there's no benefit to polling as often as
        // GPU/CPU/MEM do (see main.xml's pollInterval doc comment).
        interval: (Plasmoid.configuration.pollInterval || 5.0) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsSource.poll()
    }

    // Raw values straight from disk-stats.sh's stateless JSON -- no delta
    // math, no previous-tick baseline, same as plasmatop-mem. The mount
    // LIST is assumed stable in count/order for the plasmoid's lifetime
    // (per MountList.qml's header -- mounts don't typically change while
    // it's running), but this still detects a count change defensively
    // (e.g. a drive unplugged mid-session) and does a full MountList
    // re-init rather than silently mismatching indices against a stale
    // ListModel.
    function applyStats(stats) {
        const rawMounts = stats.mounts || [];
        const previousCount = root._mounts.length;

        root._mounts = rawMounts.map(m => ({
            mountpoint: m.mountpoint,
            source: m.source,
            label: root.deriveLabel(m.mountpoint),
            usedBytes: m.used_bytes,
            totalBytes: m.total_bytes
        }));

        if (root._activeFullItem) {
            if (rawMounts.length !== previousCount) {
                root._activeFullItem.initMountList(root._mounts);
            } else {
                for (let i = 0; i < root._mounts.length; i++) {
                    root._activeFullItem.updateMountUsage(i, root._mounts[i].usedBytes, root._mounts[i].totalBytes);
                }
            }
        }

        haveData = true;
    }

    // --- Compact (panel) representation -------------------------------------
    // btop-style: a single segmented bar for the ROOT mount, not the
    // generic Plasma progress-bar look this project exists to replace.
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
                value: root.rootUsedBytes
                maxValue: root.rootTotalBytes
                label: root.haveData ? (root.rootLabel + " " + Math.round(root.rootUsedPercent) + "%") : "—"
                goodMax: root.diskGoodMax
                warnMax: root.diskWarnMax
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

        // Row count is genuinely unknown until the first real tick (3 on
        // this machine, but this widget must not assume that) -- height
        // hints below scale with it instead of a single fixed guess, so a
        // machine with more surviving drives doesn't silently overflow a
        // box sized for this one. Falls back to 1 before the first tick
        // arrives, so the box isn't degenerate-tiny while waiting for data.
        readonly property int rowCount: Math.max(1, root._mounts.length)

        // Per-row cost/frame-overhead figures extrapolated from
        // plasmatop-gpu's/plasmatop-mem's own measured (not guessed)
        // numbers on this machine (see those files' Layout.minimumHeight
        // comments): ~17px per bar row + ~2px inter-row gap, ~43px AsciiBox
        // frame overhead, gridUnit=18px here. A small buffer on top of the
        // raw math (same spirit as those two widgets) rather than the bare
        // computed minimum.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Kirigami.Units.gridUnit * (4 + fullRoot.rowCount * 1.5)
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * (2.5 + fullRoot.rowCount * 1.1)

        // Exposed so applyStats() above can (re)populate/update the
        // Theme.MountList without root needing to reach into fullRoot's
        // internals directly -- same _activeFullItem registration pattern
        // as plasmatop-gpu's pushUtilSample().
        function initMountList(mounts) {
            mountListItem.initMounts(mounts.map(m => ({ label: m.label, mountpoint: m.mountpoint })));
            for (let i = 0; i < mounts.length; i++) {
                mountListItem.setMountUsage(i, mounts[i].usedBytes, mounts[i].totalBytes);
            }
        }
        function updateMountUsage(index, usedBytes, totalBytes) {
            mountListItem.setMountUsage(index, usedBytes, totalBytes);
        }

        Component.onCompleted: {
            root._activeFullItem = fullRoot;
            // Re-hydrate immediately from whatever root already knows --
            // covers the popup-closed-then-reopened case, where this Item
            // (and its MountList's ListModel) is recreated from scratch but
            // root's data survives (same rehydration need as Sparkline's
            // setHistory() call elsewhere in this project).
            if (root._mounts.length > 0) {
                fullRoot.initMountList(root._mounts);
            }
        }
        Component.onDestruction: {
            if (root._activeFullItem === fullRoot) {
                root._activeFullItem = null;
            }
        }

        Theme.AsciiBox {
            anchors.fill: parent
            title: i18n("DISK")
            backgroundColor: Qt.rgba(0, 0, 0, Plasmoid.configuration.backgroundOpacity || 0.0)
            borderColor: root.frameColor

            ColumnLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing / 2

                Theme.MountList {
                    id: mountListItem
                    Layout.fillWidth: true
                    goodMax: root.diskGoodMax
                    warnMax: root.diskWarnMax
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
