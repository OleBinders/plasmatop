import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

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
    property double cfg_tempPkgGoodMax
    property double cfg_tempPkgWarnMax
    property double cfg_tempVramGoodMax
    property double cfg_tempVramWarnMax
    property double cfg_vramGoodMax
    property double cfg_vramWarnMax
    property double cfg_vramTotalGib

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
            label: i18n("Meter/graph background:")
            dialogTitle: i18n("Choose the meter/graph background color")
            // Lets the user dial in transparency in the same picker,
            // not just hue -- covers both BarMeter's bar track and
            // Sparkline's graph background (one shared control, see
            // main.xml's meterBackgroundColor doc comment).
            showAlpha: true
            color: cfg_meterBackgroundColor
            onColorEdited: (newColor) => cfg_meterBackgroundColor = newColor
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Meter thresholds")
        }

        Config.ThresholdPairRow {
            label: i18n("Utilization good/warn at:")
            goodMax: cfg_utilGoodMax
            warnMax: cfg_utilWarnMax
            onGoodMaxEdited: (fraction) => cfg_utilGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_utilWarnMax = fraction
        }

        Config.ThresholdPairRow {
            label: i18n("Package temp good/warn at:")
            goodMax: cfg_tempPkgGoodMax
            warnMax: cfg_tempPkgWarnMax
            onGoodMaxEdited: (fraction) => cfg_tempPkgGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_tempPkgWarnMax = fraction
        }

        Config.ThresholdPairRow {
            label: i18n("VRAM temp good/warn at:")
            goodMax: cfg_tempVramGoodMax
            warnMax: cfg_tempVramWarnMax
            onGoodMaxEdited: (fraction) => cfg_tempVramGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_tempVramWarnMax = fraction
        }

        Config.ThresholdPairRow {
            label: i18n("VRAM used good/warn at:")
            goodMax: cfg_vramGoodMax
            warnMax: cfg_vramWarnMax
            onGoodMaxEdited: (fraction) => cfg_vramGoodMax = fraction
            onWarnMaxEdited: (fraction) => cfg_vramWarnMax = fraction
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("\"Good up to\" and \"warn up to\" are each metric's own percent-of-scale (e.g. utilization's own 0-100%, or each temperature's 0-100°C scale) at which the meter shifts from green to yellow, and from yellow to red.")
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("VRAM capacity")
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Total VRAM:")

            QQC2.SpinBox {
                id: vramTotalSpinBox
                // KConfigXT entry is a Double in GiB; SpinBox only does
                // integers, so work in hundredths-of-a-GiB internally
                // (same pattern as PollIntervalRow's tenths-of-a-second).
                from: 10
                to: 25600

                validator: DoubleValidator {
                    bottom: vramTotalSpinBox.from
                    top: vramTotalSpinBox.to
                    decimals: 2
                    notation: DoubleValidator.StandardNotation
                }

                textFromValue: (value, locale) => Number(value / 100).toLocaleString(locale, 'f', 2)
                valueFromText: (text, locale) => Math.round(Number.fromLocaleString(locale, text) * 100)

                value: Math.round(cfg_vramTotalGib * 100)
                onValueChanged: cfg_vramTotalGib = value / 100
            }

            QQC2.Label {
                text: i18n("GiB")
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("No sysfs source exists for total VRAM capacity on the Xe driver, so this is a manual figure rather than an auto-detected one. Default (11.93 GiB) matches nvtop's own reading for an Arc B580 on this machine — adjust it if this widget is ever used with different GPU hardware.")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Kirigami.FormData.isSection: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Each poll reads a few sysfs files and does a filtered scan of /proc for GPU-active processes. Lower intervals track short bursts more closely but poll more often.")
        }
    }
}
