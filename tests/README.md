# Tests

Everything here runs **outside REAPER**, against a mocked API. Nothing touches a
project or your rule file; all scratch output goes to `tests/.tmp`.

```bash
brew install lua      # once; 5.4 or newer
./tests/run.sh
```

Expect `ALL GREEN`. The runner's exit status is meaningful, so it drops straight
into CI or a pre-commit hook.

## What each suite covers

| Suite | Runs | Covers |
|---|---|---|
| `MB_NameColorizer_RunTests.lua` (repo root) | in REAPER **and** standalone | regex engine, matcher, predicates, colours, JSON, rules, config, the whole `apply` decision layer |
| `integration.lua` | mock REAPER | the real action scripts end to end — Apply, Clear, selection scope, folder policies, take-colour masking, the old-REAPER marker fallback |
| `autoloop.lua` | mock REAPER | the background engine: idle cost, renames, the "don't fight a hand-picked colour" rule, cache invalidation, recording pause |
| `gui.lua` | mock REAPER | `gui/app.lua` — config load/save debounce, undo stack, preview tallies, the name tester |
| `render.lua` | mock REAPER + stub ImGui | renders real frames: every drawing path executes, style stack balances, tabs, preview bucketing, theme behaviour |
| `fuzz_gen.py` + `fuzz_run.lua` | standalone | differential fuzz of the regex engine against Python's `re`, ~4000 random patterns per seed |

## The two fakes

**`mockreaper.lua`** models the awkward parts of the API faithfully, because
those are where the bugs live: `P_NAME` returns `false` on the master track,
media items carry no name (only their active take does), `SetProjectMarker4`
treats colour 0 as *leave unchanged* so it cannot clear, and the project change
counter ticks on **our own** writes — which is what makes the auto-loop's
self-retrigger guard testable.

Mock time only moves when a test moves it, which meant the auto-loop's
wall-clock budget could never expire and its **chunking was never exercised** —
the interrupted-cold-sweep bug lived behind that gap. Pass `tick_cost` to
`mock.install` to make every `time_precise` reading creep forward, and the
chunking becomes real.

**`mockimgui.lua`** is a no-op ImGui that lets the real drawing code run. It
cannot tell us the window *looks* right, but it proves every path executes, no
call is misspelled, and edits actually reach `app.mark_dirty()`. Constants come
back as distinct bit values so code that ORs flags together produces genuinely
different results.

## Why the fuzzer exists

The regex engine is hand-written and is the one component where a subtle wrong
answer would be invisible. Python's `re` has the same leftmost-first
backtracking semantics, so generated patterns can be compared directly. The
generator sticks to a syntax subset where the two are meant to agree exactly,
and to ASCII, since Python's `\w` is Unicode-aware and ours is byte-based.

Patterns that exhaust the step budget are reported, not counted as
disagreements — giving up is the correct behaviour there.
