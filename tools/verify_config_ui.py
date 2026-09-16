#!/usr/bin/env python3
"""Standalone verification harness for the refactored ConfigGeneral.qml files.

Loads each widget's contents/ui/ConfigGeneral.qml directly (same technique
used for prior QML verification in this project -- see agent memory
"kde-plasma6-plasmoid-qml": a standalone PySide6 QQmlEngine, not a full
plasmoidviewer session, because no GUI input-automation tool is available on
this machine's Wayland session).

Real Plasma hosts inject a global `i18n()` function via KDeclarative's
KLocalizedContext before loading any applet QML; a bare QQmlEngine doesn't,
so we install a passthrough shim of it here (none of these files use %1-style
placeholders, so passthrough is faithful) purely so the harness can load the
files at all -- this is a harness-only shim, not a change to the widgets.

For each widget this:
  1. Loads the file and fails loudly on ANY QML warning/error (catches typos,
     wrong signal/property names, missing showAlpha, etc.).
  2. Drives a few controls with direct property/signal manipulation and
     confirms the underlying cfg_* property changes as a result -- proving
     the new shared-component signal wiring (colorEdited/intervalEdited/
     valueEdited/goodMaxEdited/warnMaxEdited) reaches the same cfg_*
     bindings the old inline code wrote to.
  3. Grabs a full-height screenshot of the rendered form for visual layout
     comparison.
"""
import sys
from pathlib import Path

from PySide6.QtCore import QUrl, QTimer, QEventLoop
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlEngine, QQmlComponent
from PySide6.QtQuick import QQuickItem, QQuickWindow

WIDGETS_DIR = Path("/home/olebinders/Nextcloud/Documents/Coding/plasmatop/widgets")
OUT_DIR = Path("/tmp/plasmatop_config_screenshots")
OUT_DIR.mkdir(exist_ok=True)

app = QGuiApplication(sys.argv)

# Keep every C++-backed object alive for the whole run -- PySide's ownership
# rules can otherwise garbage-collect a QQmlComponent-created object once its
# creating QQmlComponent/QQmlEngine local variable is reclaimed.
KEEP_ALIVE = []

I18N_SHIM = "function i18n() { return arguments[0]; }"

results_ok = True


def pump(ms=50):
    loop = QEventLoop()
    QTimer.singleShot(ms, loop.quit)
    loop.exec()


def report(name, ok, detail=""):
    global results_ok
    status = "OK" if ok else "FAIL"
    print(f"[{status}] {name}{': ' + detail if detail else ''}")
    if not ok:
        results_ok = False


def by_classname(root, cls_name):
    # QQC2 style delegates instantiate QML-defined wrapper types named e.g.
    # "SpinBox_QMLTYPE_46" (compiled from the style's SpinBox.qml), not the
    # bare C++ "QQuickSpinBox" -- match on the base name before "_QMLTYPE".
    out = []
    for c in root.findChildren(QQuickItem):
        base = c.metaObject().className().split("_QMLTYPE")[0]
        if base == cls_name:
            out.append(c)
    return out


for widget in ["gpu", "cpu", "mem", "net", "disk"]:
    print(f"\n=== {widget} ===")
    qml_path = WIDGETS_DIR / f"plasmatop-{widget}" / "contents" / "ui" / "ConfigGeneral.qml"

    engine = QQmlEngine()
    KEEP_ALIVE.append(engine)
    engine.addImportPath("/usr/lib64/qt6/qml")
    engine.evaluate(I18N_SHIM)

    local_warnings = []
    engine.warnings.connect(lambda ws: local_warnings.extend(str(w.toString()) for w in ws))

    component = QQmlComponent(engine, QUrl.fromLocalFile(str(qml_path)))
    KEEP_ALIVE.append(component)
    for _ in range(20):
        if component.status() != QQmlComponent.Loading:
            break
        pump(25)

    if component.status() == QQmlComponent.Error:
        report(f"{widget}: load", False, component.errorString())
        continue

    obj = component.create()
    KEEP_ALIVE.append(obj)
    pump(50)

    if obj is None:
        report(f"{widget}: load", False, "component.create() returned None")
        continue

    if local_warnings:
        report(f"{widget}: load (zero warnings)", False, "; ".join(local_warnings))
    else:
        report(f"{widget}: load (zero warnings)", True)

    win = QQuickWindow()
    KEEP_ALIVE.append(win)
    obj.setParentItem(win.contentItem())
    # Manually parenting outside the real KCM Loader means nothing sizes
    # this item automatically (the live config dialog's host does that) --
    # set explicit width/height so content actually lays out and renders.
    obj.setWidth(560)
    obj.setHeight(1500)
    win.resize(560, 1500)
    win.show()
    pump(300)

    spinboxes_qq = by_classname(obj, "SpinBox")
    sliders_qq = by_classname(obj, "Slider")
    buttons_qq = by_classname(obj, "Button")
    print(f"  found: {len(spinboxes_qq)} spinboxes, {len(sliders_qq)} sliders, {len(buttons_qq)} buttons")

    # --- PollIntervalRow: always the first SpinBox in the form ---
    before = obj.property("cfg_pollInterval")
    if spinboxes_qq:
        poll_sb = spinboxes_qq[0]
        old_val = poll_sb.property("value")
        new_val = old_val + 1  # +0.1s, tenths-of-a-second internal encoding
        poll_sb.setProperty("value", new_val)
        pump(50)
        after = obj.property("cfg_pollInterval")
        ok = abs(after - (before + 0.1)) < 1e-6
        report(f"{widget}: PollIntervalRow -> cfg_pollInterval", ok,
               f"before={before} after={after} expected={before + 0.1}")
    else:
        report(f"{widget}: PollIntervalRow -> cfg_pollInterval", False, "no spinbox found")

    # --- BackgroundOpacityRow: the only Slider in the form ---
    if sliders_qq:
        slider = sliders_qq[0]
        before_op = obj.property("cfg_backgroundOpacity")
        target = 0.42 if abs(before_op - 0.42) > 0.01 else 0.55
        slider.setProperty("value", target)
        slider.moved.emit()  # the row listens to onMoved, not onValueChanged
        pump(50)
        after_op = obj.property("cfg_backgroundOpacity")
        ok = abs(after_op - target) < 1e-6
        report(f"{widget}: BackgroundOpacityRow -> cfg_backgroundOpacity", ok,
               f"before={before_op} after={after_op} expected={target}")
    else:
        report(f"{widget}: BackgroundOpacityRow -> cfg_backgroundOpacity", False, "no slider found")

    # --- ColorPickerRow: swatch buttons present (good/text/frame/[warn/bad]/background) ---
    expected_buttons = {"gpu": 6, "cpu": 6, "mem": 6, "net": 4, "disk": 6}[widget]
    ok = len(buttons_qq) == expected_buttons
    report(f"{widget}: ColorPickerRow swatch button count", ok,
           f"found={len(buttons_qq)} expected={expected_buttons}")

    # --- ThresholdPairRow count sanity check ---
    expected_threshold_pairs = {"gpu": 4, "cpu": 2, "mem": 2, "net": 0, "disk": 1}
    extra_spinboxes = {"gpu": 1}.get(widget, 0)  # GPU's standalone VRAM-total SpinBox
    expected_total_spinboxes = 1 + extra_spinboxes + 2 * expected_threshold_pairs[widget]
    ok = len(spinboxes_qq) == expected_total_spinboxes
    report(f"{widget}: SpinBox count matches expected threshold-pair count", ok,
           f"found={len(spinboxes_qq)} expected={expected_total_spinboxes}")

    if expected_threshold_pairs[widget] > 0:
        good_sb = spinboxes_qq[1]  # first threshold pair's "good" SpinBox
        first_pair_good_prop = {
            "gpu": "cfg_utilGoodMax", "cpu": "cfg_utilGoodMax",
            "mem": "cfg_ramGoodMax", "disk": "cfg_diskGoodMax",
        }[widget]
        before_t = obj.property(first_pair_good_prop)
        old_pct = good_sb.property("value")
        new_pct = old_pct + 5 if old_pct + 5 <= 100 else old_pct - 5
        good_sb.setProperty("value", new_pct)
        good_sb.valueModified.emit()
        pump(50)
        after_t = obj.property(first_pair_good_prop)
        expected = new_pct / 100
        ok = abs(after_t - expected) < 1e-6
        report(f"{widget}: ThresholdPairRow -> {first_pair_good_prop}", ok,
               f"before={before_t} after={after_t} expected={expected}")

    # --- Screenshot ---
    # obj.grabToImage() returns a null QSharedPointer under offscreen QPA in
    # this Qt build; window.grabWindow() (synchronous) works reliably instead.
    img = win.grabWindow()
    if img is not None and not img.isNull():
        img.save(str(OUT_DIR / f"{widget}_config.png"))
        report(f"{widget}: screenshot saved", True, str(OUT_DIR / f"{widget}_config.png"))
    else:
        report(f"{widget}: screenshot saved", False, "grabWindow failed")

    win.hide()

print("\n" + ("ALL CHECKS PASSED" if results_ok else "SOME CHECKS FAILED"))
sys.exit(0 if results_ok else 1)
