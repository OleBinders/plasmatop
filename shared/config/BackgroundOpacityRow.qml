import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// The "Background opacity:" FormLayout row, byte-for-byte identical across
// every widget: a 0-1 slider plus a live percentage readout.
RowLayout {
    id: root

    /** Current opacity (0.0-1.0) -- bind from cfg_backgroundOpacity. */
    property double value

    /** Emitted while dragging; caller writes it back to cfg_backgroundOpacity. */
    signal valueEdited(double opacity)

    Kirigami.FormData.label: i18n("Background opacity:")

    QQC2.Slider {
        id: slider
        from: 0.0
        to: 1.0
        stepSize: 0.01
        value: root.value
        onMoved: root.valueEdited(value)
    }

    QQC2.Label {
        // Fixed-ish width so the row doesn't jump around as the
        // percentage's digit count changes while dragging.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 3
        text: Math.round(slider.value * 100) + "%"
    }
}
