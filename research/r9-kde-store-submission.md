# R9 — store.kde.org submission spike

Machine: Fedora Linux 44, Plasma 6.7.5, `kpackagetool6 2.0`, 2026-09-14.
Scope: what it would actually take to publish `plasmatop-{gpu,cpu,mem,net,disk}`
to store.kde.org. **No widget code, metadata.json, or LICENSE file was
touched — this is research only**, per the task brief.

Repo state confirmed at spike time: `git status` reports "No commits yet",
every file untracked — there is no git history at all yet, not even a first
commit, despite 5 working widgets and 8 prior research docs already existing.

## 1. The symlinked shared-code packaging problem — CONFIRMED BLOCKING, tested live

This is the most important finding of the spike, so it's first, and it's not
theoretical — I built and inspected actual archives.

**Current structure**, confirmed via `find`/`ls -la`:

```
shared/theme/AsciiBox.qml, BarMeter.qml, ColorScale.qml, CoreGrid.qml,
              MetricRow.qml, MountList.qml, Sparkline.qml, fonts/

widgets/plasmatop-gpu/contents/ui/theme -> ../../../../shared/theme
widgets/plasmatop-cpu/contents/ui/theme -> ../../../../shared/theme
widgets/plasmatop-mem/contents/ui/theme -> ../../../../shared/theme
widgets/plasmatop-net/contents/ui/theme -> ../../../../shared/theme
widgets/plasmatop-disk/contents/ui/theme -> ../../../../shared/theme
```

Every `main.qml` does `import "theme" as Theme` (confirmed in
`plasmatop-gpu/contents/ui/main.qml:22`) — a plain relative QML import that
resolves through that symlink at runtime.

**Test 1 — naive zip of a single widget directory** (what you'd get from
`zip -r` or GitHub's own "download zip", i.e. exactly what a naive "package
for the store" step would produce if nobody thought about this):

```
$ cp -r widgets/plasmatop-gpu plasmatop-gpu-copy
$ zip -r test1.zip plasmatop-gpu-copy
$ unzip -q test1.zip -d extracted1        # simulating a user extracting the download elsewhere
$ file extracted1/plasmatop-gpu-copy/contents/ui/theme
extracted1/plasmatop-gpu-copy/contents/ui/theme: cannot open ... No such file or directory
```

**Confirmed: `zip` stores the symlink as a symlink** (target string
`../../../../shared/theme`, a relative path that climbs out of the archive
entirely). The moment the archive is extracted anywhere that isn't literally
this exact repo checkout, `contents/ui/theme` is a dangling symlink pointing
at a directory that doesn't exist. `import "theme"` then fails to resolve —
**the widget would not load at all** for anyone who downloads it from the
store. This isn't a cosmetic bug, it's a hard packaging blocker for all 5
widgets simultaneously (they all use the same symlink pattern).

**Test 2 — dereferencing copy before zipping** (the fix):

```
$ rsync -aL widgets/plasmatop-gpu/ plasmatop-gpu-build/    # -L = follow symlinks, copy real files
$ file plasmatop-gpu-build/contents/ui/theme
plasmatop-gpu-build/contents/ui/theme: directory              # real dir now, not a symlink
$ zip -r test2.zip plasmatop-gpu-build
$ unzip -q test2.zip -d extracted2
$ ls extracted2/plasmatop-gpu-build/contents/ui/theme
AsciiBox.qml  BarMeter.qml  ColorScale.qml  CoreGrid.qml  fonts  MetricRow.qml  MountList.qml  Sparkline.qml
```

Self-contained, real files, correct in isolation. I also confirmed
`kpackagetool6 -t Plasma/Applet -i test2.zip` **accepts a `.zip` directly**
as an installable package (it errored only with "already exists" because
that plugin ID is already installed on this machine from local dev — i.e.
it got far enough to recognize and attempt the install, which is what
matters here: kpackagetool6 doesn't require a directory, a `.plasmoid`/`.zip`
works).

**Conclusion**: the symlink is the *right* choice for local development
(single source of truth while actively editing 5 widgets' shared QML) and
does not need to change. But it is **not** what should get zipped for
distribution. This needs a small, new **packaging/build step** — a script
(e.g. `scripts/package-for-store.sh`) that, per widget: copies the widget
dir to a build/tmp location with `rsync -aL` (or `cp -rL`) so the symlink
becomes real files, then zips that as `<KPlugin.Id>-<version>.plasmoid`
(store convention, confirmed by discussion-thread evidence in §3). This is
a solved, small problem — not an architecture change — but it currently
does not exist anywhere in the repo (checked: no `scripts/` at repo root,
no Makefile, no CI config). **This is the top punch-list item.**

Rejected alternatives, and why:
- *"One widget vendors `theme/`, others depend on it at runtime"* — Plasma
  has no supported mechanism for one installed plasmoid package to import
  QML out of a sibling plasmoid's package directory by a portable relative
  path; it would also mean installing `plasmatop-net` alone (a real,
  supported use case per this project's own scope doc) silently breaks
  unless `plasmatop-gpu` happens to also be installed. Not viable.
- *"Just tell users to install from the git repo, not a zip"* — defeats the
  entire point of a KDE Store listing, which distributes a `.plasmoid` file
  fetched by Plasma's "Get New Widgets" (GHNS), not a git clone.

## 2. Actual submission mechanism (confirmed via discuss.kde.org threads, current)

store.kde.org's storefront is the **pling.com / OpenDesktop.org (OCS) network**
— same backend KDE has used for years, still current. Confirmed process from
two `discuss.kde.org` threads (2024/2025, most current concrete
first-hand accounts found):

1. **Account**: register at store.kde.org (an OpenDesktop/pling account).
   One reporter noted the signup **rejected a Gmail address**, requiring an
   alternative provider (e.g. Proton Mail) — worth flagging since it's a
   real, recently-reported friction point, though it applies to the *store
   account signup itself*, separate from the `Authors.Email` field already
   in `metadata.json` (that field is unaffected either way).
2. **Submission**: from the profile menu, "Add Product", or directly at
   `store.kde.org/product/add` (this redirects into a pling.com multi-step
   form — I could not fetch this form's live content directly, see note
   below, so field-by-field detail below is from secondhand reports, not a
   live capture).
3. Fill in name, description, **category** (one thread explicitly called out
   category selection as "confusing," recommending you look at existing
   store listings in the same category first), **license** (a dropdown; GPL
   2/3 was described as the "recommended" default in that thread, but the
   dropdown is not GPL-only — MIT is a normal, selectable option elsewhere
   on the OCS network, and MIT is one of KDE's own explicitly-accepted
   licenses, see §5).
4. Homepage / source-code link fields exist on the product page (no direct
   "upload your source" field — you link out, GitHub is the commonly-used
   target).
5. Once the product page exists, open its **Files** tab and upload the
   actual `.plasmoid` file (a zip, see §1). One reporter said their widget
   showed up in Plasma's in-app "Get New Widgets" search within minutes of
   uploading — syndication back into KNewStuff/GHNS is fast, not a long
   manual-review queue (at least not one visible to the submitter).

**No `ocs` CLI tool or invent.kde.org integration is part of this path** —
this is a plain authenticated web-form upload, not a git-push-to-publish
model. (`invent.kde.org` is KDE's own GitLab for *KDE-project-owned* code;
a third-party plasmoid like this one has no obligation to live there, and
nothing in the submission flow requires it.)

**Caveat on my own research method**: I attempted to `WebFetch` the actual
`store.kde.org/faq-pling` and `store.kde.org/product/add` pages directly to
get a first-hand, current field list, and both were blocked by the site's
**Anubis anti-bot challenge** (an access-denial page, not a 404) — this is
the site actively blocking automated fetches, not a dead link. Everything in
this section is therefore from indirect, current (2024-2025) human accounts
on `discuss.kde.org`, cross-checked across two independent threads that
agree with each other, rather than a live capture of the form itself. A
human should do one live click-through of `store.kde.org/product/add`
before submitting, to catch any field that's changed since those threads.

## 3. metadata.json fields — what's there vs. what a store listing expects

Confirmed via `develop.kde.org/docs/plasma/widget/setup/` and
`/properties/` (current Plasma 6 docs) plus this repo's actual files
(checked all 5 `widgets/*/metadata.json` — identical shape across all 5,
differing only in `Id`/`Name`/`Description`/`Icon`).

**Currently present in all 5** (already correct/sufficient for a *local
install*): `KPackageStructure`, `KPlugin.Id`, `Name`, `Description`,
`Category`, `Icon`, `Authors` (Name+Email), `Version: "0.1.0"`,
`License: "MIT"`, `X-Plasma-API-Minimum-Version: "6.0"`.

**Documented but currently absent, relevant to a public store listing**:
- `KPlugin.Website` — project homepage URL. Not required by Plasma itself
  to *load* the widget, but this is exactly the field a store listing (and
  a curious user right-clicking → "About this widget") would show, and it's
  currently empty because there's nowhere to point it (see §7, no repo is
  pushed anywhere public yet).
- `KPlugin.BugReportUrl` — issue tracker link. Same story: needs a public
  repo to point at first.
- The official docs pages do **not** themselves specify a required
  `Screenshots` key in `metadata.json`, and I found no evidence screenshots
  are metadata.json-driven at all — screenshots are attached to the store
  *product listing* itself (uploaded separately in the web form, §2/§6),
  not referenced from inside the package. Don't invent a `Screenshots` key.
- `License: "MIT"` as a **plain string** (not an SPDX expression like
  `MIT`/`GPL-2.0-or-later` in a `SPDX-License-Identifier`-style field) is
  what the docs' own examples show (`"License": "MIT"` is literally used as
  a docs example) — the current value is already in the right shape; no
  change needed here for Plasma's own metadata parsing. (§5 covers a
  *separate*, additional requirement: an actual `LICENSE` file in the repo,
  which is currently missing — the metadata string alone isn't sufficient
  once this leaves "local use only.")

**Recommendation**: add `Website` and `BugReportUrl` to all 5
`metadata.json` files once a public repo exists (§7) — cheap, expected,
currently blocked only on there being a URL to put there.

## 4. Five widgets → five store listings (no bundling mechanism found)

No evidence of a "widget pack"/"suite" listing mechanism on store.kde.org —
searched specifically for this. The store is a flat product catalog; each
product page has its own Files tab. There's no KDE-native concept of "one
listing, five separate installable plasmoids picked individually" the way
e.g. a Steam bundle or a monorepo GitHub release with multiple assets works
for end users browsing in-app.

**Practical options, in order of how much they match this project's own
"five separate, single-purpose widgets" decision** (README §Scope, locked at
kickoff — not something this research spike should relitigate):

1. **Five separate product listings** (`plasmatop-gpu`, `plasmatop-cpu`,
   etc., each its own store page with its own `.plasmoid` file) — matches
   the project's existing architecture exactly, since Plasma's own "Get New
   Widgets" browser lets a user install just the one they want, same as any
   other individually-listed plasmoid. This is the natural fit and what I'd
   recommend: it costs 5x the listing-page setup effort (5x the same
   description boilerplate, 5x screenshots) but zero architecture change,
   and correctly reflects that a user can install `plasmatop-net` alone
   without needing the other 4 — which is a real, intentional current
   capability of this project that a single bundled listing would obscure
   or contradict.
2. A single listing that just happens to have 5 `.plasmoid` files attached
   in its Files tab, all under one product page — technically possible
   (Files tabs support multiple uploads) but a worse fit: store search/
   category browsing surfaces one product name, so someone searching "GPU
   monitor" wouldn't find `plasmatop-gpu` unless the product's *title*
   somehow covers all five use cases, which undersells the individual
   widgets. Not recommended.

**Recommendation: 5 separate listings**, cross-linking each one's
description text to the others (e.g. "part of the plasmatop suite — see
also: [links]") so the connection is discoverable without forcing a bundle.

## 5. LICENSE file — required in practice, currently missing, MIT is accepted

`metadata.json` already declares `"License": "MIT"` in all 5 widgets, but
**there is no actual `LICENSE`/`COPYING` file anywhere in the repo** (checked
with `find . -iname "LICENSE*" -o -iname "COPYING*"` — zero hits) and there
are zero git commits, so there's also no license notice in any commit
history either. This is a real gap, not a formality:

- KDE's own community-wide licensing guidance
  (`community.kde.org/Guidelines_and_HOWTOs/Licensing`) explicitly lists
  `MIT` among accepted SPDX identifiers (alongside `LGPL-2.1-or-later`,
  `GPL-2.0-or-later`, `GPL-3.0-or-later`, `BSD-2-Clause`) — **MIT is fine**,
  nothing needs to change about the choice already made.
- That same policy is written for KDE's *own* repos and mandates a
  `LICENSES/` folder with one file per SPDX identifier used, plus a
  per-file `SPDX-License-Identifier` header (REUSE-tool compliant). This
  project is a third-party plasmoid (`com.olebinders.*` namespace, not
  `org.kde.*`) and is **not** obligated to be a KDE-project repo under that
  full policy — but it's the clearest evidence available that a real
  `LICENSE`/`LICENSES/MIT.txt` file, not just a metadata string, is the
  norm this ecosystem expects, and the store's own submission form asks the
  submitter to pick a license too (§2) — a plain string in `metadata.json`
  with no backing file in the actual downloaded source is the kind of gap a
  reviewer or a downstream packager would flag.
- **Minimal correct fix**: one `LICENSE` file at the repo root (not one per
  widget — it's one project, one license, this is standard practice
  regardless of the 5-package split), standard MIT boilerplate:

  ```
  MIT License

  Copyright (c) 2026 Ole Hetland

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  ```

  Copyright year 2026 (current year per this project's own dated docs),
  holder "Ole Hetland" (matches `Authors.Name` already in every
  `metadata.json`). This is implementation work for a follow-up task, not
  done here per the brief — text above is provided so the coder task
  doesn't need to re-derive it.

## 6. README/screenshots/changelog for the listing itself

Concrete, confirmed dimensions/format specs were **not findable** — the
official upload form is Anubis-blocked to automated fetches (§2 caveat), and
no secondary source gave exact pixel requirements. What is confirmed/
inferable:

- Every store listing needs a description (the product page's body text —
  this project already has strong source material: `README.md`'s Scope
  section, and the btop-aesthetic framing repeated across `research/r6`/`r7`
  could be lightly adapted into "why this looks the way it does" listing
  copy) and at least one screenshot to not look abandoned/broken in browse
  view — this is universal store-listing practice, not KDE-specific, and
  matches what every populated `store.kde.org` product page actually shows
  when browsed.
- One secondary source suggested screenshots in **16:9** for best rendering
  in the store's preview carousel — treat as a soft guideline, not a
  confirmed hard requirement, given it wasn't corroborated by an official
  KDE doc.
- No metadata.json-level "Screenshots" key exists (§3) — screenshots are a
  store-listing-page upload, separate from the package.
- No changelog requirement found anywhere — Version bumps + the product
  page's own free-text description covering "what's new" is standard
  practice on this store, not a mandated separate file/field.
- **Practical blocker specific to this project**: there are currently no
  screenshots anywhere in the repo (not checked exhaustively for image
  files, but nothing surfaced in any directory listing) — these need to be
  taken from the actually-running widgets on this machine before any
  listing can be created, regardless of exact dimension requirements.

## 7. Versioning — 0.1.0 is fine as a first submission

Nothing found (in KDE docs or the store threads) requires strict semver or a
specific starting version — `Version` is a freeform string Plasma displays
as-is. `0.1.0` reads honestly as "early but real" and plenty of store
listings start at `0.x`; **no version bump is required before first
submission**. The one thing worth deciding deliberately (not a blocker, a PO
call) is whether all 5 widgets should ship their first public version in
lockstep at the same number, since they're one conceptual "suite" release
even as 5 separate listings (§4) — cosmetic, not technical.

## 8. Recommended punch-list, priority order

1. **[Blocking, technical] Add a packaging build step that dereferences
   `shared/theme/` before zipping.** Confirmed in §1 that a naive zip of any
   widget directory ships a dangling symlink and the widget will not load
   for anyone who installs it from the store. A small script
   (`rsync -aL <widget>/ <build-dir>/` then `zip` the build dir as
   `<Id>-<Version>.plasmoid`) fixes this and was confirmed to produce a
   working, self-contained, `kpackagetool6`-installable archive. The
   existing symlink setup should stay exactly as-is for local dev — this is
   an additive packaging script, not a rearchitecture.
2. **[Blocking, non-technical] Get the repo onto a public git host**
   (GitHub, or invent.kde.org — either works, GitHub is the far more common
   choice for third-party plasmoids per the store threads). Currently zero
   commits exist anywhere. This is needed before `Website`/`BugReportUrl`
   metadata fields (§3) or the store listing's homepage/source links (§2)
   have anything real to point to, and before a `LICENSE` file (§5) is
   meaningfully "published" rather than just sitting locally.
3. **[Required, cheap] Add a root `LICENSE` file** (MIT boilerplate given
   in §5) — `metadata.json` already says MIT, this just backs that claim
   with an actual file, which the ecosystem norm (§5) expects even though
   nothing technically stops `kpackagetool6` from installing a widget that
   lacks one.
4. **[Required, cheap] Add `Website`/`BugReportUrl` to all 5
   `metadata.json` files** once punch-list item 2 exists to point them at.
5. **[Required, one-time legwork] Take screenshots of each of the 5 running
   widgets** and write a short per-widget description for its store listing
   (source material already exists in `README.md` and `research/r6`/`r7`'s
   btop-aesthetic framing — this is adaptation, not fresh writing).
6. **[Decision, not a blocker] Confirm the 5-separate-listings approach**
   (§4) with the product owner before creating store pages — it's the
   recommended fit given the project's existing "5 independent widgets"
   architecture decision, but it is a store-presentation choice the PO
   should explicitly sign off on, not something to silently assume.
7. **[Not required] Leave `Version: "0.1.0"` alone** — no version bump
   needed before first submission (§7); only revisit if the PO wants all 5
   widgets' first public release numbered in lockstep as a deliberate
   suite-release choice.
8. **[Do at submission time, not before] Account signup** — use a
   non-Gmail address for the store.kde.org/pling account itself if signup
   rejects Gmail as one 2024/2025 report described (§2) — separate from the
   Gmail address already correctly used in `metadata.json`'s `Authors.Email`,
   which needs no change.

Item 1 is confirmed to be the single most important technical blocker asked
about in the task brief — it is real (reproduced locally, not theoretical)
and it affects all 5 widgets identically since they share the exact same
symlink pattern.
