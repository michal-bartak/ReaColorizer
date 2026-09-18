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

The window re-reads the project on a settle timer as well as on the change
counter. The counter alone is not a brake: dragging an item bumps it on every
frame, so the window was re-reading every name, GUID and colour in the project
at frame rate for as long as the mouse moved — while the auto-apply loop was
doing its own scanning alongside. The cost of the timer is that the preview can
sit a quarter of a second behind the project, which is below the threshold where
anyone reads it as staleness rather than as drawing.

## The pattern tester is a scratch pad, not a rule inspector

It used to run the SELECTED rule's pattern against a typed name, plus a button
that fetched the selected track's name. Both couplings were backwards: to try
an expression you first had to commit it to a rule, and the thing you most want
while designing a pattern is somewhere to get it wrong without touching your
rule set.

So the panel now owns its three inputs -- mode, pattern, name -- and reads
nothing from the selection or the project. Case folding is not offered: a
pattern being worked out is tried against a name you typed, and `(?i)` covers
the rare case for regex.

The rule-level advisory notes ("matches every track", "this gradient collapses
to one colour") moved out with it, to under the rule table, beside the rule
they are about.

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
* Tracks are swept every tick that changed anything; items and regions follow
  once the project has settled, and only when something says they need it (see
  below), in time-budgeted chunks.
* Apply Now clears the override marks through an ExtState counter — the loop
  lives in a separate Lua state and cannot be reached any other way. Clearing
  the flag is not enough: `applied` must be cleared too, or the next sweep
  re-detects the manual colour and sets it straight back. It must also drop both
  enumeration snapshots and reset the change counter: what the loop *would* do
  has changed while the project has not, and the hand-picked colours it is being
  told to take back are by definition ones no project change is coming for.
* **Only what was actually written is remembered as ours.** `applied` used to be
  recorded at plan time, so a write that failed — or one still queued when the
  rules changed — left the cache claiming a colour the object never had. The
  next sweep reads that difference as a hand-picked colour and retires the
  object from the rules permanently. `commit()` marks each op it attempted, and
  only those are recorded.
* **A write can outlive the object it was planned for.** Chunking means ops are
  committed a tick or more after they were planned, and the user can delete a
  track in between. Every write goes through `ValidatePtr2` first; a vanished
  object is skipped silently, because nothing failed — the plan was simply made
  before it was deleted.

## The loop cannot tell a fader move from a rename

`GetProjectStateChangeCount` is a single project-wide integer: *"returns an
integer that changes when the project state changes"*. There is no per-kind
counter and nothing that says what changed. So a fader move, an FX tweak and a
track rename all arrive identically, and the loop used to pay full price for
each — three full track enumerations, one full item enumeration and three plans
over every object in the project, for a fader.

Three things narrow that down, cheapest first.

**The enumeration is compared with the last one.** Reading names is the only way
to see a rename, so the enumeration itself cannot be skipped — but *planning* is
the expensive half, and it is skipped when the reading is identical to the one
the last sweep planned from. The comparison is element-by-element over the
fields `plan()` reads, rather than a hash: exact, no collisions to reason about,
and it costs one pass of cheap comparisons. Order is part of it, because moving
a track changes no name and no colour but does change folder inheritance and
where a gradient's runs begin. `context` is deliberately excluded — the loop
always enumerates with the same options, and the cold sweep sets that flag on
the very track entries it borrows.

**Items and regions are gated.** They outnumber tracks by orders of magnitude,
so the cold sweep runs only when: a track really changed, the item or marker
count changed (two O(1) calls), the rules changed, or `cold_interval` has
passed. A burst of mixing now costs one sweep per interval instead of one per
change.

**A track change has to be latched.** It is an edge, and the settle it triggers
arrives two ticks later — by which time the tracks match the snapshot again and
the reason for sweeping has evaporated, leaving a renamed track's items
uncascaded. So `cold_owed` is set when the change is seen and cleared only by
the sweep itself. Counts need no latch: they are compared against the last cold
sweep, not the last tick.

**The safety net is not optional.** One edit is invisible to every signal above:
renaming an item *in place* adds nothing, removes nothing and touches no track.
A declined sweep therefore stays pending and runs anyway once `cold_interval`
has passed — from the *idle* path if need be, because the project need not
change again for that rename to still be waiting. `cold_interval = 0` declines
nothing, which is exactly what this did before the gate existed.

Deliberately not used: `Undo_CanUndo2`, whose description string would say what
the last change was. Not every change makes an undo point, and the strings are
translatable through a LangPack.

## Matching the same name twice is free

The loop re-tests the same names against the same rules on every sweep, and a
project holds far fewer distinct names than objects — `01-Gtr L`, `02-Gtr L` and
so on collapse to one entry per rule. So a rule remembers its answers in `_memo`,
keyed by the name alone.

That key is only sound because the memo's lifetime is owned by one function.
`matcher.prepare()` drops it the moment the rule's compiled matcher changes, and
`compile()` returns the *same* object for an unchanged (mode, pattern, ci) — so
an ordinary sweep keeps the memo while an edited pattern loses it. Every rule
change goes through `clear_cache()`, which recompiles, so that path invalidates
too. Values are small integers rather than booleans so that "gave up on the step
budget" survives the cache: it still reads as no-match, and the GUI still badges
it.

Measured on 200 tracks / 4000 items / 100 regions with the starter rules: the
window's per-recompute cost (`tally` + `plan`) went from 15.3 ms to 2.9 ms.

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

One global JSON file at `<resource path>/MXM_AutoColor/config.json`, kept
**outside** `Scripts/` so reinstalling the scripts cannot clobber it. JSON
because patterns legitimately contain `| , = : [ #` and backslashes, so any
delimiter scheme needs escaping anyway. Encoded on a single line with sorted
keys: stable diffs, and safe to round-trip through ExtState, which documents
newlines as unsupported.

**Never serialise a live rule.** Rules carry runtime scratch (`_m`, `_err`,
`_timeouts`, `_memo`) once prepared, and the compiled matcher contains
character-class tables with integer keys, which is not encodable as a JSON
object. That silently
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
8. **The cold sweep's time budget measured the wrong loop.** It timed a loop
   that copied op references into a batch and then committed the batch
   unbudgeted — and 4 ms buys about fifteen thousand of those copies, so the
   entire queue went out in one tick and nothing was ever chunked. The budget
   now belongs to `commit()`, which spends it on the writes. **The mock hid
   this**: its clock advanced on every reading, so the test "a cold sweep really
   does queue work across ticks" passed for a reason that does not exist in
   REAPER. A mock that lies in the direction of the code being right is worse
   than no test, so it grew a `write_cost` that charges per write instead.
9. **`applied` was recorded before the write happened**, so a failed or
   discarded write left the cache holding a colour the object never had — which
   the next sweep read as the user's own choice and honoured for good.
10. **The cache grew for the life of the session.** Nothing dropped entries for
   deleted objects, and the position-based marker key added one per region
   moved. The cold sweep is the one pass that sees every object, so it prunes.
11. **A rule edit repainted the project on the next mouse click.** "Editing
   rules does not repaint the project" was true only until you clicked
   something: selection is project state, so a click on empty space moves the
   change counter, and the loop had thrown away everything it knew about the
   project the moment the rules were saved. The test that was supposed to pin
   this behaviour bumped the counter by hand and asserted the repaint, so it
   pinned the bug instead. It now asserts both halves: a bare counter bump
   changes nothing, a real object change takes the edit up everywhere.

## Editing rules does not repaint the project

Changing a rule's colour, pattern or options does **not** re-apply on its own,
even with the background loop running. Apply Now is the commit; the preview
shows what would happen in the meantime. This matches how every other edit in
the window behaves, so there is one rule to learn rather than two.

The loop's job is keeping the project in step with the *saved* rules as objects
change — not repainting while someone is still typing a pattern.

A rule change is **held**, not acted on. It drops the loop's cache and its
compiled matchers, but deliberately leaves the enumeration snapshots alone:
those describe what the *project* holds, and no rule edit can change that. The
edit is taken up by the first real object change — and taken up for the whole
project at once, so you never get some objects on the old rules and some on the
new.

Holding it that way is the difference between "does not repaint" and "repaints
the moment you touch anything". The loop's only trigger is
`GetProjectStateChangeCount`, and **selection is project state**: clicking empty
space in the arrange, or a track panel in the mixer, moves that counter without
changing a single object. Dropping the snapshots on a rule edit therefore meant
the very next click re-planned everything and repainted the project — which
reads as repainting at random, and is precisely what this section promises will
not happen. Reported from the field, and it had been true since the loop was
written. A rule edit invalidates the *answer*, not the *observation*.

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

## "The selection" is decided by focus, not by counting

A track selection and an item selection are independent in REAPER and can both
be live at once. Select a track, then click three items, and the track is still
selected -- it is a remainder, not an instruction. `Selection` and `Clear
selected objects` used to honour both, so the left-over track got recoloured.

REAPER resolves this for its own `...depending on focus` actions with the cursor
context, and `targets.selection_focus` does the same. Inventing a different rule
would make this tool behave unlike everything around it.

**Measured, not assumed** (`MXM_AutoColor_FocusProbe.lua`):

* `GetCursorContext()` is **useless from a script**. It reported `-1` (unknown)
  on every run, because the running action is not the arrange view.
  `GetCursorContext2(true)` -- "last valid" -- is the one that works, and it
  tracked clicks correctly across track panels and items.
* Running an action does not clear it, so reading it from a button in the GUI
  is sound.

**The counts are checked before the context, and the order matters.** The
context goes stale: the probe caught a run reporting `items` with zero items
selected. Consulting the context first would have coloured nothing at all.

An envelope context, or a build with no `GetCursorContext2`, decides nothing and
both selections are honoured -- the behaviour from before the context was
consulted. Guessing is worse than doing as you are told.

When the items win, tracks are still **enumerated** and merely flagged
`context`: folder inheritance and the track->item cascade need to see them.
Dropping them would change the colours the items get.

The status line names which it used (`Coloured 3 of 3 selected items.`), so a
wrong guess is visible immediately rather than discovered later.

### Regions and markers are on their own axis

They were left out of every selection action, on the mistaken belief that
REAPER exposes no selection state for them. It does: `B_UISEL` ("selected in
arrange view") on `GetRegionOrMarkerInfo_Value`. There is no `IsMarkerSelected`
and no `CountSelectedMarkers`, which is what made it look absent -- found by
reading the API table out of the REAPER binary, not from a guess.

They are **always honoured when selected**, never arbitrated. The cursor
context has no value for markers (0/1/2 are track panels, items, envelopes), so
a leftover marker selection genuinely cannot be told from a deliberate one. The
status line falls back to the neutral "objects" whenever a marker selection
joins a track or item one, rather than claiming a count it cannot stand behind.

Unselected markers are enumerated and flagged `context`, not skipped -- the same
guarantee tracks get. A gradient grouped into runs needs its neighbours, so
leaving them out would give a selected region a different colour from the one
Apply All gives it.

A build without the modern marker API cannot report selection, and there every
marker becomes context. Colouring all of them would be worse than colouring
none, and that build cannot clear marker colours anyway.

**A marker's identity is its GUID, not its position.** `EnumProjectMarkers3`
hands back no GUID, so the cache key was `index:position` — which made nudging a
region a *different object* as far as the loop was concerned. It forgot that the
colour had been picked by hand and painted over it, and leaked a cache entry per
move. `GetSetRegionOrMarkerInfo_String` exposes `"GUID"` (read-only) and that is
what a marker keeps across a move. The old key remains the fallback on a build
without it. The extra call per marker per scan is the obvious trade for the one
kind a project holds few enough of.
