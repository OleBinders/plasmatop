import QtQuick
import QtQuick.Layouts

import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

import "config" as Config

KCM.SimpleKCM {
    property double cfg_pollInterval
    property double cfg_backgroundOpacity
    property color cfg_meterGoodColor
    property color cfg_meterWarnColor
    property color cfg_meterBadColor
    property color cfg_fontColor
    property color cfg_frameColor
    property color cfg_meterBackgroundColor

    Kirigami.FormLayout {
        Config.PollIntervalRow {
            interval: cfg_pollInterval
            onIntervalEdited: (seconds) => cfg_pollInterval = seconds
        }

        Config.BackgroundOpacityRow {
            value: cfg_backgroundOpacity
            onValueEdited: (opacity) => cfg_backgroundOpacity = opacity
        }

        // Warning/bad color pickers are deliberately NOT offered here: this
        // widget's goodMax/warnMax are both pinned to 1.0 (see main.qml's
        // throughputGoodMax/throughputWarnMax comment), so
        // ColorScale.colorForFraction() can only ever return goodColor --
        // warn/bad are unreachable dead UI. cfg_meterWarnColor/
        // cfg_meterBadColor properties are kept below (schema unchanged,
        // values round-trip untouched) even though no control edits them.
        Config.ColorPickerRow {
            label: i18n("Good color:")
            dialogTitle: i18n("Choose the \"good\" meter color")
            color: cfg_meterGoodColor
            onColorEdited: (newColor) => cfg_meterGoodColor = newColor
        }

        Config.ColorPickerRow {
            label: i18n("Text color:")
            dialogTitle: i18n("Choose the text color")
            color: cfg_fontColor
            onColorEdited: (newColor) => cfg_fontColor = newColor
        }

        Config.ColorPickerRow {
            label: i18n("Frame color:")
            dialogTitle: i18n("Choose the ASCII frame color")
            color: cfg_frameColor
            onColorEdited: (newColor) => cfg_frameColor = newColor
        }

        Config.ColorPickerRow {
            label: i18n("Graph background:")
            dialogTitle: i18n("Choose the graph background color")
            showAlpha: true
            color: cfg_meterBackgroundColor
            onColorEdited: (newColor) => cfg_meterBackgroundColor = newColor
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Throughput has no fixed 0-100% scale like utilization or temperature, so this widget doesn't expose per-metric good/warn thresholds — the graph auto-scales to recent peak throughput instead, and always renders in the good color above (there's no warn/bad state to reach on a self-scaling axis).")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Each poll re-detects the default-route (primary) network interface and reads its byte counters from /proc/net/dev. Lower intervals track short bursts more closely but poll more often.")
        }
    }
}
