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

## Gradients restart per group

`gradient_scope` is per rule (`all` / `run` / `folder` / `both`, default `run`),
because the setting is meaningless without `color2`, which is per rule.

Grouping is a group index folded into the key that pass 1 already counts
matches under. Three things it must get right:

* **Per kind.** `targets.markers` interleaves markers and regions, so a marker
  must not split a run of regions.
* **Same rule, not merely "matched".** A run is a stretch won by the *same*
  rule, so `String1, Bass, String2` is two groups.
* **Context entries take part in full.** `targets.tracks` returns every track
  under `selected_only`, flagging the unselected ones as context. If grouping
  skipped them, *apply to selection* would compute different colours from
  *apply all* for the very same tracks. This is a correctness invariant, not an
  optimisation, and it is pinned by a test.

Items additionally break on a change of track — they are enumerated per track,
so without it a run would ramp straight across a track boundary. Folder scope is
tracks only: nothing else has folder structure, and for items the ordering
inside a folder (track order, then item order) is not something anyone can
predict from the arrange view.

**A REAPER visual spacer ends a run.** Spacers are not objects, so they never
reach the entry list. They are a track attribute —
`I_SPACER : int * : 1=TCP track spacer above this track` — so the flag lives on
the track *below* the gap, at the cost of one extra `GetMediaTrackInfo_Value`
per track. Honoured automatically rather than given its own scope value:
inserting a spacer states the grouping in REAPER's own UI, which is a plainer
signal than an incidental gap in what a rule happens to match. `folder` scope
ignores it — that scope is structural and a spacer is visual. On a REAPER
without spacers the parameter reads 0, so no version guard is needed.

**Defaults differ by kind**, deliberately. Tracks and items default to `run`;
regions and markers default to `all`. A song's regions are interleaved —
`Verse, Chorus, Verse, Chorus` — so a rule matching one of them rarely wins two
in a row, and defaulting them to runs would leave every group with a single
member and the gradient invisible. Contiguous blocks are the norm for tracks and
the exception for regions, so the default follows the reality rather than
consistency for its own sake.

The folder container map mirrors the propagation stack in pass 3 exactly,
multi-level close included, so the two can never disagree about where a folder
ends. `groups` is a nested table rather than a concatenated string key: pass 1
runs over every track on every auto-loop tick, and per-entry string garbage
there is not free.

No config version bump. A missing `gradient_scope` defaults to `run`, and
because rule edits do not repaint the project, any change of appearance waits
for the next Apply — the same as editing a colour.

**Deliberately not built:** an "auto" mode that picks between run and folder by
inspecting the project. Colour would then depend on a global heuristic that
flips on a single structural edit, with nothing in the UI explaining why.

The real fix for gradient instability is a fixed denominator (a per-rule
`gradient_steps`, 0 = use the group size) so adding a member does not move the
existing ones. That is orthogonal to grouping and not done here.

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
7. **The test harness was silently dependent on the current directory** — it
   found the mocks through Lua's default `./?.lua`, so it only worked when
   invoked from inside `tests/`.

## Editing rules does not repaint the project

Changing a rule's colour, pattern or options does **not** re-apply on its own,
even with the background loop running. Apply Now is the commit; the preview
shows what would happen in the meantime. This matches how every other edit in
the window behaves, so there is one rule to learn rather than two.

The loop's job is keeping the project in step with the *saved* rules as objects
change — not repainting while someone is still typing a pattern.

A rule change does clear the loop's cache, so the next sweep re-evaluates
everything against the new rules. That is what stops a partly-applied project:
you never get some objects on the old rules and some on the new.

**One exception, and it is not a new repaint.** A cold sweep is chunked across
ticks. If a rule change lands while one is still draining, the queued ops are
discarded — they were planned against the old rules — but part of that sweep has
already been written. Walking away there leaves the project genuinely
half-applied, with nothing scheduled to reconcile it: the symptom is "it just
stops recolouring and never resumes". So when in-flight work is dropped, and
only then, the loop forces a fresh sweep. Finishing a sweep already started is
not the same as starting one.

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
