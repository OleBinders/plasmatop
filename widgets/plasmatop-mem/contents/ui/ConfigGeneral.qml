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
    property double cfg_ramGoodMax
    property double cfg_ramWarnMax
    property double cfg_swapGoodMax
    property double cfg_swapWarnMax

    Kirigami.FormLayout {
        Config.PollIntervalRow {
            interval: cfg_pollInterval
            onIntervalEdited: (seconds) => cfg_pollInterval = seconds
        }

        Config.BackgroundOpacityRow {
            value: cfg_backgroundOpacity
            onValueEdited: (opacity) => cfg_backgroundOpacity = opacity
        }

        Config.ColorPickerRow {
            label: i18n("Good color:")
            dialogTitle: i18n("Choose the \"good\" meter color")
            color: cfg_meterGoodColor
            onColorEdited: (newColor) => cfg_meterGoodColor = newColor
        }

        Config.ColorPickerRow {
            label: i18n("Warning color:")
            dialogTitle: i18n("Choose the \"warning\" meter color")
            color: cfg_meterWarnColor
            onColorEdited: (newColor) => cfg_meterWarnColor = newColor
        }

        Config.ColorPickerRow {
            label: i18n("Bad color:")
            dialogTitle: i18n("Choose the \"bad\" meter color")
            color: cfg_meterBadColor
            onColorEdited: (newColor) => cfg_meterBadColor = newColor
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
            label: i18n("Meter background:")
            dialogTitle: i18n("Choose the meter background color")
            showAlpha: true
            color: cfg_meterBackgroundColor
            onColorEdited: (newColor) => cfg_meterBackgroundColor = newColor
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Meter thresholds")
        }

        Config.ThresholdPairRow {
            label: i18n("RAM good/warn at:")
            goodMax: cfg_ramGoodMax
            warnMax: cfg_ramWarnMax
            onGoodMaxEdited: (fraction) => cfg_ramGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_ramWarnMax = fraction
        }

        Config.ThresholdPairRow {
            label: i18n("Swap good/warn at:")
            goodMax: cfg_swapGoodMax
            warnMax: cfg_swapWarnMax
            onGoodMaxEdited: (fraction) => cfg_swapGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_swapWarnMax = fraction
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("\"Good up to\" and \"warn up to\" are each metric's own used-percent at which the meter shifts from green to yellow, and from yellow to red. Swap defaults lower than RAM's since any nonzero swap usage is generally worse news than the same percentage of RAM in use.")
        }
    }
}
