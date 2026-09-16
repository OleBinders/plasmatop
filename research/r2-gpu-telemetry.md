# R2 — Intel Arc B580 GPU telemetry spike

Machine: Fedora Linux 44, Plasma 6.7.5, kernel driver for GPU `03:00.0`
(Intel Battlemage G21 / Arc B580). All commands below were run live on this
machine as the normal user `olebinders` (no sudo), 2026-09-13.

## 1. Kernel driver bound

```
$ lspci -k -s 03:00.0
03:00.0 VGA compatible controller: Intel Corporation Battlemage G21 [Arc B580]
	Subsystem: ASRock Incorporation Device 6021
	Kernel driver in use: xe
	Kernel modules: xe
```

`ls /sys/class/drm/` shows one GPU card: `card1` (plus `card1-DP-*` /
`card1-HDMI-*` connector nodes), symlinked to
`/sys/bus/pci/drivers/xe`. `lsmod | grep xe` confirms the `xe` module is
loaded (66 users). **This machine uses the `xe` driver, not legacy `i915`.**
This matters a lot for tooling (see §4) — Battlemage is Xe2, and Intel's
newer discrete GPUs use `xe` by default on recent kernels/Mesa.

## 2. sysfs paths (verified to exist on this machine)

Base: `/sys/class/drm/card1/device/`

| Metric | Path | Sample value |
|---|---|---|
| GPU core freq (actual) | `tile0/gt0/freq0/act_freq` | `1350` (MHz) |
| GPU core freq (requested) | `tile0/gt0/freq0/cur_freq` | `1317` |
| GPU freq min/max/limits | `tile0/gt0/freq0/{min_freq,max_freq,rp0_freq,rpe_freq,rpn_freq}` | max=2850, rp0=2850 (boost ceiling) |
| Media/video engine freq | `tile0/gt1/freq0/*` (same fields, separate GT for media) | |
| Throttle reasons | `tile0/gt0/freq0/throttle/{status,reason_pl1,reason_pl2,reason_pl4,reason_thermal,reason_prochot,...}` | all `0` currently |
| GT idle state | `tile0/gt0/gtidle/idle_status`, `idle_residency_ms` | `gt-c0`, counter in ms — **see caveat below, not a reliable busy% proxy** |
| Package temp | `hwmon/hwmon3/temp2_input` (label `pkg`) | `51000` (m°C = 51.0°C) |
| VRAM temp | `hwmon/hwmon3/temp3_input` (label `vram`) | `54000` |
| Memory controller / PCIe temps | `temp4_input` (`mctrl`), `temp5_input` (`pcie`) | 52.0°C, 56.0°C |
| Per-VRAM-channel temps | `temp6_input`..`temp17_input` (labels `vram_ch_0`..`vram_ch_11`) | present, 12 channels |
| Power cap (sustained) | `hwmon/hwmon3/power1_cap` | `200000000` µW = 200 W |
| Power cap (critical/shutdown) | `hwmon/hwmon3/power1_crit` | `400000000` µW = 400 W |
| **Instantaneous power draw** | **not directly exposed** — no `power1_input`/`power1_average` file | — |
| Energy counter (for power calc) | `hwmon/hwmon3/energy1_input` (label `pkg`) | monotonic µJ counter; delta over time = average watts |
| Card-level energy counter | `hwmon/hwmon3/energy2_input` (label `card`) | same idea, whole-card scope |
| hwmon device name | `hwmon/hwmon3/name` | `xe` |

`hwmon3` is the right hwmon index on this boot (it's discovered dynamically —
a real widget must scan `/sys/class/drm/card1/device/hwmon/hwmon*/name` for
the string `xe` rather than hardcoding `hwmon3`, since the number can shift
across reboots as other hwmon devices attach/detach).

**Power draw**: there is no instant-watts sysfs file. It must be derived by
sampling `energy1_input` (cumulative microjoules) at two points in time and
dividing by the elapsed time. Verified live:

```
E1=... ; sleep 1 ; E2=...
power_W = (E2 - E1) / 1e6 / elapsed_seconds  →  45.2 W  (idle-ish desktop load)
```

This matches nvtop's own `POW N/A / 400 W` cap display (nvtop shows the same
`power1_crit` cap; nvtop displayed instantaneous draw as N/A in our short
sampling window too — it likely does the same energy-delta trick over a
longer window, or simply couldn't get two samples in time).

**VRAM used/total**: **no sysfs file exists for this** (unlike AMD's
`amdgpu` which has `mem_info_vram_{used,total}`). Confirmed via
`find /sys/class/drm/card1 -iname '*vram*' -o -iname '*mem*'` → nothing
under the `xe` sysfs tree except the hwmon VRAM *temperature* channels.
Total VRAM capacity was only observable via:
- `lspci -v -s 03:00.0`: BAR2 `Memory at 4000000000 (64-bit, prefetchable)
  [size=16G]` — this is the resizable PCI BAR window, *not* the true VRAM
  size (it's rounded up to a power-of-2 BAR size).
- **nvtop**, which gets the real figure from the DRM driver's memory-region
  query ioctl (not sysfs): live capture showed `0.985Gi/11.93` — i.e.
  **11.93 GiB total VRAM**, matching the Arc B580's 12 GB spec (minus
  reserved regions).
- Per-process VRAM usage (not total) *is* available for free via
  `/proc/<pid>/fdinfo/<fd>` `drm-total-*` keys once a process holds a DRM
  fd — this is what `gputop`/`nvtop` show per-row (`MEM` column).

**GPU busy %**: also **no single sysfs "busy percent" file** exists for
`xe` (confirmed: `find ... -iname '*busy*'` under the whole card1 tree
returns nothing). The `gtidle/idle_residency_ms` counter looked like an
obvious proxy but is **not reliable**: sampled twice 1s apart while the GPU
was doing essentially nothing (per nvtop, ~0-3%), `idle_residency_ms` didn't
move at all (`idle_status` stayed `gt-c0` the whole time), which would
compute as "100% busy" — clearly wrong. This is a known Xe/RC6 quirk: the GT
can sit parked in the C0 power state (not deep idle) even with negligible
render-engine load, so idle-residency deltas don't track actual engine
utilization. **Real utilization requires the fdinfo mechanism** (§5/§6),
same as nvtop and `gputop` use.

## 3. Permissions

Every sysfs path above (freq, throttle, gtidle, all hwmon temp/power/energy
files) was read as the plain user `olebinders` (`uid=1000`, groups
`wheel,dialout,video,docker`) with **no sudo and no elevated permission
needed** — all are world-readable (`-r--r--r--`, root-owned but 0444). No
root required for any of the sysfs/hwmon telemetry values.

The DRM device nodes:
```
crw-rw----+ root video  /dev/dri/card1       (needs `video` group — we have it)
crw-rw-rw-  root render /dev/dri/renderD128  (world read-write)
```
`renderD128` (the render-only node used for ioctl-based queries like VRAM
size/regions and opening a DRM fd for fdinfo-based busy tracking) is
world-accessible; `card1` needs `video` group membership, which the current
user already has.

Passwordless sudo is **not** configured (`sudo -n true` → "a password is
required"), and `/sys/kernel/debug/dri/` (debugfs, which some deeper Xe
counters live under) is root-only (`Permission denied` as normal user) —
so any approach relying on debugfs is a non-starter for this project's "no
interactive sudo" constraint. Nothing we need for the widget requires it,
however (see §5).

## 4. `intel_gpu_top -J` — does not work on this machine

```
$ timeout 3 intel_gpu_top -J -s 1000
No device filter specified and no discrete/integrated i915 devices found
Detected Xe device which is not supported by intel_gpu_top.
Please use 'gputop' tool instead.
```

**`intel_gpu_top` explicitly refuses to run against `xe`-driver devices on
this build** (`igt-gpu-tools-2.4-1.fc44`, same package that also ships the
`gputop` binary). It only supports legacy `i915`. This directly invalidates
using `intel_gpu_top -J` as the GPU widget's data source on this exact
machine, despite it being listed as "already installed and working" at
project kickoff — it's installed, but not usable for the Arc B580 here
specifically because of the driver split. (It *is* still useful ground
truth on any `i915`-driven Intel iGPU, just not this dGPU.)

### `gputop` (the Xe-era replacement, same package)

- No `-J`/JSON mode — it only offers a text UI (`-d SEC[.TENTHS]`,
  `-n ITERATIONS`).
- Runs fine as a **normal user, no root/CAP_PERFMON needed** — verified by
  running it through a Python-allocated pty (it clears the screen with
  ANSI codes when not attached to a real terminal, so plain piping shows
  nothing; captured via `pty.fork()` to get real output).
- Output is **per-process, per-engine**, not a single global number:
  ```
  DRM minor 128   Frequency(MHz) GT0-1217/1550 GT1-1200/1200
   PID      MEM      RSS   rcs     vcs     vecs    bcs     ccs    NAME
  5801     759M     759M | 16.7% ||  0.0% ||  0.0% ||  0.0% ||  0.0% | zen
  7244     330M     330M |  0.3% ||  0.0% ||  0.0% ||  0.0% ||  0.0% | plasmashell
  ...
  ```
  Columns are: PID, VRAM used, RSS, then per-engine busy % for each DRM
  engine class (`rcs`=render/3D, `vcs`=video decode, `vecs`=video enhance,
  `bcs`=blitter/copy, `ccs`=compute). A single "GPU %" number is not
  emitted anywhere by this tool — you'd sum/max across processes and
  engines yourself if you wanted one aggregate figure, same as nvtop does.
- Two separate `DRM minor` groups appear (minor 1 = primary node used by
  Xwayland, minor 128 = render node used by everything else) — both need to
  be considered/merged for a complete picture.

nvtop's own **overall** `GPU0[N/A]` gauge in our live capture (vs. its
functioning per-process `GPU %` column) corroborates that there's genuinely
no clean "global busy %" source on this xe/Battlemage stack right now —
even nvtop can't fill that gauge in and instead sums per-process numbers.

## 5. How nvtop actually sources Intel GPU data (cross-check)

nvtop (`Syllo/nvtop` on GitHub, GPLv3, open source) detects Intel GPUs
generically via `/sys/class/drm` (vendor ID + driver name, so it supports
both `i915` and `xe` through the same code path). For utilization, it does
**not** read a single sysfs busy-percent file either: it opens each
process's `/proc/<pid>/fdinfo/<fd>` for DRM fds, reads the
`drm-engine-*`/`drm-total-*` keys (a kernel interface Intel added in 5.19+,
present for both `i915` and `xe`), and computes per-engine busy % from the
delta of the cumulative "engine time" counter between two polls divided by
elapsed wall time — exactly the same mechanism `gputop` uses, and it sums
those across all DRM clients to build its per-process rows. Memory
(VRAM total) and clocks/temps/power come from the DRM ioctl memory-region
query and sysfs/hwmon respectively, same paths as this doc found by hand.
This confirms fdinfo-delta math (not a magic single sysfs number) is the
correct, standard technique for Intel GPU utilization on this driver
generation, and that reading it doesn't require elevated privileges (nvtop
runs on this machine as this user without sudo).

Sources:
- https://github.com/Syllo/nvtop
- https://github.com/Syllo/nvtop/blob/master/README.markdown
- https://github.com/Syllo/nvtop/pull/331

## 6. Recommended integration approach for the QML/Plasma widget

**Recommendation: (a) read sysfs/hwmon directly from QML/JS on a Timer for
freq/temp/power, PLUS a lightweight custom fdinfo-delta reader (small
native/C++ helper or a lightweight parse of `/proc/*/fdinfo`) for
utilization — not shelling out to `intel_gpu_top` or `gputop`.**

Justification:

- **`intel_gpu_top -J` is a dead end on this machine** — it hard-refuses
  `xe` devices (§4). Building the "priority-one" GPU widget around it would
  make the widget non-functional on the exact hardware it's meant for.
  This alone rules out option (b) as originally scoped.
- **`gputop` (the Xe-capable replacement) has no JSON/machine-readable
  output**, only an ANSI-formatted text UI meant for a terminal. Parsing
  that reliably (handling the clear-screen escape codes, column widths,
  two `DRM minor` sections, process churn) is significantly more fragile
  and more work than reading a handful of sysfs files directly, for a tool
  we don't control the output format of and that isn't designed to be
  scraped.
- **Direct sysfs/hwmon reads cover freq, temp, and power (via energy
  delta) cleanly**: all are plain files, all confirmed world-readable as a
  normal user (§3), no subprocess, no parsing beyond `parseInt`, trivially
  pollable from a QML `Timer` via Plasma's `Qt.labs.platform` /
  `KIO`/file-read APIs or a tiny C++ `DataSource` plugin. This satisfies
  the "no interactive sudo" and "no elevated permissions" hard constraints
  in `AGENTS.md` outright — nothing here needs root.
- **GPU busy % is the one metric with no sysfs shortcut.** The correct,
  proven technique (used by nvtop and gputop, §5/§6) is: enumerate PIDs
  with an open DRM fd, read `/proc/<pid>/fdinfo/<fd>`'s `drm-engine-*` (or
  `drm-cycles-*`/`drm-total-cycles-*`) busy-time counters, take two samples
  a poll-interval apart, and compute `Δbusy_ns / Δwall_ns * 100` per engine
  (then combine engine classes, e.g. show `rcs`+`ccs` as "GPU %", `vcs`+
  `vecs` as a separate "media %" if desired). This is plain-text
  `/proc` parsing, needs no special capability (verified — `gputop`, which
  does exactly this, ran as a normal user with no CAP_PERFMON/sudo), and
  is small enough to implement directly rather than depending on an
  external tool's text formatting.
- Recommended shape for `plasmatop-gpu`'s data source: a small QML
  `Timer`-driven JS/C++ helper that on each tick (a) `readFileSync`s the
  sysfs/hwmon paths in §2 directly for freq/temp/power/VRAM-used-per-process
  (or omit VRAM total-capacity, since it's not in sysfs — either hardcode
  it as a config default from `nvtop`'s observed 11.93 GiB, or query it
  once at startup via a tiny ioctl call/plasmoid-side helper against
  `/dev/dri/renderD128`, which is world-accessible), and (b) walks
  `/proc/*/fdinfo` once per tick, filtering to entries containing
  `drm-driver:\txe` (or matching this GPU's PCI address in `drm-pdev`),
  and does the delta math for busy %. No subprocess spawn per tick avoids
  the process-spawn overhead/latency of shelling out every poll interval,
  and avoids depending on `intel_gpu_top`/`gputop`'s presence, output
  format, or version behaving consistently across Fedora updates —
  robustness matters since this is meant to be a maintained, always-on
  panel widget, not a one-off script.
- Do **not** pick option (c) "something else" like a perf_event/PMU-based
  reader: `perf_event_paranoid` is `2` on this machine and the `xe` PMU
  device (`/sys/bus/event_source/devices/xe_0000_03_00.0`) exists, but
  using it via `perf_event_open` typically wants `CAP_PERFMON` for an
  unprivileged process to read GPU-wide PMU counters — an unnecessary
  privileges/packaging complication (capabilities on a QML/JS-invoked
  helper) compared to the fdinfo approach, which needs nothing beyond
  normal file read permissions already confirmed in §3.

**Bottom line:** sysfs + hwmon direct reads for freq/temp/power, a small
custom `/proc/*/fdinfo` delta-based reader for GPU busy % (mirroring what
nvtop/gputop do internally), VRAM total pulled once via a DRM ioctl or
hardcoded from nvtop's live reading — no shelling out to `intel_gpu_top`
(broken for `xe` here) or `gputop` (no JSON, fragile to scrape), and no
privilege elevation of any kind.
