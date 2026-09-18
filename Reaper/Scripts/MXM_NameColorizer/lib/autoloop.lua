--[[
  autoloop.lua -- the background engine behind the auto-apply toggle.

  Cost model, which is the whole design:

    * Idle (nothing changed): three API calls per tick. Nothing else runs.
    * A change: tracks are enumerated immediately, because renames almost always
      happen to a track and that is where the user is looking. They are only
      PLANNED when that enumeration differs from the last one. REAPER has a
      single project-wide change counter, so a fader move arrives looking
      exactly like a rename; comparing the enumeration is what tells them apart,
      and planning is the expensive half.
    * Items and markers are swept once the project has settled, and only when
      something says they need it: a change in how many there are, a track that
      really did change, a rule edit, or the slow safety net below.
    * That sweep is COMMITTED in time-budgeted chunks across subsequent ticks.
      Enumerating and planning happen once per sweep rather than per chunk, so
      gradients still see the whole list -- chunking splits the writing, not the
      thinking.

  The safety net exists because one edit is invisible to every cheap signal:
  renaming an item in place adds nothing, removes nothing and touches no track.
  So a sweep that was declined stays PENDING and runs anyway once
  `cold_interval` has passed -- from the idle path if need be, since the project
  need not change again for the rename to still be waiting. Setting the option
  to 0 declines nothing and sweeps on every change, which is what this did
  before the gate existed.

  Three things stop the loop from being obnoxious:

    * The project change counter is re-read AFTER writing, so our own edits do
      not trigger another sweep.
    * If an object's colour differs from what we last wrote while its name is
      unchanged, the user recoloured it by hand. It is marked as overridden and
      left alone until it is renamed. Without this the tool would revert every
      manual colour within a fifth of a second.
    * "What we last wrote" means exactly that. A write that failed, or one still
      sitting in the queue, is not remembered as ours -- otherwise the next
      sweep reads the difference as a hand-picked colour and quietly retires the
      object from the rules for good.
]]

local targets = require 'targets'
local apply   = require 'apply'
local colors  = require 'colors'
local config  = require 'config'

local M = {}

local DESC = 'Colorize by name (auto)'

local S = {
  last_tick = 0,
  proj      = nil,
  last_scc  = nil,
  prev_scc  = nil,
  cache     = {},      -- guid -> { name, applied, override }
  rev       = nil,
  cfg       = nil,
  cold      = nil,     -- { ops, i }
  snap_tracks  = nil,  -- the enumeration the last track sweep planned from
  snap_cold    = nil,  -- ditto for tracks-as-context + items + markers
  cold_counts  = nil,  -- { items, marks } as of the last cold sweep
  cold_at      = 0,    -- when that sweep ran
  cold_owed    = false,-- a track really changed; sweep at the next settle
  cold_pending = false,-- something changed we could not attribute; sweep on the timer
  force_cold   = true, -- the gate must not decline the next one
  rules_changed = false,-- rules were edited; waiting for a real object change
  stats     = { ticks = 0, sweeps = 0, writes = 0, skipped = 0, last_ms = 0 },
}

M.state = S

------------------------------------------------------------------ overrides
--- Update the cache for one entry and report whether we should leave it alone.
local function note_and_check_override(e)
  local c = S.cache[e.guid]
  if not c then
    c = { name = e.name, applied = nil, override = false }
    S.cache[e.guid] = c
    return false
  end

  if c.name ~= e.name then
    -- A rename is the user asking for the rules to decide again.
    c.name = e.name
    c.override = false
    return false
  end

  if not c.override and c.applied ~= nil then
    local cur = colors.from_native(e.color)
    if cur ~= c.applied then
      c.override = true          -- they picked their own colour; respect it
    end
  end

  return c.override
end

local function remember_applied(e, rgb)
  local c = S.cache[e.guid]
  if c then c.applied = rgb end
end

--- Record what actually landed. commit() sets `op.done` on every op it
--- attempted; anything it did not reach, or could not write, must not be
--- remembered as ours.
-- @param stop  one past the last op to consider (commit's next_index)
-- @return how many were remembered
local function remember_written(ops, from, stop)
  local n = 0
  for i = from, stop - 1 do
    local op = ops[i]
    if op.done then remember_applied(op.entry, op.rgb); n = n + 1 end
  end
  return n
end

--- Forget every override, so the rules take over again. Used by Apply Now.
--- `applied` has to go too: it is the value the override test compares against,
--- so leaving it in place would make the very next sweep look at the user's
--- colour, see it differs, and immediately set the flag again.
function M.clear_overrides()
  for _, c in pairs(S.cache) do
    c.override = false
    c.applied  = nil
  end
end

--- Drop cache entries for objects that are no longer in the project. Called
--- only from the cold sweep, the one pass that sees every object -- anywhere
--- else this would forget objects that are simply not in front of it. Without
--- it the cache grows for the life of the REAPER session.
local function prune_cache(entries)
  local live = {}
  for i = 1, #entries do live[entries[i].guid] = true end
  for guid in pairs(S.cache) do
    if not live[guid] then S.cache[guid] = nil end
  end
end

------------------------------------------------------------------ snapshots
--- Is this enumeration identical to the one the last sweep planned from?
---
--- REAPER offers one project-wide change counter, so "something changed" is all
--- the loop is ever told. This is what separates a rename from a fader move,
--- over exactly the fields plan() reads. Comparing element by element rather
--- than hashing keeps it exact -- no collisions to reason about -- and costs one
--- pass of cheap comparisons; the price is holding the previous list, which is
--- tables that were allocated anyway.
---
--- ORDER is part of the comparison: moving a track changes no name and no
--- colour, but it does change folder inheritance and where a gradient's runs
--- begin.
---
--- `context` is deliberately NOT compared. This module always enumerates with
--- the same options, so it is always nil as read; the cold sweep then sets it on
--- the very track entries it borrows from the hot pass, and comparing it would
--- report a difference on every tick following a cold sweep.
local function same_snapshot(prev, cur)
  if prev == nil then return false end
  local n = #cur
  if #prev ~= n then return false end
  for i = 1, n do
    local a, b = prev[i], cur[i]
    if a.guid         ~= b.guid
    or a.name         ~= b.name
    or a.color        ~= b.color
    or a.kind         ~= b.kind
    or a.folderdepth  ~= b.folderdepth
    or a.depth        ~= b.depth
    or a.spacer_above ~= b.spacer_above
    or a.take_color   ~= b.take_color
    or a.track_guid   ~= b.track_guid then
      return false
    end
  end
  return true
end

--- Take up a rule edit that has been waiting for something to happen.
---
--- Editing a rule changes the ANSWER, not the observation, so the snapshots
--- stay valid across it -- they describe what the project holds, which no rule
--- edit can alter. That is what keeps a click off the repaint path: selecting a
--- track, or clicking empty space in the arrange, moves REAPER's project state
--- counter without changing a single object, and the loop is told only that the
--- number moved. Dropping the snapshots on a rule edit meant the next such
--- click re-planned everything and repainted the project, which is exactly what
--- "editing rules does not repaint the project" promises it will not do.
---
--- What a rule edit does mean is that the next REAL object change has to
--- re-plan the WHOLE project rather than just the object that moved -- dropping
--- both snapshots at that moment is precisely that. Otherwise half the project
--- ends up on the old rules and half on the new.
local function activate_rules()
  S.rules_changed = false
  S.snap_tracks, S.snap_cold = nil, nil
  S.cold_owed, S.force_cold = true, true
end

--------------------------------------------------------------------- sweeps
--- Plan over `entries`, drop anything the user has overridden, commit the rest.
-- @return number of writes
local function sweep(entries, chunked)
  local cfg = S.cfg
  local ops, _, desired = apply.plan(entries, cfg.rules, cfg.options)

  -- An op means the object does NOT yet have the colour the rules want, so the
  -- desired value is not something we can claim to have written. Everything
  -- else already carries it, and recording that is what makes a later manual
  -- change detectable even on a sweep with nothing to write.
  local pending = {}
  for _, op in ipairs(ops) do pending[op.entry] = true end

  for i = 1, #entries do
    local e = entries[i]
    if not e.context then
      local overridden = note_and_check_override(e)
      if desired[i] ~= nil and not overridden and not pending[e] then
        remember_applied(e, desired[i])
      end
    end
  end

  local keep = {}
  for _, op in ipairs(ops) do
    local c = S.cache[op.entry.guid]
    if c and c.override then
      S.stats.skipped = S.stats.skipped + 1
    else
      keep[#keep + 1] = op
    end
  end

  if #keep == 0 then return 0 end

  if chunked then
    S.cold = { ops = keep, i = 1 }
    return 0
  end

  local written = apply.commit(keep, DESC, { no_undo = not cfg.options.auto_undo })
  remember_written(keep, 1, #keep + 1)
  S.stats.writes = S.stats.writes + written
  return written
end

--- Drain the pending cold ops within a wall-clock budget.
--- The budget is handed to commit(), which spends it on the writes themselves.
--- Measuring it around a loop that merely collected the ops into a batch --
--- which is what this used to do -- bought about fifteen thousand iterations per
--- 4 ms, so the entire queue went out in one tick and nothing was ever chunked.
local function drain_cold(budget_s)
  local cold = S.cold
  if not cold then return 0 end

  local from = cold.i
  local _, _, nexti = apply.commit(cold.ops, DESC, {
    no_undo  = not S.cfg.options.auto_undo,
    from     = from,
    deadline = reaper.time_precise() + budget_s,
  })

  local n = remember_written(cold.ops, from, nexti)
  cold.i = nexti
  S.stats.writes = S.stats.writes + n

  if cold.i > #cold.ops then S.cold = nil end
  return n
end

------------------------------------------------------------------ cold gate
local function cold_interval()
  return (S.cfg and S.cfg.options.cold_interval) or 5
end

--- Has enough time passed that a sweep we declined has to happen anyway?
--- 0 means no waiting at all: normally nothing is ever declined at that
--- setting, but a sweep already pending when it is turned down to 0 must not be
--- left waiting on a timer that will never fire.
local function cold_overdue()
  local iv = cold_interval()
  if iv <= 0 then return true end
  return (reaper.time_precise() - S.cold_at) >= iv
end

--- Is a full items-and-markers sweep worth its cost right now?
--- Everything here is O(1) except the track comparison, which the hot pass has
--- already done.
local function cold_due(proj)
  if cold_interval() <= 0 then return true end       -- opted out of the gate
  if S.force_cold or S.cold_counts == nil then return true end
  -- A track change is an EDGE, and the settle it triggers takes two more ticks
  -- to arrive -- by which time the tracks match the snapshot again and the
  -- reason for sweeping has evaporated. So it is latched when it is seen, and
  -- only run_cold clears it. Counts need no latch: they are compared against
  -- the last cold sweep, not the last tick.
  if S.cold_owed then return true end                -- a rename can cascade
  local nit, nmk = targets.counts(proj)
  if nit ~= S.cold_counts.items or nmk ~= S.cold_counts.marks then return true end
  return cold_overdue()
end

--- Enumerate items and markers, plan them alongside the tracks as context, and
--- queue the writes.
--- @param tracks the list the caller has already enumerated. Reusing it rather
---        than reading every track a second time is safe because plan() never
---        looks at a CONTEXT entry's colour -- only at the colour the rules give
---        it -- so a reading taken before the hot pass wrote is not stale in any
---        way this depends on.
local function run_cold(proj, tracks)
  local rest = {}
  for i = 1, #tracks do
    tracks[i].context = true
    rest[i] = tracks[i]
  end
  for _, e in ipairs(targets.items(proj, {}))   do rest[#rest + 1] = e end
  for _, e in ipairs(targets.markers(proj, {})) do rest[#rest + 1] = e end

  if not same_snapshot(S.snap_cold, rest) then
    -- A pending rule edit can just as well be woken by an item as by a track,
    -- and then the tracks are the side that still needs re-planning.
    if S.rules_changed then activate_rules() end
    sweep(rest, true)
    S.snap_cold = rest
    prune_cache(rest)
  end

  local nit, nmk = targets.counts(proj)
  S.cold_counts  = { items = nit, marks = nmk }
  S.cold_at      = reaper.time_precise()
  S.cold_owed, S.cold_pending = false, false
  S.force_cold   = false
  S.stats.sweeps = S.stats.sweeps + 1
end

------------------------------------------------------------------ the tick
--- One iteration. Returns true if it did any real work.
function M.tick()
  S.stats.ticks = S.stats.ticks + 1

  local now = reaper.time_precise()
  local interval = (S.cfg and S.cfg.options.tick_interval) or 0.20
  if now - S.last_tick < interval then return false end
  S.last_tick = now

  -- A different project means every cached GUID is meaningless.
  local proj = reaper.EnumProjects(-1)
  if proj ~= S.proj then
    S.proj, S.cache, S.cold, S.last_scc, S.prev_scc = proj, {}, nil, nil, nil
    S.snap_tracks, S.snap_cold, S.cold_counts = nil, nil, nil
    S.cold_owed, S.cold_pending, S.force_cold = false, false, true
  end

  -- The GUI signals rule changes through ExtState; nothing else is shared.
  local rev = config.rev()
  if rev ~= S.rev or S.cfg == nil then
    S.rev  = rev
    S.cfg  = config.load()
    local had_pending = S.cold ~= nil
    S.cache, S.cold = {}, nil
    require('matcher').clear_cache()
    -- Held, not acted on. The snapshots survive: see activate_rules().
    S.rules_changed = true

    -- Editing rules does not repaint the project: that is what Apply Now is
    -- for, and it matches how every other edit in the window behaves.
    --
    -- One exception, and it is not a new repaint. If a cold sweep was still
    -- draining, its queued ops were just discarded -- they were planned
    -- against the old rules, so applying them would be wrong. But some of that
    -- sweep has already been written, so walking away now leaves the project
    -- genuinely half-applied: a few objects on the old rules and the rest
    -- untouched, with nothing scheduled to reconcile them. Finishing a sweep
    -- we had already started is not the same as starting one.
    if had_pending then
      S.last_scc, S.prev_scc = nil, nil
      S.force_cold = true          -- ...and the gate must not talk us out of it
    end
  end

  -- An Apply Now, from the window or the action, means "rules decide again".
  local orev = config.override_rev()
  if S.override_rev == nil then
    S.override_rev = orev
  elseif orev ~= S.override_rev then
    S.override_rev = orev
    M.clear_overrides()
    -- The rules decide again, so what this loop WOULD do has changed even
    -- though the project has not. Neither snapshot can stand for "nothing to
    -- do" any more, and the counter must not be allowed to keep us idle: the
    -- hand-picked colours we are being told to take back are, by definition,
    -- ones no project change is coming for.
    S.snap_tracks, S.snap_cold = nil, nil
    S.last_scc, S.prev_scc = nil, nil
    S.force_cold = true
  end

  -- Never fight the transport.
  if reaper.GetPlayState() & 4 ~= 0 then return false end

  local t0 = reaper.time_precise()
  local budget = (S.cfg.options.cold_budget_ms or 4) / 1000

  -- Finish any cold work first; it is already planned and paid for.
  if S.cold then
    drain_cold(budget)
    S.last_scc = reaper.GetProjectStateChangeCount(proj)
    S.stats.last_ms = (reaper.time_precise() - t0) * 1000
    return true
  end

  local scc = reaper.GetProjectStateChangeCount(proj)
  if scc == S.last_scc then
    S.prev_scc = scc
    -- A sweep we declined still owes an answer, and the edit it might be
    -- hiding -- an item renamed in place -- will not bump the counter again.
    -- So it is honoured from here, at most once per cold_interval.
    if S.cold_pending and cold_overdue() then
      run_cold(proj, targets.tracks(proj, {}))
      drain_cold(budget)
      S.last_scc = reaper.GetProjectStateChangeCount(proj)   -- after our writes
      S.stats.last_ms = (reaper.time_precise() - t0) * 1000
      return true
    end
    return false                                    -- idle: three API calls
  end

  -- Hot: tracks every time something changed. Few objects, and it is where
  -- renames happen, so this is what makes the tool feel immediate. The
  -- enumeration is unavoidable -- a rename is only visible by reading names --
  -- but planning is skipped when it produced this very list last time.
  local tracks = targets.tracks(proj, {})
  if not same_snapshot(S.snap_tracks, tracks) then
    if S.rules_changed then activate_rules() end
    sweep(tracks, false)
    S.snap_tracks = tracks
    S.cold_owed = true          -- a track rule can cascade onto its items
  end

  -- Cold: only once the project has stopped changing, so a drag or a burst of
  -- edits does not make us re-enumerate thousands of items over and over.
  if scc == S.prev_scc then
    if cold_due(proj) then
      run_cold(proj, tracks)
      drain_cold(budget)
    else
      S.cold_pending = true
    end
    S.last_scc = reaper.GetProjectStateChangeCount(proj)   -- after our writes
  else
    -- Still settling; re-read so our own track writes do not count as a change.
    S.last_scc = nil
    S.prev_scc = scc
  end

  S.stats.last_ms = (reaper.time_precise() - t0) * 1000
  return true
end

function M.reset()
  S.cache, S.cold, S.cfg, S.rev, S.override_rev = {}, nil, nil, nil, nil
  S.last_scc, S.prev_scc, S.proj = nil, nil, nil
  S.snap_tracks, S.snap_cold, S.cold_counts = nil, nil, nil
  S.cold_at, S.cold_owed, S.cold_pending, S.force_cold = 0, false, false, true
  S.rules_changed = false
  S.stats = { ticks = 0, sweeps = 0, writes = 0, skipped = 0, last_ms = 0 }
end

return M
