# Research notes

External facts this project relies on, with where they came from. Recorded
because several were verified against source or the installed binaries rather
than documentation, and would be expensive to re-establish.

Verified against **REAPER 7.80** (macOS/arm64), **SWS 2.14.0 build 7**,
**ReaImGui 0.10.0.5**, in Sep 2026.

## Prior art

| Tool | Matching | Tracks | Items | Regions/markers |
|---|---|---|---|---|
| SWS Auto Color 2.14.0.7 | case-insensitive substring (`stristr`) | yes | **no** | yes |
| joshnt Auto-Color Items (Aug 2024) | Lua patterns, undocumented | no | yes | no |
| mpl "user defined filter" (2021) | rules hardcoded in source | folders only | no | no |
| nvk_THEME ($19) | `*` wildcards | yes | no | no |
| REAPER itself | — | — | — | — |

* SWS matching is two `stristr` call sites in `Color/Autocolor.cpp`; `*`, `?`,
  `.` and `[` are matched literally. Its only non-substring filters are a fixed
  keyword list (`(any)`, `(unnamed)`, `(folder)`, `(master)`, …) compared with
  `strcmp`.
* [SWS PR #1291](https://github.com/reaper-oss/sws/pull/1291) proposed
  `$`-prefixed regex; closed unmerged 27 Feb 2025. Blockers: C++11 `<regex>`
  unavailable on SWS's macOS 10.5 deployment target, and an invalid pattern
  could crash REAPER at startup and brick the install.
* [SWS issue #1868](https://github.com/reaper-oss/sws/issues/1868) asks for
  `only`/`not` so "bass" does not hit "bassoon"; open, no commitment.
* REAPER changelog 6.0 → 7.80: zero hits for `auto.?colo`.
* ReaPack indexes (ReaTeam Scripts, X-Raym, MPL, acendan, Joshnt): no
  rule-based colouriser. Every take-colour script is manual or random.

## PCRE is not usable from ReaScript

[Mavriq Lua Batteries](https://github.com/mavriq-dev/mavriq-lua-batteries) is
the only route to `lrexlib`. It ships `lua53.dylib` while REAPER 7 uses Lua 5.4,
is still a release candidate from May 2023, and has an open unanswered issue:
*hard crash when requiring a module on M4 Mac* (Jun 2025).

Pure-Lua alternatives: [reLua](https://github.com/o080o/reLua) is active but has
no anchors, no `{n,m}`, and is implicitly anchored at both ends.
`jsdotlua/LEGACY-regex-lua` was archived Aug 2023.

## REAPER preferences that affect what you see

**Preferences → Appearance → Peaks/Waveforms**, under *"Extra peaks display
options — many themes including the default override these"*:

```
Tint media item waveform peaks to:   [Track color] [Item color] [Take color]
Tint media item background to:       [Track color] [Item color] [Take color]
```

Precedence is **take > item > track**. REAPER's own tooltip: *"Custom take
colors override custom item colors, which override custom track colors."* Stored
in `reaper.ini` as `tinttcp`; the key is absent until changed.

**Preferences → Appearance → Media**:

```
Automatically color any recording pass that adds takes or lanes
```

Tooltip: *"When recording, automatically apply the same random color to all
takes created in the same recording pass, or all media items in the same fixed
lane."* This is the usual source of custom take colours nobody remembers
setting.

## Take colours

* The only recurring use case in the wild is **comping** — making each recording
  pass visually distinct. REAPER covers it natively, keyed off the *recording
  pass*, which a name matcher cannot see.
* For keepers vs rejects REAPER has take **ranking** (`Item: Up-rank active take
  or last recording pass`, down-rank, delete-by-rank), not colour.
* Take names come from the recorded filename, whose default pattern is
  track-derived (`$tracknumber-$track`, or with a timestamp). Renaming a track
  does **not** retro-rename existing takes.
* REAPER 7 comping uses fixed **item lanes**, not takes, so the modern version
  of that workflow is an item-colouring problem.
* Claimed-but-unfound uses: colouring by mic/DI/amp source, by session, by
  performer. Those are track-level concerns and people solve them with tracks.

`GetDisplayedMediaItemColor2(item, take)` resolves the whole track/item/take
cascade *according to the `tinttcp` preference* — it answers "what will the user
actually see", not "what is set". Zero means no colour, not black.

## ReaImGui 0.10 facts

* The repo moved to [codeberg.org/cfillion/reaimgui](https://codeberg.org/cfillion/reaimgui);
  the GitHub mirror was archived 3 Jun 2026. Same for ReaPack.
* Use the shim: `package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'` then
  `require 'imgui' '0.10'`. It version-guards and gives typo protection.
* `ImGui.End(ctx)` is called **only** if `Begin` returned true — a deliberate
  deviation from C++ Dear ImGui. Same for `BeginChild`/`EndChild`.
* There is **no `DestroyContext`** in 0.10; you close by not re-deferring.
* `CreateFont(family, flags)` takes **no size**; size is given at
  `PushFont(ctx, font, size)`, in logical pixels at 96 DPI. `Attach` is no
  longer required before use.
* DPI is automatic. All coordinates are logical units and glyphs rasterise at
  device resolution. `GetWindowDpiScale` returns 2.0 on Retina and is
  informational — multiplying by it double-scales the UI.
* There is no style preset API (`StyleColorsDark/Light`) and no `SetStyleColor`;
  only `GetStyleColor` and push/pop. ReaImGui does not follow REAPER's theme.

The full API reference ships locally with the extension:
`<resource path>/Data/reaper_imgui_doc.html`.

## ReaScript colour API

* `ColorToNative(r,g,b)` / `ColorFromNative(col)`. Native layout is OS
  dependent — RGB on macOS, BGR on Windows — so **persist plain `0xRRGGBB`** and
  convert only at the API boundary.
* The `|0x1000000` "enabled" bit is required on `I_CUSTOMCOLOR` for tracks,
  items and takes. Without it the colour is *stored but not used*. Setting 0
  clears.
* Markers/regions: `EnumProjectMarkers3` to read, `SetProjectMarker4` to write.
  `SetProjectMarker4` treats `color = 0` as **leave unchanged**, so it cannot
  clear — clearing needs `SetRegionOrMarkerInfo_Value` (REAPER 7.62+), guarded
  with `APIExists`.
* `GetSetMediaTrackInfo_String(tr, 'P_NAME', …)` returns **false** on the master
  track. Media items have no `P_NAME` at all; match the active take.
* `UNDO_STATE_*` are `reaper_plugin.h` defines, not exposed to Lua:
  `TRACKCFG=1`, `ITEMS=4`, `MISCCFG=8` (markers and regions live under MISCCFG).
  `UNDO_STATE_ALL` forces a full project snapshot and is slow.
* `SetProjExtState` / `GetProjExtState` — not `SetProjectExtState`.
* ExtState values **must not contain newlines**; documented.
