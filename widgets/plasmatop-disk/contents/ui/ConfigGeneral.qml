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
    property double cfg_diskGoodMax
    property double cfg_diskWarnMax

    Kirigami.FormLayout {
        Config.PollIntervalRow {
            interval: cfg_pollInterval
            // A full mount scan is heavier than the other widgets' /proc
            // reads, so this widget's schema allows longer intervals
            // (up to 30s vs. the usual 10s).
            maxSeconds: 30.0
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
            label: i18n("Disk usage good/warn at:")
            goodMax: cfg_diskGoodMax
            warnMax: cfg_diskWarnMax
            onGoodMaxEdited: (fraction) => cfg_diskGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_diskWarnMax = fraction
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("\"Good up to\" and \"warn up to\" are each mount's own used-percent at which its bar shifts from green to yellow, and from yellow to red. One shared pair applies to every drive shown, since the list of drives varies by machine. Defaults sit higher than this project's CPU/RAM widgets (80%/90%) since disk space is normal to run fairly full — only the last stretch before actually running out is worth flagging.")
        }
    }
}
