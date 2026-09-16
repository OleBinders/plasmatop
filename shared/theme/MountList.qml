/*
    MountList.qml — shared/theme

    Single-column list of usage bars for a variable, runtime-unknown mount
    count (`plasmatop-disk`'s driving use case) — the exact same class of
    problem `CoreGrid.qml` already solved for per-core CPU rows: the number
    of surviving mounts is fixed for the plasmoid's lifetime (mounts don't
    typically change while it's running) but unknown at write-time (varies
    by machine, and even run-to-run on the SAME machine as drives get
    plugged/unplugged) — so, per CoreGrid.qml's header, neither MetricRow's
    "N fixed-index declarations" trick nor "reassign a plain array to
    Repeater.model every tick" (the documented Repeater/modelData staleness
    bug, see MetricRow.qml's header) apply here either.

    Built as a NEW component rather than reusing CoreGrid.qml directly: this
    widget's shape is a single column (not a density-driven multi-column
    grid) with LABELS OF UNKNOWN, VARIABLE LENGTH (mount/drive display
    names — "ROOT"/"GAMES"/"LAGRING" on this machine, but arbitrary on
    another), unlike CoreGrid's short fixed-format "C0".."C11" labels that
    a single hardcoded FontMetrics probe string ("C11 100%") can safely
    bound in advance. Contorting CoreGrid to also handle a one-column
    layout AND an unbounded label width would have meant threading a
    "columns: 1, forced" escape hatch through its maxRowsPerColumn logic
    plus replacing its hardcoded probe string with something dynamic
    anyway — at that point it's a different component wearing CoreGrid's
    skin, not a reuse. Confirmed-correct pattern instead (same as
    CoreGrid.qml, see that file's header for the full empirical diagnosis):
    a real `ListModel`, populated ONCE via initMounts(mounts) (one
    `.append()` per mount), with a `Repeater` reading it. Per-tick updates
    go through setMountUsage(index, usedBytes, totalBytes), which calls
    `.setProperty()` on an EXISTING row — the reactive path Repeater
    reliably reacts to.

    Each row is a full-size BarMeter (not CoreGrid's compact cellTrackHeight
    -- this widget's list is short, "likely just 2-4 rows in practice" per
    spec, so there's no density pressure the way a dozen CPU cores have),
    labelled "<LABEL> <percent>%" -- matching plasmatop-mem's established
    percent-only inline-label convention (see plasmatop-mem/main.qml's
    formatMemPercent() comment: a fuller "<LABEL> <percent>% (used/total
    GiB)" label collapsed the BarMeter track to ~0px on that widget's real
    desktop layout; the full used/total detail lives in the owning
    widget's tooltip instead, built from the same raw usedBytes/totalBytes
    this component is fed, kept independently by the owning widget's own
    JS array since that's a plain read, not a Repeater-driven one).

    Same shared right-edge `labelColumnWidth` alignment fix as CoreGrid.qml/
    MetricRow.qml/GPU's meterLabelColumnWidth/MEM's meterLabelColumnWidth,
    but computed INTERNALLY here (once, in initMounts()) from the actual
    label strings this list ends up holding, rather than a hardcoded probe
    string -- there is no fixed worst-case label like GPU's "VRAM 100.0°C"
    to hardcode when labels are arbitrary mount names. Safe to compute only
    once at init: label text itself never changes after initMounts() (only
    the percent alongside it does), and the set of rows is fixed for the
    list's lifetime per the file header above.

    Usage:
        Theme.MountList {
            id: mountList
            Layout.fillWidth: true
            goodMax: root.diskGoodMax
            warnMax: root.diskWarnMax
            goodColor: ...
            warnColor: ...
            badColor: ...
            trackColor: root.meterBackgroundColor
            labelColor: root.fontColor
            Component.onCompleted: initMounts([{label: "ROOT", mountpoint: "/"}, ...])
        }
        // per tick, once per mount:
        mountList.setMountUsage(i, usedBytes, totalBytes)
*/

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: root

    // Forwarded straight through to each row's internal BarMeter, same
    // meaning/defaults as BarMeter.qml's own properties. One shared
    // good/warn/bad pair for every mount row (not one pair per mount --
    // wouldn't scale to a variable-length list, same rationale as
    // CoreGrid's single shared per-core threshold pair).
    property color goodColor: "#77ca9b"
    property color warnColor: "#cbc06c"
    property color badColor: "#dc4c4c"
    property color trackColor: "#404040"
    property color labelColor: "#eeeeee"
    property real goodMax: 0.6
    property real warnMax: 0.85

    property int trackHeight: 14
    property int rowSpacing: Kirigami.Units.smallSpacing / 2

    readonly property int mountCount: mountModel.count

    implicitWidth: column.implicitWidth
    implicitHeight: column.implicitHeight

    // Sized once in initMounts() to the widest "<LABEL> 100%" this list
    // actually holds -- see file header for why this can't be a hardcoded
    // probe string the way CoreGrid/GPU/MEM's fixed-vocabulary labels
    // allow.
    property real labelColumnWidth: -1

    ListModel {
        id: mountModel
    }

    FontMetrics {
        id: mountLabelMetrics
        font.family: "monospace"
        // Mirrors BarMeter.qml's own label font-size formula, Math.max(10,
        // trackHeight - 2), for root.trackHeight (the trackHeight every
        // delegate below actually uses) -- keep in sync if either changes.
        font.pixelSize: Math.max(10, root.trackHeight - 2)
    }

    /*!
        Populates the internal ListModel with one row per entry in \a mounts
        (array of {label, mountpoint} objects, already-derived display
        labels -- see the owning widget's basename-derivation logic).
        Call ONCE, e.g. from the owning widget's Component.onCompleted after
        the first stats tick reports the real mount list -- see file header
        for why this must not be called repeatedly or replaced with a
        reassigned array. Starts every row at 0/1 usedBytes/totalBytes
        (updated by the first real setMountUsage() call moments later).
    */
    function initMounts(mounts) {
        mountModel.clear();
        let widest = 0;
        for (let i = 0; i < mounts.length; i++) {
            const label = mounts[i].label;
            // Role deliberately NOT named "label" -- BarMeter (the
            // delegate's base type below) already has its own "label"
            // property, and a required property re-declared with that
            // same name on the delegate shadows it, the exact same
            // silent-empty-bar bug CoreGrid.qml's initCores() documents in
            // detail for its own "value" role (renamed to "percent"
            // there). Using a non-colliding role name ("mountLabel") here
            // avoids the same trap.
            mountModel.append({
                index: i,
                mountLabel: label,
                mountpoint: mounts[i].mountpoint,
                usedBytes: 0,
                totalBytes: 1
            });
            // Worst case for this row's own label is 100% (3 digits) --
            // widest possible reading, same idea as CoreGrid's "C11 100%"
            // probe string but derived from this list's REAL labels
            // instead of a hardcoded vocabulary.
            const w = mountLabelMetrics.advanceWidth(label + " 100%");
            if (w > widest) {
                widest = w;
            }
        }
        root.labelColumnWidth = widest;
    }

    /*!
        Updates one existing mount row's usage in place. Safe to call every
        poll tick -- this is the ListModel.setProperty() path Repeater
        reliably reacts to (see file header).
    */
    function setMountUsage(index, usedBytes, totalBytes) {
        if (index >= 0 && index < mountModel.count) {
            mountModel.setProperty(index, "usedBytes", usedBytes);
            mountModel.setProperty(index, "totalBytes", totalBytes > 0 ? totalBytes : 1);
        }
    }

    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: root.rowSpacing

        Repeater {
            // A real ListModel, not a reassigned plain JS array -- see
            // file header for why this is the correct choice here (a
            // genuinely variable-length list, same reasoning as
            // CoreGrid.qml).
            model: mountModel

            delegate: BarMeter {
                id: rowDelegate
                required property int index
                required property string mountLabel
                required property real usedBytes
                required property real totalBytes

                Layout.fillWidth: true

                value: rowDelegate.usedBytes
                maxValue: rowDelegate.totalBytes
                label: rowDelegate.mountLabel + " " + Math.round((rowDelegate.usedBytes / rowDelegate.totalBytes) * 100) + "%"
                trackHeight: root.trackHeight
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
