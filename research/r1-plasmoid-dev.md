# R1 — Plasma 6 Plasmoid Development Spike

Researched: 2026-09-13, against this machine (Fedora 44, Plasma 6.7.5, Qt
6.11.2). Verified live wherever possible (`rpm`/`dnf`/`find` against
installed files, not just docs) plus KDE's current develop.kde.org docs.

## 1. Package layout (Plasma 6)

Minimal working plasmoid:

```
org.example.mywidget/
├── metadata.json
└── contents/
    ├── ui/
    │   └── main.qml          # entry point — always this path now
    └── config/                # optional, only if the widget has settings
        ├── main.xml           # KConfigXT schema
        └── config.qml         # ConfigModel / ConfigCategory list
```

Confirmed on this machine by inspecting real installed plasmoids (see §6),
plus KDE's own setup doc.

`metadata.json` minimum required fields (Plasma 6):

```json
{
    "KPlugin": {
        "Id": "org.example.mywidget",
        "Name": "My Widget",
        "Description": "...",
        "Icon": "utilities-system-monitor",
        "Category": "System Information",
        "Version": "1.0"
    },
    "KPackageStructure": "Plasma/Applet",
    "X-Plasma-API-Minimum-Version": "6.0"
}
```

- `KPackageStructure: "Plasma/Applet"` replaces the old `ServiceTypes:
  [Plasma/Applet]` line from `.desktop`-era metadata.
- `X-Plasma-API-Minimum-Version: "6.0"` is **mandatory** — without it Plasma
  assumes Plasma-5-only and won't offer the widget in the Add Widgets UI.
- `X-Plasma-MainScript` and `X-Plasma-API` (`declarativeappletscript`) are
  no longer required — `contents/ui/main.qml` is now a hardcoded entry
  point. (The locally-installed `org.kde.olib.thermalmonitor` still sets
  them for backward-compat but they're inert on 6.x.)
- Old `.desktop` metadata can be converted with the `desktoptojson` utility
  if ever porting a Plasma 5 widget.

Install location for per-user plasmoids: `~/.local/share/plasma/plasmoids/<Id>/`
— confirmed live; this machine already has three installed there
(`luisbocanegra.panel.colorizer`, `org.kde.olib.thermalmonitor`,
`plasmusic-toolbar`), each following exactly this layout. System-wide ones
live in `/usr/share/plasma/plasmoids/<Id>/` (e.g. the built-in
`org.kde.plasma.systemmonitor.*` family, also inspected directly).

## 2. QML APIs for Plasma 6.7

Confirmed present under `/usr/lib64/qt6/qml/org/kde/` on this machine:

| Module | Use | Notes |
|---|---|---|
| `org.kde.plasma.plasmoid` | `PlasmoidItem` (root element), `Plasmoid` attached object | **Root QML object must now be `PlasmoidItem`** (or `ContainmentItem`), not a bare `Item`. This is new/enforced in Plasma 6. |
| `org.kde.plasma.core` | `PlasmaCore.Types`, theming enums | Import is now **unversioned** (`import org.kde.plasma.core`, no `2.0`) |
| `org.kde.plasma.components` | Buttons, labels, etc. (PlasmaComponents 3) | Unversioned import; internally still "3.0" |
| `org.kde.kirigami` | `Kirigami.Theme`, `Kirigami.Icon`, `Kirigami.Heading`, `Kirigami.FormLayout` | Absorbed several things that used to live in PlasmaCore/PlasmaExtras |
| `org.kde.ksvg` | `KSvg.Svg`, `KSvg.SvgItem`, `KSvg.FrameSvgItem` | New home for SVG theming, split out of PlasmaCore |
| `org.kde.plasma.plasma5support` | `Plasma5Support.DataSource` | Compat/porting shim (see §3) |
| `org.kde.ksysguard.sensors` | `Sensors.Sensor` | Native sensor-framework bridge, used by built-in system-monitor widgets and by the locally-installed thermalmonitor |
| `org.kde.quickcharts` | Line charts / sparkline-style rendering | Used by thermalmonitor for its history graph — good candidate for R3's sparkline work |
| `org.kde.kcmutils` | `SimpleKCM`, `AbstractKCM`, `ScrollViewKCM` | Config-page containers, Plasma 6 preferred |

**Deprecated / changed from Plasma 5** (this is the part that will bite
someone following an old tutorial):

- **Root element**: Plasma 5 plasmoids often had `Item { ... }` as root.
  Plasma 6 **requires** `PlasmoidItem`.
- **Versioned imports gone**: `import org.kde.plasma.core 2.0` /
  `import org.kde.plasma.plasmoid 2.0` → drop the version number entirely.
- `PlasmaCore.DataSource` → moved out of core into
  `org.kde.plasma.plasma5support` as `Plasma5Support.DataSource`. Not a
  drop-in — different import, same API surface.
- `PlasmaCore.SvgItem` / `FrameSvgItem` / `Svg` → moved to `org.kde.ksvg`
  as `KSvg.*`.
- `PlasmaCore.ColorScope` → `Kirigami.Theme`.
- `PlasmaCore.IconItem` → `Kirigami.Icon`.
- `PlasmaExtras.Heading` → `Kirigami.Heading`. `PlasmaComponents 2.0` /
  `PlasmaExtras` from Plasma 5 are **removed outright**, not just
  deprecated — old tutorials using `import org.kde.plasma.extras 2.0` will
  fail to even parse.
- **Actions**: old imperative pattern (magic functions like
  `plasmoid.action_myAction`) replaced by declarative `PlasmaCore.Action`
  objects added to a `contextualActions` array.
- **`nativeInterface` indirection removed**: C++ plugin properties are now
  reachable directly off the `Plasmoid` attached property, no more
  `plasmoid.nativeInterface.foo`.
- **Config UI root**: must now use a KCM container
  (`org.kde.kcmutils` — `SimpleKCM` etc.) rather than a bare `Item`/`Column`,
  for config pages that want native KCM chrome/spacing.
- **Dataengines are gone as a general extension mechanism** in KF6 — only
  the ones ported into `plasma5support` still work, and that library is
  explicitly a *porting aid*, not a long-term API (see next section).

Any tutorial written for Plasma 5 (pre-2024, most of what's indexed on
techbase.kde.org) will use at least 3-4 of the deprecated forms above.
Treat them as structural reference only, verify every import against
what's actually on disk in `/usr/lib64/qt6/qml/org/kde/`.

## 3. Data sourcing pattern (poll a file / run a shell command on a timer)

Two viable options in Plasma 6.7, both confirmed present on this machine.
Neither is a clean "one obvious answer" — pick per-widget:

**Option A — `Plasma5Support.DataSource` (executable engine)**
```qml
import org.kde.plasma.plasma5support as Plasma5Support

Plasma5Support.DataSource {
    id: exe
    engine: "executable"
    connectedSources: []
    onNewData: (sourceName, data) => {
        // data.stdout, data.stderr, data.exit code
        disconnectSource(sourceName)
    }
    function runCmd(cmd) {
        connectSource(cmd)
    }
}
Timer {
    interval: 1000; running: true; repeat: true
    onTriggered: exe.runCmd("intel_gpu_top -J -s 500")
}
```
This module still ships and works on this machine
(`/usr/lib64/qt6/qml/org/kde/plasma/plasma5support/` exists). It's the
straightforward "run a shell command periodically, get stdout back"
pattern most existing Plasma-6-ported system-monitor widgets use (e.g.
Zren's `plasma-applet-commandoutput`, ported to Plasma 6 in 2024). **But**
KDE's own porting docs describe `plasma5support` explicitly as a
**migration/compat shim** with no committed long-term future — "consider
porting away from it." For a project starting fresh in Sprint 0, treat it
as acceptable-but-not-ideal.

**Option B — plain QML `Timer` + `Plasma5Support.DataSource`/`FileIO`-style
file read**, or a small helper process launched once and read via stdout
streaming, is the more "native QML" pattern KDE points toward, but there's
no polished first-party QML file-reading API to replace it with yet for
simple sysfs/proc polling — C++ helper plugins or `plasma5support` remain
the practical options for shell-command/file polling in pure-QML plasmoids
today.

**Option C — `org.kde.ksysguard.sensors`** (`Sensors.Sensor { sensorId:
"cpu/all/usage" }`) is what the *built-in* `org.kde.plasma.systemmonitor.*`
widgets and the locally-installed thermalmonitor plasmoid actually use for
CPU/mem/temperature-class data — it's backed by the native KSysGuard
sensor daemon (ksystemstats), supports `updateRateLimit`, and is the
"most Plasma 6 native" option. **It only exposes sensors the ksystemstats
daemon knows about.** It has no Intel Arc/Xe GPU utilization sensor today
(GPU sensors framework coverage is patchy/vendor-dependent) — worth a
`ksystemstats` sensor listing check in R2, but plan for GPU data via
Option A (shelling to `intel_gpu_top`/`gputop`/`nvtop`) regardless, since
the built-in Intel GPU tooling on this machine has its own gotcha (below).

**Recommendation for this project:** `Plasma5Support.DataSource` running
short-lived CLI invocations on a QML `Timer`, for all five widgets, for
consistency — even though CPU/mem *could* use `ksysguard.sensors`, GPU
can't yet reliably, and using one pattern across all five widgets is
simpler than mixing two. Revisit if `plasma5support` gets pulled in a
future Plasma release (no announced timeline as of this writing).

**Gotcha found for GPU specifically** (flagging for R2, found here while
testing): `intel_gpu_top` is installed on this machine but **refuses to
run** — `Detected Xe device which is not supported by intel_gpu_top.
Please use 'gputop' tool instead.` `gputop` (from `igt-gpu-tools`) is also
installed but has **no JSON output mode** (`-J` is not a valid flag,
`--help` shows only `-d`/`-n`/`-h`) — its output will need to be
text-parsed, not JSON-parsed. This directly affects the DataSource
`onNewData` parsing code for `plasmatop-gpu`; R2 should confirm current
`gputop` plain-text output format and/or check `nvtop`'s
`--freq`/piped-output-friendliness or sysfs (`/sys/class/drm/card*/`,
`/sys/kernel/debug/dri/`) as an alternative to shelling out at all.

## 4. Config system

Standard Plasma 6 KConfigXT pattern, confirmed against the real
`org.kde.olib.thermalmonitor` plasmoid installed on this machine
(`~/.local/share/plasma/plasmoids/org.kde.olib.thermalmonitor/contents/config/`):

```
contents/config/main.xml      # KConfigXT schema: groups, entries, types, defaults
contents/config/config.qml    # ConfigModel { ConfigCategory { name, icon, source } }
contents/ui/configGeneral.qml # (or ui/config/*.qml) — actual form UI per category
```

`main.xml` example (trimmed from the real local file):
```xml
<kcfg xmlns="http://www.kde.org/standards/kcfg/1.0">
    <kcfgfile name=""/>
    <group name="Behavior">
        <entry name="updateInterval" type="Double">
            <default>1.0</default>
        </entry>
    </group>
</kcfg>
```

`config.qml`:
```qml
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Behavior")
        icon: "preferences-other"
        source: "config/ConfigBehavior.qml"
    }
}
```

Form UI (`ConfigBehavior.qml` etc.) uses `Kirigami.FormLayout` with
`property alias cfg_<name>: control.<property>` bindings — the `cfg_`
prefix convention auto-wires to the matching `main.xml` entry name. Values
are read at runtime from `main.qml`/any QML via
`Plasmoid.configuration.<name>` (thermalmonitor uses exactly this, e.g.
`Plasmoid.configuration.updateInterval`, `Plasmoid.configuration.sensors`
storing a JSON-encoded string for a list-typed setting since KConfigXT has
no native array/object type — worth reusing that same
stringify-JSON-in-a-String-entry trick for e.g. "which stats visible").
Config changes are live — `Plasmoid.configuration.xChanged` signals fire,
thermalmonitor hooks these via `Connections { target: Plasmoid.configuration }`.

For `plasmatop-*`: poll interval → `Double`/`Int` entry with a `SpinBox`;
"which stats shown" → either separate `Bool` entries per stat, or one
JSON-string entry like thermalmonitor's `sensors` list, depending on how
dynamic the stat list needs to be.

## 5. Dev workflow on this machine

Checked live via `dnf`/`rpm`/`which` (read-only, nothing installed):

- **`plasma-sdk` is available but not installed.** `dnf search`/`dnf info`
  confirms `plasma-sdk-6.7.5-1.fc44` in the `updates` repo (and
  `6.6.4-1.fc44` in base `fedora`), summary "Development tools for Plasma
  6". `dnf provides '*/plasmoidviewer'` confirms this package is exactly
  what ships `/usr/bin/plasmoidviewer`. **Install command (not yet run,
  needs sign-off):** `sudo dnf install plasma-sdk`.
- **`kpackagetool6` is already installed** (`/usr/bin/kpackagetool6`,
  reports "kpackagetool6 2.0") — no separate package needed, it's pulled
  in by the base Plasma install.
- `dnf search plasmoidviewer` / `dnf search kpackagetool` directly return
  no package hits (they're binaries inside `plasma-sdk` and
  `plasma-workspace`/`kf6-kpackage` respectively, not separately named
  packages — confirmed via `dnf provides`).

Install/upgrade/remove commands (`kpackagetool6 --help` output, confirmed
live):
```
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-gpu   # first install
kpackagetool6 -t Plasma/Applet -u widgets/plasmatop-gpu   # reinstall after changes
kpackagetool6 -t Plasma/Applet -r org.example.plasmatop-gpu  # remove, by Id
kpackagetool6 -l                                          # list installed packages
```
`-u`/upgrade is what a `tools/reload-widget.sh` script should call on each
iteration — it replaces the installed copy in `~/.local/share/plasma/plasmoids/`.
After upgrading an *already-added* widget instance, Plasma typically needs
either the specific widget removed/re-added to the panel/desktop, or
`plasmashell --replace` (kills and restarts the whole shell — disruptive
but reliable), to pick up QML changes; `plasmoidviewer` (once `plasma-sdk`
is installed) avoids this entirely by running the widget standalone
outside a live shell session:
```
plasmoidviewer -a widgets/plasmatop-gpu    # live-preview without touching the real panel
```
That's the recommended fast-iteration loop once `plasma-sdk` is installed
— `kpackagetool6 -u` + full shell restart is the fallback for final
on-panel acceptance testing (which AGENTS.md requires before calling a
widget "done" anyway).

**Recommendation:** get product owner sign-off to `sudo dnf install
plasma-sdk` as part of the "Dev environment setup" backlog item — it's a
small (910 KB download / 3.4 MiB installed), official Fedora-repo package,
low risk.

## 6. Real-world Plasma 6 plasmoid references

1. **`org.kde.olib.thermalmonitor`** — already installed locally at
   `~/.local/share/plasma/plasmoids/org.kde.olib.thermalmonitor/`
   (upstream: https://invent.kde.org/olib/thermalmonitor). Directly
   inspected for this spike. Excellent structural reference: clean
   `PlasmoidItem` root, full KConfigXT config system with multiple
   categories, `org.kde.ksysguard.sensors` + `org.kde.quickcharts` for
   live sensor history/sparklines, threshold-coloring config
   (warning/meltdown thresholds) — very close to what
   `plasmatop-cpu`/`plasmatop-gpu` need for color-coded thresholds.
2. **Zren/plasma-applet-commandoutput** —
   https://github.com/Zren/plasma-applet-commandoutput — simple widget
   that runs a shell command every N seconds and displays stdout, ported
   to Plasma 6 in 2024. Cleanest available reference for the
   `Plasma5Support.DataSource` executable-engine timer pattern chosen
   above.
3. **luisbocanegra/plasma-intel-gpu-monitor** —
   https://github.com/luisbocanegra/plasma-intel-gpu-monitor — Intel GPU
   widget for Plasma 6 (same author as the `panel.colorizer` plasmoid
   already installed locally). Shells out to `intel_gpu_top` and needs
   `sudo setcap cap_perfmon=+ep /usr/bin/intel_gpu_top` for permissions
   (relevant to AGENTS.md's "no interactive sudo" constraint — flag for
   R2). Targets legacy i915 only as far as documented, not confirmed to
   handle Xe/Arc — don't assume it works unmodified on the B580, but its
   plasmoid structure and permission-handling approach are worth copying.
4. **LaBatata101/kde-system-monitor** —
   https://github.com/LaBatata101/kde-system-monitor — panel-friendly
   multi-metric (CPU/GPU/mem/net/storage/temp) monitor for Plasma 6,
   closest single-repo analog to what plasmatop is doing across five
   widgets, worth a structural skim for panel-compact-representation
   layout ideas.

## Gotchas summary (Plasma-5-tutorial traps)

- Root QML element must be `PlasmoidItem`, not `Item`.
- Drop version numbers from `org.kde.plasma.*` imports.
- `PlasmaCore.DataSource` → `Plasma5Support.DataSource` (different import,
  and the whole module is a deprecated-but-present porting shim).
- `PlasmaCore.Svg*` → `KSvg.*`; `PlasmaCore.IconItem` → `Kirigami.Icon`;
  `PlasmaExtras.*` → mostly `Kirigami.*` or removed.
- `metadata.desktop` is dead; `metadata.json` with
  `"X-Plasma-API-Minimum-Version": "6.0"` and
  `"KPackageStructure": "Plasma/Applet"` is required.
- Config page root should be a `org.kde.kcmutils` KCM container, not a
  bare Item, for correct native styling/spacing.
- `intel_gpu_top` does not work on this machine's Xe/i915 driver stack for
  the Arc B580 — it explicitly errors and tells you to use `gputop`
  instead, and `gputop` has no JSON output mode. Budget R2 time for
  output-format parsing, not just tool selection.
