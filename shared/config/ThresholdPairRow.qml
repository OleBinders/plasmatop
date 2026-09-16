import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// A single FormLayout row holding a "good up to" / "warn up to" percent
// SpinBox pair for one metric's severity bands. Widgets vary in how many of
// these they need (GPU has four, DISK has one, NET has none), but each pair
// itself was copy-pasted byte-for-byte -- this is that pair, extracted.
//
// Values are fractions (0.0-1.0), matching the cfg_*GoodMax/WarnMax
// KConfigXT entries; the SpinBoxes display/edit them as whole percent.
RowLayout {
    id: root

    /** Text shown in the FormLayout's left-hand label column. */
    property string label

    /** Current "good up to" fraction (0.0-1.0) -- bind from cfg_*GoodMax. */
    property double goodMax

    /** Current "warn up to" fraction (0.0-1.0) -- bind from cfg_*WarnMax. */
    property double warnMax

    /** Emitted on user edit; caller writes the fraction back to cfg_*GoodMax. */
    signal goodMaxEdited(double fraction)

    /** Emitted on user edit; caller writes the fraction back to cfg_*WarnMax. */
    signal warnMaxEdited(double fraction)

    Kirigami.FormData.label: root.label

    QQC2.SpinBox {
        id: goodSpinBox
        from: 0; to: 100; stepSize: 1
        value: Math.round(root.goodMax * 100)
        onValueModified: root.goodMaxEdited(value / 100)
        textFromValue: (value, locale) => value + "%"
        valueFromText: (text, locale) => parseInt(text)
    }
    QQC2.Label { text: i18n("good up to") }
    QQC2.SpinBox {
        id: warnSpinBox
        from: 0; to: 100; stepSize: 1
        value: Math.round(root.warnMax * 100)
        onValueModified: root.warnMaxEdited(value / 100)
        textFromValue: (value, locale) => value + "%"
        valueFromText: (text, locale) => parseInt(text)
    }
    QQC2.Label { text: i18n("warn up to") }
}
