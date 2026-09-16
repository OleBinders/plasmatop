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
    property double cfg_utilGoodMax
    property double cfg_utilWarnMax
    property double cfg_tempGoodMax
    property double cfg_tempWarnMax

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
            // Lets the user dial in transparency in the same picker,
            // not just hue -- covers every BarMeter in this widget
            // (the core grid cells and the package-temp row), one
            // shared control.
            showAlpha: true
            color: cfg_meterBackgroundColor
            onColorEdited: (newColor) => cfg_meterBackgroundColor = newColor
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Meter thresholds")
        }

        Config.ThresholdPairRow {
            label: i18n("Per-core utilization good/warn at:")
            goodMax: cfg_utilGoodMax
            warnMax: cfg_utilWarnMax
            onGoodMaxEdited: (fraction) => cfg_utilGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_utilWarnMax = fraction
        }

        Config.ThresholdPairRow {
            label: i18n("Package temp good/warn at:")
            goodMax: cfg_tempGoodMax
            warnMax: cfg_tempWarnMax
            onGoodMaxEdited: (fraction) => cfg_tempGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_tempWarnMax = fraction
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("\"Good up to\" and \"warn up to\" are each metric's own percent-of-scale (per-core utilization's 0-100%, or package temperature's 0-100°C scale) at which the meter shifts from green to yellow, and from yellow to red. Utilization thresholds apply to all core cells via one shared pair, not per-core.")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Each poll reads /proc/stat, one frequency file per logical core, and one hwmon temperature file -- a few milliseconds of work, cheap even at a low interval.")
        }
    }
}
