/*
    ColorScale.qml — shared/theme

    Single source of truth for "what does yellow mean" across every
    plasmatop widget. Maps a raw value/max pair, or an already-normalized
    0..1 fraction, to a green -> yellow -> red color using two configurable
    thresholds (goodMax, warnMax), per ARCHITECTURE.md's shared theme spec.

    Usage:
        ColorScale {
            id: colorScale
            // goodMax: 0.5, warnMax: 0.8 (defaults, override per-widget if needed)
        }
        someRect.color: colorScale.colorForValue(currentTemp, criticalTemp)
*/

import QtQuick

QtObject {
    id: root

    // Fraction (0..1) at/below which a value reads as "good" (green).
    property real goodMax: 0.5
    // Fraction (0..1) at/below which a value reads as "warning" (yellow).
    // Above this it reads as "bad" (red). Must be > goodMax.
    property real warnMax: 0.8

    // btop's actual default-theme meter gradient (cpu_start/cpu_mid/cpu_end),
    // not a generic Material palette -- picked deliberately so plasmatop
    // reads as "the terminal tool", not "a Plasma widget with colors".
    property color goodColor: "#77ca9b"
    property color warnColor: "#cbc06c"
    property color badColor: "#dc4c4c"

    function _clamp01(x) {
        return Math.max(0, Math.min(1, x));
    }

    function _lerp(a, b, t) {
        return Qt.rgba(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            a.a + (b.a - a.a) * t
        );
    }

    /*!
        Returns a color for \a value against \a max (e.g. colorForValue(51, 100)).
        \a max <= 0 (no data yet) returns goodColor rather than dividing by zero.
    */
    function colorForValue(value, max) {
        if (!max || max <= 0) {
            return goodColor;
        }
        return colorForFraction(value / max);
    }

    /*!
        Returns a color for an already-normalized 0..1 \a fraction, piecewise-
        interpolated across the goodMax/warnMax thresholds: solid goodColor up
        to goodMax, smooth goodColor->warnColor between goodMax and warnMax,
        smooth warnColor->badColor between warnMax and 1.0.
    */
    function colorForFraction(fraction) {
        var f = _clamp01(fraction);

        if (f <= goodMax) {
            return goodColor;
        }
        if (f <= warnMax) {
            var t1 = (warnMax > goodMax) ? (f - goodMax) / (warnMax - goodMax) : 1;
            return _lerp(goodColor, warnColor, _clamp01(t1));
        }
        var t2 = (warnMax < 1) ? (f - warnMax) / (1 - warnMax) : 1;
        return _lerp(warnColor, badColor, _clamp01(t2));
    }
}
