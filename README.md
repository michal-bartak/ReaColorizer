# Name Colorizer for REAPER

Colour tracks, items, regions and markers from their **names**, using plain
substring, glob, or **real regular expressions**.

SWS's Auto Color does case-insensitive substring matching only (`stristr`, two
call sites in `Color/Autocolor.cpp`) and has no item support at all. This covers
tracks, items *and* regions/markers in one ordered rule list, with regex.

## Requirements

* REAPER 7 (tested against 7.80 on macOS/arm64)
* **ReaImGui 0.10+** — only for the configuration window. Everything else works
  without it. Install via ReaPack: *Extensions → ReaPack → Browse packages →*
  search `ReaImGui` → Install → restart REAPER.
  (ReaImGui lives at <https://codeberg.org/cfillion/reaimgui> — the GitHub repo
  was archived in June 2026 and is now a stale mirror.)

## Install

Copy the `NameColorizer` folder into your REAPER `Scripts` folder, then add the
actions you want in *Actions → Show action list → New action → Load ReaScript*:

| Script | What it does |
|---|---|
| `MXM_NameColorizer_GUI.lua` | the configuration window |
| `MXM_NameColorizer_ApplyAll.lua` | colour the whole project, one undo point |
| `MXM_NameColorizer_ApplySelection.lua` | colour the selected tracks and items |
| `MXM_NameColorizer_ClearColors.lua` | reset colours to default |
| `MXM_NameColorizer_AutoToggle.lua` | start/stop background auto-colouring |
| `MXM_NameColorizer_Dump.lua` | read-only diagnostic listing |
| `MXM_NameColorizer_RunTests.lua` | self-test, prints to the console |

## Rules

The window has **one tab per object kind** — Tracks, Items, Regions, Markers —
and each tab holds its own ordered list. Within a tab, **the first rule that
matches wins**; reorder them to change precedence, exactly like firewall rules.

Precedence is per tab, so reordering your track rules can never change which
region wins. Each tab also only offers the filters that mean something for it:
folder filters exist on Tracks and nowhere else.

Each rule has a match mode:

| Mode | Matches | Example |
|---|---|---|
| **contains** | anywhere in the name, nothing is interpreted | `bass` matches "Sub Bass DI" |
| **glob** | the **whole** name; `*` `?` `[abc]` `[!abc]` | `*bass*`, `Gtr_?`, `[Bb]ass*` |
| **regex** | anywhere unless anchored | `^(kick\|snare\|hh)\b` |

Note the difference: `bass` as a *glob* matches only a track called exactly
"bass", because globs are anchored. As *contains*, it matches "Sub Bass DI".

### Supported regex syntax

```
.                any character except newline (one whole UTF-8 character)
( )  (?: )       capturing / non-capturing group
|                alternation
* + ? {n} {n,} {n,m}     greedy; add ? for lazy (*? +? ??)
[abc] [^abc] [a-z]       character classes
\d \D \w \W \s \S        digit / word / space classes
\b \B            word boundary
^ $              start / end of the name
\n \t \r \xHH    escapes
(?i)             case-insensitive, at the very start only
```

Not supported, and rejected with a clear message rather than silently
misbehaving: backreferences, lookaround, named groups.

### Filters

A rule can carry an optional non-name filter that **narrows** what it matches:
`is a folder track`, `is inside a folder`, `has no name`.

Leave the pattern empty to match on the filter alone — an empty pattern with
*is a folder track* means "every folder track". Combine them and both must hold.

### Colouring items from their track

A track rule has an **also colour items** switch. With it on, every item sitting
on a track that rule matches gets the track's colour — *whatever those items are
called*. That is usually what you want: colour the Bass track purple and its
parts go purple too, without naming them.

Precedence for an item is:

1. a rule on the **Items** tab, if one matches its take name — this always wins
2. otherwise its track's colour, if that track's rule has *also colour items*
3. otherwise nothing

The switch travels down folders with the colour, so a cascading folder rule also
colours the items on its child tracks.

### Colours

Each rule has a colour, and optionally a **second** colour. With a second
colour, the objects that rule wins are spread evenly along a gradient in HSL, in
project order, separately per kind.

**What a gradient spreads across** is set per rule, in the box beside the second
colour:

| spread across | meaning |
|---|---|
| all matches | one ramp across every match in the project |
| **runs** (default) | a run is an unbroken stretch this rule wins; anything it does not win ends one, and so does a **visual spacer** |
| folders | one ramp inside each folder |
| runs & folders | a new ramp at a gap or a folder edge, whichever comes first |

REAPER 7's **visual spacers** count as a break, so a gradient can be split
without inventing a separator track — *Track: Insert visual spacer before
tracks*, and the ramp restarts there. Usually the tidiest way to say "these
belong together and those don't", since the line is already drawn in the track
panel.

So with `String*` matching any of these, each block gets its own full ramp:

```
String1, String2, String3      <- "runs": the Bus below ends this one
Bus
String11, String12, String13

String1(parent), String2, String3       <- "folders"
String11(parent), String12, String13

String1, String2, String3
─────────────────────────      <- a visual spacer; also "runs"
String11, String12, String13
```

Items group per track as well as per gap, since ramping across a track boundary
is meaningless. Folders are offered for track rules only — nothing else has
folder structure.

Regions and markers can be grouped into runs too, but they **default to
`all matches`** rather than `runs`. A song's regions are normally interleaved —
`Verse, Chorus, Verse, Chorus` — so a rule matching one of them rarely wins two
in a row, and grouping would leave every group with a single member and no
visible gradient. Switch them to `runs` when your regions really do come in
blocks.

Two things to know about gradients:

* They are **position dependent** — inserting an object into a group reshuffles
  that group. Grouping shrinks the blast radius (one group rather than every
  match) but each member then moves further, because groups are smaller. Edits
  at a boundary change membership: renaming the separating `Bus` to `String Bus`
  merges two groups and recolours both.
* They cannot be computed incrementally, so a gradient rule aimed at *items* is
  expensive on very large projects.
* Two combinations quietly flatten a gradient to one colour, and the rule warns
  about both: grouping by folder with an *is a folder track* filter (every group
  has one member), and grouping by folder while folder colours are set to
  *force* (each parent overwrites its children).

### Folder colours

`propagate_folders` controls whether a folder's colour flows to its children:

* `fill_unmatched` (default) — a child that matched its own rule keeps that
  colour; only unmatched children inherit.
* `force` — the folder's colour overrides matched children too.
* `off` — no inheritance.

## Auto-apply

`MXM_NameColorizer_AutoToggle.lua` starts a background loop; run it again to
stop. The toolbar button lights while it runs.

It is built to stay out of your way:

* **It never reverts a colour you set by hand.** If an object's colour stops
  matching what the tool last wrote while its name is unchanged, that object is
  left alone until you rename it.
* It adds **no undo points**, so renaming a track does not shred your undo
  history. Set `auto_undo` if you want them.
* It writes nothing when nothing changed, and pauses entirely while recording.
* Tracks are swept immediately; items and regions follow once the project has
  settled, in time-budgeted chunks.
* **It tries hard not to re-read your project.** REAPER reports one
  project-wide "something changed" counter, so a fader move arrives looking
  exactly like a rename. Tracks are re-read on every change (a rename is only
  visible by reading names) but re-planned only when that reading actually
  differs. Items and regions, of which there are far more, are re-read only when
  one appeared or vanished, when a track changed, or when
  **Rescan items at most every (s)** has passed — 5 s by default, and the only
  thing waiting on it is an item *renamed in place*, which nothing cheaper can
  see. Set it to 0 to re-read everything on every change.

Editing a rule does not repaint the project, and neither does clicking around
in it afterwards — the edit is held until an object actually changes, and then
applied to everything at once so the project is never half on the old rules.
**Apply now** is the way to commit an edit immediately.

**Apply now** (from the window or the action) also tells the background loop to
drop those marks, so the rules take every object back. That is the way out if you
have hand-coloured something and want the rules to own it again.

Opening the configuration window does **not** stop or pause the background loop.
The window shows its status and has its own Pause button; the loop itself is
started and stopped only by the `AutoToggle` action.

Set the ExtState `MXM_NameColorizer` / `auto_debug` to `1` for a console readout.

## Clearing colours

`MXM_NameColorizer_ClearColors.lua` offers two scopes: the selection, or
everything the current rules match. Clearing *every* custom colour in a project
is only available from the GUI, where it can be confirmed properly.

**Reset to the default colour when no rule matches** is set **per kind**
(Options → Scope), off everywhere by default. With it on for a kind, Apply
strips the colour from any object of that kind the rules do not claim.

For **items** this is usually what you want, and it is the better answer to
"my pasted item kept its old colour":

> An item with **no custom colour** is drawn by REAPER in its **track's**
> colour, live. Copy it to another track and it follows that track
> immediately — no rule, no sweep, and nothing that can go stale.

So there are two ways to make items match their track, and they are not equal:

| | how it works | on copy/paste to another track |
|---|---|---|
| **also colour items** on a track rule | writes the track's colour onto the item | stays wrong until something re-applies, and stale if the new track's rule does not cascade |
| **reset unmatched items** | removes the item's colour so REAPER draws it from the track | correct instantly, forever |

Prefer the second unless you actually want items to differ from their track, or
your theme does not tint item backgrounds by track colour.

Be careful turning it on for **tracks**: it will strip every track colour you
set by hand.

## Upgrading from the single-list version

Older configs kept one list where each rule had track/item/region/marker
checkboxes. On first load they are migrated automatically: a rule that ticked
several boxes becomes one rule **per tab**, in the same relative order, so the
precedence you had is preserved within every kind. Nothing is lost, and the
previous file is kept as `config.bak.json`.

After migrating you may find duplicate rules on the Items tab — copies of track
rules that matched item *names*. If what you actually wanted was "colour the
items on these tracks", delete those copies and tick **also colour items** on
the track rule instead.

## Configuration file

```
<REAPER resource path>/NameColorizer/config.json
```

One global rule set shared by every project, deliberately outside `Scripts/` so
reinstalling or updating the scripts cannot destroy your rules. A previous
version is kept as `config.bak.json`; an unreadable file is parked as
`config.bad.json` rather than being lost.

## REAPER preferences that affect what you see

Two settings decide whether the colours this tool writes are visible at all.

**Preferences → Appearance → Peaks/Waveforms**, under *"Extra peaks display
options"*:

```
Tint media item waveform peaks to:   [Track color] [Item color] [Take color]
Tint media item background to:       [Track color] [Item color] [Take color]
```

Precedence is **take > item > track** — a custom take colour beats a custom item
colour, which beats the track colour. If *Item color* is unticked, item colours
may not show no matter what this tool writes. REAPER's own tooltip also warns
that *"Color theme may override this preference"*. The setting is stored in
`reaper.ini` as `tinttcp`, and is absent until you change it.

**Preferences → Appearance → Media**:

```
Automatically color any recording pass that adds takes or lanes
```

REAPER's tooltip: *"When recording, automatically apply the same random color to
all takes created in the same recording pass."* This is the usual source of
custom take colours that nobody remembers setting — and because take colour
beats item colour, and take colours travel with a copy/paste, a stale one can
follow an item onto a track where it no longer means anything. Turn it off if
you want this tool's item colours to be the whole story.

## Diagnostics

Three read-mostly helpers, useful when a colour is not what you expected:

| Script | What it tells you |
|---|---|
| `MXM_NameColorizer_WhyThisColour.lua` | Select a track or item: which rule claimed it, what the rules would set, whether anything is applying, and why an old colour survived |
| `MXM_NameColorizer_Dump.lua` | Every track, item, region and marker with its name, GUID and current colour |
| `MXM_NameColorizer_TakeColorProbe.lua` | Whether your REAPER displays take colours over item colours |
| `MXM_NameColorizer_MakeTestProject.lua` | Builds a scratch project covering the awkward cases, in a new tab |

## Known limitations

* Case-insensitive matching folds **ASCII only** — `(?i)` will not equate `Č`
  and `č`. Byte classes do accept non-ASCII, so `\w+` matches `Kytara_hlavní`.
* A pathological pattern (`(a+)+$` and friends) is cut off by a step budget
  rather than being allowed to hang REAPER. The rule is flagged in the GUI when
  this happens; simplify the pattern.
* On REAPER older than 7.62 the marker/region *clear* path is unavailable,
  because `SetProjectMarker4` reads colour 0 as "leave unchanged". Colouring
  still works. Colours are set on the **item**, not the take.
* **No rules for takes.** Take names in REAPER are auto-derived from the track
  (`$tracknumber-$track` by default) and are not updated when the track is
  renamed, so matching on them would mostly duplicate matching the track, using
  a staler copy of the same string. Genuine take colouring is per-instance and
  semantic ("this one is a keeper", "this is pass 3"), which REAPER already
  covers natively with recording-pass auto-colour and take ranking. A Takes tab
  would add little and would let rules on two tabs fight over the same object.
* **Takes are not coloured, they are cleared.** Colours are written to the
  **item**. A custom colour on a *take* can hide the item's colour entirely
  (which of the two is displayed is a REAPER preference), so whenever a colour
  is written to an item, every take on that item has its own colour reset. This
  is deliberate: without it the tool appears to do nothing on items whose takes
  carry colours, and because take colours travel with a copy/paste, a stale one
  follows an item onto a track it no longer belongs to.
  If you deliberately colour takes, do not use this tool on items.
  `MXM_NameColorizer_TakeColorProbe.lua` reports what your setup displays.
* **The master track is not supported.** REAPER does not honour a custom colour
  on it — not through this tool, and not through REAPER's own track-colour
  action — so the master is never scanned and never coloured. An earlier build
  offered a "master track" rule filter; a saved rule still using it is
  **disabled** on load (with the reason in its note) rather than silently losing
  the filter, which would have turned it into a rule matching every object.
* Don't run SWS Auto Color at the same time — both are live colour engines and
  will fight. The scripts warn if SWS's auto-colour is switched on.

## Not implemented

* No filter/search box over the rule list. It interacts badly with drag-to-reorder
  (the visible index stops matching the real one), and precedence *is* the list
  order, so hiding rows would hide the thing that matters most.

## Repository layout

```
NameColorizer/            everything ReaPack installs
  MXM_NameColorizer.lua   ReaPack manifest: metadata only, installs nothing
  MXM_NameColorizer_*.lua actions you add to REAPER's Action List
  lib/                    the engine; lib/gui/ is the only part that uses ImGui
dev/                      author-only probes, deliberately not shipped
tests/                    runs outside REAPER against a mocked API
docs/DECISIONS.md         why it is built this way, and what was tried first
docs/RESEARCH.md          verified external facts: SWS, ReaImGui, REAPER prefs
index.xml                 generated by reapack-index; never edit by hand
```

## Tests

`MXM_NameColorizer_RunTests.lua` runs from REAPER's Action List and prints a
summary to the ReaScript console. It touches no project state and never writes
your config.

The full suite runs outside REAPER:

```bash
brew install lua     # once
./tests/run.sh
```

That covers the engine, the action scripts end to end, the background loop, the
GUI logic and its drawing paths — against a mock REAPER and a stub ImGui — plus
a differential fuzz of the regex engine against Python's `re`. See
[tests/README.md](tests/README.md).
