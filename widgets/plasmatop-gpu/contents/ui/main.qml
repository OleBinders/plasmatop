/*
    plasmatop-gpu — main.qml

    btop-style GPU monitor for the Intel Arc B580 (Xe driver). Data sourcing
    follows ARCHITECTURE.md's pattern for all five plasmatop widgets:
    Plasma5Support.DataSource (executable engine) running
    contents/scripts/gpu-stats.sh on a QML Timer, JSON-parsed in onNewData.
    The script is stateless (prints raw current-state counters); all delta
    math (utilization %, watts) happens here in QML, using the previous
    tick's raw values and the actual elapsed wall time between ticks.
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
    property real utilizationPercent: 0    // 0..100, max(rcs, ccs) busy fraction
    property real tempPkgC: 0
    property real tempVramC: 0
    property real freqMhz: 0
    property real powerWatts: -1           // -1 until we have two samples to delta
    property bool haveData: false

    // --- VRAM used % (Epic 1.7) ---------------------------------------------
    // vram_kib is an instantaneous gauge per client (not a cumulative
    // counter, see gpu-stats.sh's header) -- summed directly across
    // whichever clients are present THIS tick, no delta math/previous-tick
    // baseline needed, unlike utilizationPercent above.
    property real vramUsedBytes: 0
    // No sysfs/ioctl-from-bash source for total VRAM capacity exists on
    // the xe driver (research/r2 section 2) -- configurable default seeded
    // from nvtop's own live-observed figure for this GPU (see main.xml's
    // vramTotalGib doc comment for the full justification).
    readonly property real vramTotalBytes: (Plasmoid.configuration.vramTotalGib || 11.93) * 1024 * 1024 * 1024
    readonly property real vramUsedPercent: vramTotalBytes > 0 ? Math.min(100, (vramUsedBytes / vramTotalBytes) * 100) : 0

    // Raw stats from the previous tick, for delta computation (freq/temp/
    // energy only now -- see _prevClientStats below for per-client busy
    // tracking). null until the first sample arrives.
    property var _prevStats: null

    // Per-client-id busy-time tracking, PERSISTENT across ticks (not
    // replaced wholesale every tick). Keyed by drm-client-id (string) ->
    // {cycles, total_cycles} per engine, plus a lastSeenTick counter for
    // pruning. This is deliberately NOT "just last tick's snapshot":
    // keeping an entry around even on ticks where that client doesn't
    // appear in gpu-stats.sh's output means a short-lived or transiently-
    // churning DRM client only needs to be seen in ANY two ticks (not
    // necessarily consecutive ones) to produce a valid delta. Fixes the
    // tester-found "client churn between polls silently zeroes a tick"
    // bug at the root instead of patching around it -- see
    // engineBusyPercent()/applyStats() below and gpu-stats.sh's header
    // comment for the full diagnosis (R5 / BACKLOG Epic 1.6).
    property var _prevClientStats: ({})
    property int _tickCounter: 0
    // ~5 minutes of poll ticks at the default 1.5s interval -- generous
    // grace period for a churning client to reappear, while still
    // bounding memory growth from processes that are gone for good.
    readonly property int _clientStalenessTicks: 200

    // Utilization/VRAM% history kept at the root so it survives the full
    // representation being destroyed/recreated when the popup closes and
    // reopens (see Theme.Sparkline.setHistory()). Index-aligned -- pushed
    // together every tick in applyStats() below (Epic 1.7's mirrored
    // utilization-peak/VRAM-valley graph).
    property var _utilHistory: []
    property var _vramHistory: []
    readonly property int historyLength: 60

    // fullRepresentation is instantiated lazily by Plasma (via its own
    // internal Loader/Component machinery) in a separate QML context, so an
    // id declared inside it (e.g. the Sparkline) is NOT reachable from root
    // by bare id -- confirmed empirically against the real PlasmoidItem type
    // before writing this. Instead, the full representation registers
    // itself here via Component.onCompleted/onDestruction (a plain property
    // write through the `root` reference, which IS visible from inside a
    // dynamically-created child context), giving root a real object
    // reference it can call into.
    property Item _activeFullItem: null

    // Temperature bars share one 0-100C scale (pkg "high" per `sensors` on
    // this machine is 60C, crit ~100C; vram crit ~105C -- both are legible
    // on the same scale). Good/warn THRESHOLDS below are now per-metric and
    // user-configurable (R5/R6, BACKLOG Epic 1.6) -- previously hardcoded
    // as fixed readonly properties shared by both temps (and 0.6/0.85
    // inlined a second time on the utilization BarMeter). Defaults match
    // the old hardcoded values exactly, so an un-configured widget's
    // thresholds are unchanged from before this refactor.
    readonly property real tempScaleMax: 100
    readonly property real utilGoodMax: Plasmoid.configuration.utilGoodMax || 0.6
    readonly property real utilWarnMax: Plasmoid.configuration.utilWarnMax || 0.85
    readonly property real tempPkgGoodMax: Plasmoid.configuration.tempPkgGoodMax || 0.60
    readonly property real tempPkgWarnMax: Plasmoid.configuration.tempPkgWarnMax || 0.85
    readonly property real tempVramGoodMax: Plasmoid.configuration.tempVramGoodMax || 0.60
    readonly property real tempVramWarnMax: Plasmoid.configuration.tempVramWarnMax || 0.85
    readonly property real vramGoodMax: Plasmoid.configuration.vramGoodMax || 0.6
    readonly property real vramWarnMax: Plasmoid.configuration.vramWarnMax || 0.85

    // --- Generic metric-row model (R5 shape B) ------------------------------
    // One descriptor per displayable metric, consumed by fullRepresentation's
    // Repeater<Theme.MetricRow> below -- see shared/theme/MetricRow.qml for
    // the descriptor shape documentation. compactRepresentation deliberately
    // does NOT use this model (product-owner "keep the panel view exactly
    // as it looks today" constraint) -- it keeps its own hand-written
    // BarMeter, unchanged, further down in this file.
    readonly property var metrics: [
        {
            // Mirrored dual-value graph (Epic 1.7): utilization as peaks
            // (upper half), VRAM used % as valleys (lower half) -- R7's
            // confirmed bashtop net-box pattern (two different values
            // sharing one mirrored graph), not its CPU-box pattern (one
            // value mirrored against itself), since utilization and VRAM%
            // are genuinely different metrics.
            key: "utilization", label: "UTIL", style: "graph",
            value: root.utilizationPercent, maxValue: 100, unit: "%", decimals: 0,
            goodMax: root.utilGoodMax, warnMax: root.utilWarnMax,
            history: root._utilHistory,
            displayOverride: root.haveData ? null : "—",

            valleyLabel: "VRAM",
            valleyValue: root.vramUsedPercent, valleyMaxValue: 100, valleyUnit: "%", valleyDecimals: 0,
            valleyGoodMax: root.vramGoodMax, valleyWarnMax: root.vramWarnMax,
            valleyHistory: root._vramHistory
        },
        {
            key: "tempPkg", label: "PKG", style: "bar",
            value: root.tempPkgC, maxValue: root.tempScaleMax, unit: "°C", decimals: 1,
            goodMax: root.tempPkgGoodMax, warnMax: root.tempPkgWarnMax
        },
        {
            key: "tempVram", label: "VRAM", style: "bar",
            value: root.tempVramC, maxValue: root.tempScaleMax, unit: "°C", decimals: 1,
            goodMax: root.tempVramGoodMax, warnMax: root.tempVramWarnMax
        },
        {
            key: "power", label: "Power", style: "text",
            value: root.powerWatts >= 0 ? root.powerWatts : 0, maxValue: 1, unit: " W", decimals: 1,
            displayOverride: root.powerWatts >= 0 ? null : "—"
        }
    ]

    // --- User-configurable text/frame colors --------------------------------
    // fontColor: value-readout color (MHz/W, BarMeter's "42%"/"51.0°C"
    // labels), matching the previous hardcoded #eeeeee. Primary labels
    // ("Utilization" etc., previously #cccccc) are the SAME configured
    // color at reduced opacity rather than a second config entry -- one
    // user-facing text-color control, with opacity doing the job the old
    // two hardcoded hex values did.
    readonly property color fontColor: Plasmoid.configuration.fontColor || "#eeeeee"
    readonly property color secondaryFontColor: Qt.rgba(fontColor.r, fontColor.g, fontColor.b, 0.8)

    // frameColor: AsciiBox border glyphs + the compact view's matching
    // "[...]" brackets, matching the previous hardcoded #606060.
    // Deliberately NOT applied to AsciiBox's titleColor: a user picking a
    // light/pale frameColor would make a frameColor-bound title unreadable
    // against its own border, so the title keeps AsciiBox's fixed bright
    // default instead of tracking this value.
    readonly property color frameColor: Plasmoid.configuration.frameColor || "#606060"

    // meterBackgroundColor: shared background/track color for both
    // BarMeter's bar track and Sparkline's graph background (one control
    // covering "the graph and the bars" together, per product-owner ask --
    // see main.xml's meterBackgroundColor doc comment). Matches BarMeter's
    // previous hardcoded default (#404040) so an un-configured widget's
    // bars look identical to before.
    readonly property color meterBackgroundColor: Plasmoid.configuration.meterBackgroundColor || "#404040"

    // NoBackground: the widget draws its own opaque terminal-style frame
    // (Theme.AsciiBox) instead of Plasma's translucent default card --
    // that translucent card was the actual cause of the "generic Plasma
    // widget" look flagged in product-owner review, since it let the
    // desktop wallpaper show through and washed out the meter contrast.
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    // Deliberately NOT setting preferredRepresentation: PlasmoidItem's
    // built-in default already does the right dual-context thing --
    // compactRepresentation in a panel (Horizontal/Vertical formFactor),
    // fullRepresentation directly when placed on the desktop (Planar
    // formFactor). Forcing compactRepresentation here (as some reference
    // plasmoids do, e.g. for a popup-only detail view) would make this
    // widget show only the small panel bar even as a standalone desktop
    // item, which is not the desired behavior for plasmatop-gpu.

    toolTipMainText: Plasmoid.title
    toolTipSubText: root.haveData
        ? "Util %1%  •  %2°C  •  %3 MHz".arg(Math.round(root.utilizationPercent)).arg(root.tempPkgC.toFixed(0)).arg(Math.round(root.freqMhz))
        : "Waiting for data…"

    // --- Data source: run gpu-stats.sh, parse its one-line JSON ------------
    Plasma5Support.DataSource {
        id: statsSource
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);

            const exitCode = data["exit code"];
            if (exitCode !== 0) {
                console.warn("plasmatop-gpu: gpu-stats.sh exited with code", exitCode, data["stderr"]);
                return;
            }

            let stats;
            try {
                stats = JSON.parse(data["stdout"]);
            } catch (e) {
                console.warn("plasmatop-gpu: failed to parse stats JSON:", e, data["stdout"]);
                return;
            }

            if (!stats.ok) {
                console.warn("plasmatop-gpu: gpu-stats.sh reported an error:", stats.error);
                return;
            }

            root.applyStats(stats);
        }

        function poll() {
            // main.qml lives in contents/ui/; the script lives in
            // contents/scripts/ (ARCHITECTURE.md's package layout), hence ../.
            const scriptPath = Qt.resolvedUrl("../scripts/gpu-stats.sh").toString().replace("file://", "");
            connectSource(scriptPath);
        }
    }

    Timer {
        id: pollTimer
        // Plasmoid.configuration.pollInterval reads back as undefined for a
        // moment during applet startup (KConfigXT loads asynchronously) --
        // confirmed live via plasmoidviewer: without this fallback,
        // interval briefly evaluates to NaN, which silently breaks Timer's
        // repeat scheduling (only the triggeredOnStart tick ever fires).
        // The fallback keeps this binding reactive: once configuration
        // loads, Plasmoid.configuration.pollInterval becomes truthy and the
        // expression re-evaluates to the real configured value.
        interval: (Plasmoid.configuration.pollInterval || 1.5) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsSource.poll()
    }

    // --- Delta math: raw counters -> percentages/watts ----------------------

    function applyStats(stats) {
        freqMhz = stats.freq_mhz;
        if (stats.temp_pkg_c !== null) {
            tempPkgC = stats.temp_pkg_c;
        }
        if (stats.temp_vram_c !== null) {
            tempVramC = stats.temp_vram_c;
        }

        root._tickCounter++;

        // VRAM used % (Epic 1.7): an instantaneous gauge, not a cumulative
        // counter (see gpu-stats.sh's header) -- just sum this tick's
        // per-client vram_kib snapshot directly, no previous-tick baseline
        // needed (unlike utilization's cycles-delta math below).
        let vramKibSum = 0;
        for (const cid in stats.clients) {
            vramKibSum += stats.clients[cid].vram_kib || 0;
        }
        vramUsedBytes = vramKibSum * 1024;

        const prev = root._prevStats;
        if (prev !== null) {
            const dtMs = stats.timestamp_ms - prev.timestamp_ms;

            if (dtMs > 0) {
                if (stats.energy_uj !== null && prev.energy_uj !== null) {
                    const dEnergyUj = stats.energy_uj - prev.energy_uj;
                    if (dEnergyUj >= 0) {
                        powerWatts = (dEnergyUj / 1e6) / (dtMs / 1000);
                    }
                }

                // GPU busy % = the busier of the render (rcs) and compute
                // (ccs) engines, per ARCHITECTURE.md/R2 §6's "combine engine
                // classes" guidance -- rcs covers normal desktop/3D
                // rendering, ccs covers compute workloads, and they mostly
                // don't saturate simultaneously on a desktop session.
                const rcsPct = engineBusyPercent("rcs", stats.clients);
                const ccsPct = engineBusyPercent("ccs", stats.clients);
                utilizationPercent = Math.max(rcsPct, ccsPct);

                root._utilHistory.push(utilizationPercent);
                root._vramHistory.push(vramUsedPercent);
                while (root._utilHistory.length > root.historyLength) {
                    root._utilHistory.shift();
                    root._vramHistory.shift();
                }
                if (root._activeFullItem) {
                    root._activeFullItem.pushUtilSample(utilizationPercent, vramUsedPercent);
                }

                haveData = true;
            }
        }

        updatePrevClientStats(stats.clients);
        root._prevStats = stats;
    }

    // Computes busy% for one engine class from PER-CLIENT counters (see
    // gpu-stats.sh's header comment for the full diagnosis of why the
    // previous pre-summed-totals approach was wrong, not just fragile).
    //
    // For each client-id present in this tick's snapshot AND in
    // root._prevClientStats (which persists across ticks, so a client
    // absent on the immediately-preceding tick but present earlier still
    // has a valid baseline), computes that client's own Δcycles/Δtotal.
    // drm-total-cycles-<engine> is a reference-clock counter that advances
    // at (approximately) the same rate for every concurrently-open
    // client -- it is NOT a shared "capacity" that gets divided among
    // clients -- so Δcycles is summed across qualifying clients (multiple
    // simultaneous clients can each contribute real busy time to the same
    // engine) but Δtotal is taken from a SINGLE representative client
    // (the max seen this tick), not summed. Summing Δtotal across N
    // clients was the root cause of the real-world "ComfyUI shows <=2%"
    // report: it inflated the denominator by ~N (this machine routinely
    // has 15-25 concurrent xe DRM clients), deflating any real workload's
    // true busy% by roughly that same factor regardless of client churn.
    function engineBusyPercent(engineName, curClients) {
        const prevClients = root._prevClientStats;
        let sumDCycles = 0;
        let maxDTotal = 0;

        for (const cid in curClients) {
            const prevClient = prevClients[cid];
            if (!prevClient) {
                continue; // no baseline yet for this client -- skip, not zero the whole tick
            }
            const curEngine = curClients[cid][engineName];
            const prevEngine = prevClient[engineName];
            if (!curEngine || !prevEngine) {
                continue;
            }
            const dCycles = curEngine.cycles - prevEngine.cycles;
            const dTotal = curEngine.total_cycles - prevEngine.total_cycles;
            // Guards against this specific client's counters having reset
            // (e.g. client-id reused by a new process) -- skip just that
            // client's contribution rather than zeroing every client's.
            if (dTotal <= 0 || dCycles < 0) {
                continue;
            }
            sumDCycles += dCycles;
            if (dTotal > maxDTotal) {
                maxDTotal = dTotal;
            }
        }

        if (maxDTotal <= 0) {
            return 0;
        }
        return Math.max(0, Math.min(100, (sumDCycles / maxDTotal) * 100));
    }

    // Merges this tick's client snapshot into the persistent tracking map
    // and prunes entries not seen in _clientStalenessTicks ticks, so the
    // map doesn't grow without bound as processes come and go over a long
    // uptime.
    function updatePrevClientStats(curClients) {
        const merged = root._prevClientStats;
        for (const cid in curClients) {
            const entry = curClients[cid];
            entry._lastSeenTick = root._tickCounter;
            merged[cid] = entry;
        }
        for (const cid in merged) {
            if (root._tickCounter - merged[cid]._lastSeenTick > root._clientStalenessTicks) {
                delete merged[cid];
            }
        }
        root._prevClientStats = merged;
    }

    // --- Compact (panel) representation -------------------------------------
    // btop-style: a single segmented bar for utilization (Theme.BarMeter,
    // Epic 1.7), not the generic Plasma progress-bar look this project
    // exists to replace.
    // Assigned directly (not wrapped in an explicit Component{}) so its
    // properties can bind straight to root's; it doesn't need to expose
    // anything back to root, unlike the full representation below.
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

            // Bracket characters flanking the bar -- a panel bar is too
            // short (one text line) for a full AsciiBox frame, but "[...]"
            // is the same "the GUI is built from real characters" idea
            // scaled down to fit, rather than dropping the aesthetic
            // entirely just because the space is small.
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
                value: root.utilizationPercent
                maxValue: 100
                label: Math.round(root.utilizationPercent) + "%"
                goodMax: 0.6
                warnMax: 0.85
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

        // Portrait-friendly default: this widget's primary target is a
        // portrait-rotated desktop monitor (1080x1920 physical), where it
        // sits alongside other desktop items rather than spanning the
        // screen -- so default to a narrow-ish card (a few hundred px
        // wide) that's taller than it is wide, not a landscape-wide panel
        // popup shape. Still just a default: on the desktop the user can
        // freely resize the item afterwards.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 13
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        // Minimums measured (2026-09-14 debugging session, PySide6 offscreen
        // harness rendering this exact AsciiBox+ColumnLayout content tree
        // with realistic worst-case sample values) rather than guessed --
        // the previous 11x15 gridUnit minimums left ~100px of dead space
        // below the content when dragged to their floor (flagged but not
        // acted on when this widget was first built). Real numbers on this
        // machine (gridUnit=18px, AsciiBox padding=8/borderPixelSize=13):
        //   content ColumnLayout.implicitHeight = 122px (4 MetricRows:
        //     graph row gridUnit*3.6=64.8, two bar rows ~17px each, one
        //     text row ~17px, +3 inter-row gaps of smallSpacing/2=2px)
        //   AsciiBox frame overhead = 2*topBottomRowHeight(17.7) +
        //     padding(8) = 43.4px vertically
        //   -> true minimum content height ~165px; minimumHeight below
        //      (9.5 gridUnit = 171px) adds a ~6px buffer, not ~100px.
        //   Width: BarMeter rows share meterLabelColumnWidth (86px, sized
        //     for the widest label "VRAM 100.0°C") + labelSpacing(4) + a
        //     still-legible minimum track (~48px/6 segments) = ~138px of
        //     content, + AsciiBox's left/right border+padding (~32px) ->
        //     ~170px; minimumWidth below (10 gridUnit = 180px) keeps a
        //     small buffer since width wasn't cross-checked with a live
        //     screenshot the way height was (see debugging session notes).
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 9.5

        // Exposed so applyStats() above can push live utilization/VRAM%
        // samples straight into the utilization MetricRow's mirrored
        // Sparkline (Epic 1.7).
        function pushUtilSample(utilV, vramV) {
            utilRow.pushValue(utilV, vramV);
        }

        // --- Shared right-edge column for "bar"-style MetricRows ---------------
        // Each BarMeter's track used to end at parent.width minus ITS OWN
        // label's text width, so a wider label pushed that row's track
        // further left than a narrower one. Fix: measure the widest label
        // string this widget can actually produce ("VRAM 100.0°C" -- the
        // "bar" style now folds the metric name prefix into the same label,
        // per R6 item 3, and pkg/VRAM temp could in principle hit 3 digits)
        // once via FontMetrics, at the same font BarMeter renders its label
        // in, then give every "bar" MetricRow here that same fixed
        // labelColumnWidth. Derived from font metrics, not a hardcoded
        // pixel value, so it stays correct across font/DPI changes.
        FontMetrics {
            id: meterLabelMetrics
            font.family: "monospace"
            // Mirrors BarMeter.qml's own label font-size formula,
            // Math.max(10, trackHeight - 2), for the default trackHeight
            // (14) every BarMeter below uses -- keep in sync if either
            // changes.
            font.pixelSize: Math.max(10, 14 - 2)
        }
        readonly property real meterLabelColumnWidth: meterLabelMetrics.advanceWidth("VRAM 100.0°C")

        Component.onCompleted: root._activeFullItem = fullRoot
        Component.onDestruction: {
            if (root._activeFullItem === fullRoot) {
                root._activeFullItem = null;
            }
        }

        Theme.AsciiBox {
            anchors.fill: parent
            title: i18n("GPU")
            // Fully transparent (0.0) by default per product-owner ask;
            // user-adjustable via the config slider. Black base color
            // matches the frame's original opaque default (#000000) so
            // dialing opacity up from 0 fades in the same look, just less
            // see-through.
            backgroundColor: Qt.rgba(0, 0, 0, Plasmoid.configuration.backgroundOpacity || 0.0)
            borderColor: root.frameColor
            // titleColor deliberately left at AsciiBox's own fixed default
            // rather than bound to frameColor -- see root.frameColor's
            // comment above.

            // Frequency moved into the box header, next to the title, per
            // R6 item 4 (bashtop shows clock speed once, as part of the
            // box's identity, not a repeated/tabular stat) -- replaces the
            // old bottom GridLayout's "Frequency:" row entirely.
            trailingText: root.haveData ? Math.round(root.freqMhz) + " MHz" : "—"
            trailingColor: root.fontColor

            ColumnLayout {
                anchors.fill: parent
                // Tightened per R6 item 6: once utilization's separate
                // label+bar+graph collapsed to one graph-with-overlay row
                // and each temperature's label+bar collapsed to one row,
                // there are only 4 rows left (down from 8) -- the previous
                // uniform smallSpacing read as noticeably looser once that
                // many fewer children remained, closer to the near-zero
                // inter-row gap real reference tools (bashtop/gtop/vtop)
                // use within a single box.
                spacing: Kirigami.Units.smallSpacing / 2

                // Generic metric-row model (R5 shape B): one MetricRow per
                // entry in root.metrics, reusing BarMeter/Sparkline/
                // ColorScale via shared/theme/MetricRow.qml -- see that
                // file for the descriptor shape.
                //
                // Bound by INDEX into root.metrics rather than via a
                // Repeater over that array -- found empirically (live
                // journalctl debug tracing) that QML's Repeater does not
                // reliably refresh existing delegates' `modelData` when a
                // NEW array (same length) is reassigned to `model` on every
                // tick, even though the underlying property value itself
                // genuinely updates. That's a real, documented Repeater +
                // plain-JS-array limitation, not a QML binding-reactivity
                // problem in general: an ordinary property expression like
                // `root.metrics[0]` (used directly below, no Repeater
                // involved) re-evaluates correctly whenever root.metrics
                // changes, exactly like every other binding in this file.
                // GPU's metric COUNT never changes at runtime, so explicit
                // declarations cost nothing here; a future widget with a
                // genuinely variable-length list (e.g. per-core CPU rows)
                // should use a real Qt ListModel with set()/append(), not a
                // reassigned plain array, if it needs a Repeater.
                Theme.MetricRow {
                    id: utilRow
                    Layout.fillWidth: true
                    // Epic 7: graph row now grows vertically with the
                    // widget instead of leaving the trailing filler Item
                    // (removed below) to eat all the extra resize space.
                    // Floor matches MetricRow's own internal
                    // graphMinimumHeight (3.6 gridUnit) so this row can't
                    // be squeezed thinner than its pre-Epic-7 fixed size.
                    Layout.fillHeight: true
                    Layout.minimumHeight: utilRow.graphMinimumHeight
                    metric: root.metrics[0]
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                    labelColumnWidth: fullRoot.meterLabelColumnWidth
                }
                Theme.MetricRow {
                    Layout.fillWidth: true
                    metric: root.metrics[1]
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                    labelColumnWidth: fullRoot.meterLabelColumnWidth
                }
                Theme.MetricRow {
                    Layout.fillWidth: true
                    metric: root.metrics[2]
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                    labelColumnWidth: fullRoot.meterLabelColumnWidth
                }
                Theme.MetricRow {
                    Layout.fillWidth: true
                    metric: root.metrics[3]
                    goodColor: Plasmoid.configuration.meterGoodColor || "#77ca9b"
                    warnColor: Plasmoid.configuration.meterWarnColor || "#cbc06c"
                    badColor: Plasmoid.configuration.meterBadColor || "#dc4c4c"
                    trackColor: root.meterBackgroundColor
                    labelColor: root.fontColor
                    labelColumnWidth: fullRoot.meterLabelColumnWidth
                }
            }
        }
    }
}
