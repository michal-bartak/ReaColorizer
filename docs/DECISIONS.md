# Decisions

Why this is built the way it is. Kept because several of these look arbitrary
until you know what was tried first.

## Why build it at all

SWS Auto Color matches with `stristr` — case-insensitive **plain substring**,
two call sites in `Color/Autocolor.cpp`, no wildcard handling anywhere. It also
has **no item support at all** (`MediaItem` appears zero times in that file).
A [PR adding regex](https://github.com/reaper-oss/sws/pull/1291) was closed
unmerged in Feb 2025 over the macOS 10.5 deployment target and the risk of an
invalid pattern crashing REAPER at startup.

REAPER itself has nothing — zero hits for "auto color" across the 6.0 → 7.80
changelog. No ReaScript covers tracks + items + regions together.

See [RESEARCH.md](RESEARCH.md) for the full survey.

## The regex engine is hand-written

**PCRE is not available.** The only ReaScript binding (Mavriq Lua Batteries)
ships Lua 5.3 while REAPER 7 uses 5.4, and has an open, unanswered issue: *hard
crash when requiring a module on Apple Silicon*. Lua patterns can't express
alternation or `{n,m}`.

So: recursive-descent parser → flat instruction program → **iterative**
backtracking VM. Iterative rather than recursive so step-counting is one
decrement in one loop, with no Lua call-stack depth risk.

**The step budget is the load-bearing part.** This runs on REAPER's UI thread,
so a pathological pattern must never hang the DAW. `(a+)+$` and friends give up
after 20,000 steps and report `'budget'`, which the matcher treats as no-match
and the GUI flags with an amber badge. A wrong answer beats a beachballed DAW.
Supporting pieces: a `PROGRESS` opcode that fails zero-width loop iterations, a
compile-time cap on `{n,m}` expansion and program size, and a mandatory-literal
prefilter that gates the VM behind one C-level `string.find`.

Case folding happens **at compile time** — classes are 0–255 lookup tables, so
matching is one table index per byte and the subject is never lowercased.
Folding must happen *before* negation: `[^a-z]` under `(?i)` folded afterwards
re-admits exactly the characters the class excluded. That was a real bug.

## One rule list per object kind

v1 had a single ordered list where each rule carried track/item/region/marker
checkboxes. v2 has one list per kind, which:

* makes precedence per-kind, so reordering track rules cannot change which
  region wins;
* lets each tab offer only filters that mean something — folder filters exist on
  Tracks and nowhere else;
* removes the "targets nothing" state entirely.

Migration splits a multi-target rule into one rule per kind, preserving relative
order, with fresh ids for the copies.

## Two ways to make items follow their track, and they are not equal

| | mechanism | after copy/paste to another track |
|---|---|---|
| **also colour items** on a track rule | writes the track's colour onto the item | stale unless the destination rule also cascades |
| **reset unmatched items** | removes the item's colour so REAPER draws it from the track | correct instantly, cannot go stale |

An item with no custom colour is drawn by REAPER in its track's colour, live.
So the second is usually right, and the first is for when items should
deliberately differ. `clear_unmatched` is **per kind** for exactly this reason:
clearing unmatched items is desirable, clearing unmatched *tracks* would strip
every colour set by hand.

## Colours are written to the item, and takes are cleared

A custom colour on a **take** overrides the item's, depending on a REAPER
preference. Take colours also travel with a copy/paste, which is how a stale one
arrives on a track where it means nothing. So writing an item colour clears the
colour on **every** take of that item — not just the active one, or switching
takes brings the stale colour back.

Consequence: an item whose colour is already correct but is *masked* by a take
colour is not "up to date". Items carry a `take_color` flag from the scan so the
no-op pruning does not skip them.

## No rules for takes

Take names are auto-derived from the track (`$tracknumber-$track` by default)
and are **not** updated when the track is renamed — so they are a stale snapshot
of the track name, and matching them would mostly duplicate matching the track
using an older copy of the same string. Real take colouring is per-instance and
semantic ("this one is a keeper", "this is pass 3"), which REAPER already covers
with recording-pass auto-colour and take ranking.

## The master track is not supported

REAPER does not honour a custom colour on it — not through this tool and not
through REAPER's own track-colour action. An earlier build offered a "master
track" filter; a saved rule still using it is **disabled** on load rather than
silently losing the filter, because a master rule with an empty pattern would
otherwise become a rule matching *every* object.

## The preview is the plan

`apply.plan()` is pure: it reads entry tables and writes nothing. The GUI preview
is literally that function's output, so the two cannot tell different stories —
the usual failure mode for a tool with both a preview and a background worker.
It has drifted twice and both were caught by tests comparing preview colour
against what Apply wrote, object by object.

## The background loop must not be obnoxious

* **Never reverts a hand-picked colour.** If an object's colour differs from
  what we last wrote while its name is unchanged, the user chose it — leave it
  alone until the name changes or Apply Now is pressed. Without this the tool
  reverts every manual colour within 200 ms and is unusable.
* **No undo points.** An undo point per rename shreds the undo history, and
  colours are fully re-derivable. `MarkProjectDirty` only.
* **Writes nothing when nothing changed**, so the change counter does not tick
  and the loop does not retrigger itself. The counter is re-read *after*
  committing for the same reason.
* Tracks are swept every tick; items and regions follow once the project has
  settled, in time-budgeted chunks.
* Apply Now clears the override marks through an ExtState counter — the loop
  lives in a separate Lua state and cannot be reached any other way. Clearing
  the flag is not enough: `applied` must be cleared too, or the next sweep
  re-detects the manual colour and sets it straight back.

## Config

One global JSON file at `<resource path>/NameColorizer/config.json`, kept
**outside** `Scripts/` so reinstalling the scripts cannot clobber it. JSON
because patterns legitimately contain `| , = : [ #` and backslashes, so any
delimiter scheme needs escaping anyway. Encoded on a single line with sorted
keys: stable diffs, and safe to round-trip through ExtState, which documents
newlines as unsupported.

**Never serialise a live rule.** Rules carry runtime scratch (`_m`, `_err`,
`_timeouts`) once prepared, and the compiled matcher contains character-class
tables with integer keys, which is not encodable as a JSON object. That silently
broke every save after the first preview until `config.serializable()` existed.

## GUI constraints worth knowing

ReaImGui has effectively **one look, and it is dark** — no `StyleColorsLight`,
no `SetStyleColor`, and it does not follow REAPER's theme.

Things that cannot be done, each discovered the hard way:

* **Tables cannot be rounded**, and their border thickness is not adjustable.
  Only prominence, via `Col_TableBorderLight` / `Col_TableBorderStrong`.
* **`TableFlags_Resizable` forces `BordersInnerV` back on** (`TableFixFlags` in
  Dear ImGui). Resizable columns and no vertical grid lines are mutually
  exclusive, so the two travel together in the theme.
* **`Col_ModalWindowDimBg` cannot be controlled.** ImGui paints it during
  `Render()`, after every `PushStyleColor` has been popped, so it always uses
  the style default — which in the dark style is near-white and *brightens* the
  window. Dimming uses `StyleVar_Alpha` instead, which is global and consulted
  as each widget draws, so it reaches inside child windows. A draw-list rect
  does not: scrolling tables and `BeginChild` panels are separate child windows
  drawn afterwards.
* **Small caps are not achievable.** No font-variant, and no access to a font's
  baseline or ascent — ImGui lays items out by their tops, so mixing two sizes
  on one line can only ever approximate baseline alignment.
* `ColorEdit3` with `NoInputs` takes the **full item width**, so swatches need
  an explicit `SetNextItemWidth` to match square icon buttons.
* `DragDropFlags_SourceNoPreviewTooltip` makes anything drawn inside the source
  block land **inline in the window** instead of following the cursor.

DPI needs no work: ReaImGui reports logical units and rasterises at device
resolution. Every dimension is a multiple of `GetFontSize`. Multiplying by
`GetWindowDpiScale` (2.0 on Retina) would render everything double size.

## Bugs worth remembering

Each of these was silent, and each now has a test named after its failure mode.

1. **`[^a-z]` under `(?i)`** folded after negation, re-admitting the excluded
   characters.
2. **Saving stopped working after the first preview** — live rules carry
   unencodable runtime scratch.
3. **Rule-table edits were never saved and never refreshed the preview.**
   `draw()` computed a `changed` flag and returned it; the caller dropped it.
   Marking dirty now happens inside the module that owns the edits, because
   "return a flag and trust the caller" is what failed.
4. **The preview showed a rule's primary colour**, not the colour each object
   would actually get — gradients were wrong and folder-inherited tracks were
   missing entirely.
5. **Apply Now could not clear the background loop's override marks**, and the
   first fix cleared the flag but not `applied`, so the next sweep undid it.
6. **`clear_unmatched` became a table** and `WhyThisColour` reported it with
   `x and 'ON' or 'OFF'` — a table is always truthy, so it always said ON.
7. **Editing a rule did nothing while the background loop was running.** The
   config-change branch cleared the cache but left the project-change counter
   alone, so the idle gate returned immediately and no sweep happened until the
   project changed for some unrelated reason. The test that should have caught
   it was bumping the project itself.

## Manual colours and rule ownership

With *reset when unmatched* on for a kind, the rules own that kind: a colour set
by hand on an unmatched object is removed on the next sweep. That is deliberate
— it is what makes "items always follow their track" a guarantee rather than a
tendency. Turn the option off for that kind to keep manual colours, and use
Clear for one-off resets.

One asymmetry is worth knowing. The background loop's override rule ("do not
fight a colour the user picked") applies to objects a rule *matches*, so
hand-colouring a matched item survives until it is renamed or Apply Now is
pressed. It does not apply to unmatched objects under *reset when unmatched*,
because the loop records "we wrote nothing" rather than "we wrote default", so
there is no baseline to compare a later manual change against. Apply Now
overrules in both cases.
