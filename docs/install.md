# Installing plasmatop

Five separate Plasma 6 widgets, installed independently: `plasmatop-gpu`,
`plasmatop-cpu`, `plasmatop-mem`, `plasmatop-net`, `plasmatop-disk`. Install
whichever ones you want — there's no dependency between them at runtime.

## Prerequisites

- **Plasma 6.0+** with `kpackagetool6` available (ships with Plasma 6).
- That's it. Each widget's data comes from a bundled shell script
  (`contents/scripts/*.sh`) that reads `/proc` and `/sys` directly and shells
  out only to standard coreutils/util-linux/iproute2 tools that are present
  on any normal Linux install (`awk`, `sed`, `cut`, `sort`, `df`, `ip`,
  `stat`, etc.) — nothing needs to be installed separately. This was checked
  against the actual scripts, not assumed: none of them call out to
  `sensors`, `nvtop`, or `intel_gpu_top`, even though those tools exist on
  the reference machine and are mentioned in code comments as *research*
  references (the GPU widget's data-sourcing approach was derived by reading
  `nvtop`'s own source, and its cross-checked against `sensors`/`nvtop`
  output during testing) — they are not runtime dependencies.

If you're setting up `plasmoidviewer` for local development/preview
(optional, not needed just to use the widgets), that comes from the
`plasma-sdk` package, e.g. `sudo dnf install -y plasma-sdk` on Fedora.

## Repository layout you need to keep intact

Each widget package symlinks in the shared theme library:

```
widgets/plasmatop-gpu/contents/ui/theme -> ../../../../shared/theme
```

(same relative symlink in each of the other four widgets). That relative
path walks up from `contents/ui/` to the repo root and back down into
`shared/theme/`, so **`widgets/` and `shared/` must stay siblings**, at the
same relative depth, for the symlink to resolve. Don't copy a single
`widgets/plasmatop-<name>/` directory off somewhere on its own — clone or
copy the whole repo (or at least `widgets/` and `shared/` together) before
installing.

## Install a widget

From the repo root:

```
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-gpu
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-cpu
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-mem
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-net
kpackagetool6 -t Plasma/Applet -i widgets/plasmatop-disk
```

Install only the ones you want; each is a separate plasmoid package
(`com.olebinders.plasmatop.<name>` as its plugin ID) with no cross-install
requirement.

## Updating after a code change

If you're tracking the repo and pull in changes, re-sync the installed
copy with `-u` instead of `-i`:

```
kpackagetool6 -t Plasma/Applet -u widgets/plasmatop-gpu
```

Existing instances on your panel/desktop pick up the update after a
`plasmashell --replace` (or logout/login); a bare `-u` alone doesn't always
force already-placed widgets to reload.

## Adding a widget to your panel or desktop

Standard Plasma "Add Widgets" flow:

1. Right-click the panel (or desktop) → **Add Widgets…**
2. Search for "plasmatop" — the installed widget(s) show up by name
   (`plasmatop GPU`, `plasmatop CPU`, `plasmatop Memory`, `plasmatop NET`,
   `plasmatop Disk`).
3. Drag it onto the panel, or double-click/drag it onto the desktop.

Each widget has a compact (panel) view and a full (desktop/expanded) view —
see `docs/customization.md` for what differs between the two per widget.

## Uninstalling

```
kpackagetool6 -t Plasma/Applet -r com.olebinders.plasmatop.gpu
```

(substitute the plugin ID for the widget you want to remove — `.cpu`,
`.mem`, `.net`, `.disk`).
