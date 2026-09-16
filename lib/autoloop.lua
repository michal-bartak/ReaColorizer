--[[
  autoloop.lua -- the background engine behind the auto-apply toggle.

  Cost model, which is the whole design:

    * Idle (nothing changed): three API calls per tick. Nothing else runs.
    * A change: tracks are swept immediately, because renames almost always
      happen to a track and that is where the user is looking.
    * Items and markers are swept once the project has settled for a tick, then
      COMMITTED in time-budgeted chunks across subsequent ticks. Enumerating and
      planning happen once per sweep rather than per chunk, so gradients still
      see the whole list -- chunking splits the writing, not the thinking.

  Two things stop the loop from being obnoxious:

    * The project change counter is re-read AFTER writing, so our own edits do
      not trigger another sweep.
    * If an object's colour differs from what we last wrote while its name is
      unchanged, the user recoloured it by hand. It is marked as overridden and
      left alone until it is renamed. Without this the tool would revert every
      manual colour within a fifth of a second.
]]

local targets = require 'targets'
local apply   = require 'apply'
local colors  = require 'colors'
local config  = require 'config'

local M = {}

local S = {
  last_tick = 0,
  proj      = nil,
  last_scc  = nil,
  prev_scc  = nil,
  cache     = {},      -- guid -> { name, applied, override }
  rev       = nil,
  cfg       = nil,
  cold      = nil,     -- { ops, i }
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

--------------------------------------------------------------------- sweeps
--- Plan over `entries`, drop anything the user has overridden, commit the rest.
-- @return number of writes
local function sweep(entries, chunked)
  local cfg = S.cfg
  local ops, _, desired = apply.plan(entries, cfg.rules, cfg.options)

  -- Record what each object is *supposed* to be, so a later manual change is
  -- detectable even when this sweep had nothing to write.
  for i = 1, #entries do
    local e = entries[i]
    if not e.context then
      local overridden = note_and_check_override(e)
      if desired[i] ~= nil and not overridden then
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

  local written = apply.commit(keep, 'Colorize by name (auto)', { no_undo = not S.cfg.options.auto_undo })
  for _, op in ipairs(keep) do remember_applied(op.entry, op.rgb) end
  S.stats.writes = S.stats.writes + written
  return written
end

--- Drain the pending cold ops within a wall-clock budget.
local function drain_cold(budget_s)
  local cold = S.cold
  if not cold then return 0 end

  local t0 = reaper.time_precise()
  local batch = {}
  while cold.i <= #cold.ops do
    batch[#batch + 1] = cold.ops[cold.i]
    cold.i = cold.i + 1
    if reaper.time_precise() - t0 > budget_s then break end
  end

  if #batch > 0 then
    apply.commit(batch, 'Colorize by name (auto)', { no_undo = not S.cfg.options.auto_undo })
    for _, op in ipairs(batch) do remember_applied(op.entry, op.rgb) end
    S.stats.writes = S.stats.writes + #batch
  end

  if cold.i > #cold.ops then S.cold = nil end
  return #batch
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
  end

  -- The GUI signals rule changes through ExtState; nothing else is shared.
  local rev = config.rev()
  if rev ~= S.rev or S.cfg == nil then
    S.rev  = rev
    S.cfg  = config.load()
    local had_pending = S.cold ~= nil
    S.cache, S.cold = {}, nil
    require('matcher').clear_cache()

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
    if had_pending then S.last_scc, S.prev_scc = nil, nil end
  end

  -- An Apply Now, from the window or the action, means "rules decide again".
  local orev = config.override_rev()
  if S.override_rev == nil then
    S.override_rev = orev
  elseif orev ~= S.override_rev then
    S.override_rev = orev
    M.clear_overrides()
  end

  -- Never fight the transport.
  if reaper.GetPlayState() & 4 ~= 0 then return false end

  local t0 = reaper.time_precise()

  -- Finish any cold work first; it is already planned and paid for.
  if S.cold then
    drain_cold((S.cfg.options.cold_budget_ms or 4) / 1000)
    S.last_scc = reaper.GetProjectStateChangeCount(proj)
    S.stats.last_ms = (reaper.time_precise() - t0) * 1000
    return true
  end

  local scc = reaper.GetProjectStateChangeCount(proj)
  if scc == S.last_scc then
    S.prev_scc = scc
    return false                                    -- idle: three API calls
  end

  -- Hot: tracks every time something changed. Few objects, and it is where
  -- renames happen, so this is what makes the tool feel immediate.
  local tracks = targets.tracks(proj, {})
  sweep(tracks, false)

  -- Cold: only once the project has stopped changing, so a drag or a burst of
  -- edits does not make us re-enumerate thousands of items over and over.
  if scc == S.prev_scc then
    -- Tracks go in as CONTEXT: not written to here (the hot pass already did
    -- them) but needed so folder inheritance and the track->item cascade can
    -- be worked out for the items in this sweep.
    local rest = {}
    for _, e in ipairs(targets.tracks(proj, {})) do
      e.context = true
      rest[#rest + 1] = e
    end
    for _, e in ipairs(targets.items(proj, {})) do rest[#rest + 1] = e end
    for _, e in ipairs(targets.markers(proj))   do rest[#rest + 1] = e end
    sweep(rest, true)
    drain_cold((S.cfg.options.cold_budget_ms or 4) / 1000)
    S.last_scc = reaper.GetProjectStateChangeCount(proj)   -- after our writes
    S.stats.sweeps = S.stats.sweeps + 1
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
  S.stats = { ticks = 0, sweeps = 0, writes = 0, skipped = 0, last_ms = 0 }
end

return M
