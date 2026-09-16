import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// The "Poll interval:" FormLayout row, identical in structure across every
// widget -- only the allowed range differs (DISK allows up to 30s since a
// full mount scan is heavier than the other widgets' /proc reads).
RowLayout {
    id: root

    /** Poll interval in whole seconds -- bind from cfg_pollInterval. */
    property double interval

    /** Lower bound in seconds. Same (0.5s) for every widget so far. */
    property double minSeconds: 0.5

    /** Upper bound in seconds. Most widgets use 10s; DISK uses 30s. */
    property double maxSeconds: 10.0

    /** Emitted on user edit; caller writes it back to cfg_pollInterval. */
    signal intervalEdited(double seconds)

    Kirigami.FormData.label: i18n("Poll interval:")

    QQC2.SpinBox {
        id: spinBox

        // KConfigXT entry is a Double in seconds; SpinBox only does
        // integers, so work in tenths-of-a-second internally.
        stepSize: 1
        from: Math.round(root.minSeconds * 10)
        to: Math.round(root.maxSeconds * 10)

        validator: DoubleValidator {
            bottom: spinBox.from
            top: spinBox.to
            decimals: 1
            notation: DoubleValidator.StandardNotation
        }

        textFromValue: (value, locale) => Number(value / 10).toLocaleString(locale, 'f', 1)
        valueFromText: (text, locale) => Math.round(Number.fromLocaleString(locale, text) * 10)

        value: Math.round(root.interval * 10)
        onValueChanged: root.intervalEdited(value / 10)
    }

    QQC2.Label {
        text: i18n("seconds")
    }
}
