import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs

import org.kde.kirigami as Kirigami

// A single FormLayout row: a button showing the current color as a swatch,
// which opens a ColorDialog on click. Every widget's ConfigGeneral.qml used
// to hand-roll this same Button+Rectangle+ColorDialog block once per color
// (5-6 near-identical copies per widget) -- this is that block, extracted.
//
// Two colors in this project's widgets (meter/graph backgrounds) also need
// an alpha channel so users can dial in transparency, not just hue; the
// rest don't. `showAlpha` covers both cases from one component rather than
// forking into two near-duplicate components.
RowLayout {
    id: root

    /** Text shown in the FormLayout's left-hand label column. */
    property string label

    /** Window title of the color dialog this row opens. */
    property string dialogTitle

    /** Current color value -- bind this from the widget's cfg_* property. */
    property color color

    /** Whether the dialog exposes an alpha slider (meter/graph backgrounds only). */
    property bool showAlpha: false

    /** Emitted when the user accepts a new color; caller writes it back to cfg_*. */
    signal colorEdited(color newColor)

    Kirigami.FormData.label: root.label

    QQC2.Button {
        id: swatchButton
        implicitWidth: Kirigami.Units.gridUnit * 4
        implicitHeight: Kirigami.Units.gridUnit * 1.5
        background: Rectangle {
            color: root.color
            border.color: Kirigami.Theme.textColor
            border.width: 1
        }
        onClicked: colorDialog.open()
    }

    ColorDialog {
        id: colorDialog
        title: root.dialogTitle
        options: root.showAlpha ? ColorDialog.ShowAlphaChannel : 0
        selectedColor: root.color
        onAccepted: root.colorEdited(selectedColor)
    }
}
