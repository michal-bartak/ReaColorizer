--[[
  apply.lua -- plan / prune / commit.

  Every entry point shares this pipeline, including the GUI's live preview,
  which is just plan() with no commit. Keeping planning pure (it reads entry
  tables and writes nothing) is what makes the preview honest: what it shows is
  literally what Apply would do.

    plan(entries, rules, options) -> ops     no REAPER writes
    commit(ops, desc, options)               the only place that writes

  plan() already drops no-ops, so an unchanged project produces zero ops, which
  in turn means no writes, no undo point, and no project-dirty flag. That is the
  precondition for the auto-apply loop being cheap.
]]

local matcher    = require 'matcher'
local predicates = require 'predicates'
local colors     = require 'colors'
local targets    = require 'targets'

local M = {}

-- reaper_plugin.h UNDO_STATE_* bits; not exposed as Lua symbols.
local UNDO_TRACKCFG, UNDO_ITEMS, UNDO_MISCCFG = 1, 4, 8

local KINDS = { 'track', 'item', 'region', 'marker' }

local KIND_UNDO = {
  track = UNDO_TRACKCFG, item = UNDO_ITEMS,
  region = UNDO_MISCCFG, marker = UNDO_MISCCFG,
}

------------------------------------------------------------------- resolving
--- First enabled rule in `list` whose filter passes and whose pattern matches.
--- `list` is the rule list for the entry's own kind, so there is no target
--- check to do: a rule in the track list only ever sees tracks.
local function resolve(entry, list)
  for i = 1, #list do
    local r = list[i]
    if r.enabled and predicates.test(r.only, entry.kind, entry) then
      local hit, why = matcher.test(r, entry.name)
      if why == 'budget' then r._timeouts = (r._timeouts or 0) + 1 end
      if r.invert then hit = not hit end
      if hit then return r, i end
    end
  end
  return nil
end

M.resolve = resolve

--- Map each track entry to the innermost folder containing it; 0 = not in one.
--- A folder PARENT belongs to the folder it opens, together with its children,
--- which is what "group by folder" means when you look at the track panel.
---
--- This mirrors the propagation stack in pass 3 exactly, multi-level close
--- (folderdepth can be -2) included, so the two can never disagree about where
--- a folder ends.
local function folder_groups(entries)
  local fg, stack, next_id = {}, {}, 0
  for i = 1, #entries do
    local e = entries[i]
    if e.kind == 'track' then
      local fd = e.folderdepth or 0
      if fd >= 1 then
        next_id = next_id + 1
        fg[i] = next_id
        for _ = 1, fd do stack[#stack + 1] = next_id end
      else
        fg[i] = stack[#stack] or 0
        if fd < 0 then
          for _ = 1, -fd do
            if #stack == 0 then break end
            stack[#stack] = nil
          end
        end
      end
    end
  end
  return fg
end

M.folder_groups = folder_groups

local function prepare_all(rules)
  for _, kind in ipairs(KINDS) do
    local list = rules[kind] or {}
    for _, r in ipairs(list) do r._timeouts = nil end
    matcher.prepare(list)
  end
end

M.prepare_all = prepare_all

---------------------------------------------------------------------- plan
--- Work out what every entry's colour should be.
--
-- Order of resolution:
--   1. each object against the rule list for its OWN kind, first match wins
--   2. gradients, over each rule's own matches
--   3. folder colours flow down to child tracks (propagate_folders)
--   4. track colours flow onto the ITEMS sitting on them, for track rules with
--      "also colour items" -- but only where no item rule already claimed them,
--      so an item rule always overrides its track
--
-- Entries flagged `context = true` take part in steps 3 and 4 but are never
-- written to. That is how "apply to selection" still gets folder inheritance
-- and track cascade right: the unselected parent tracks are present as context.
--
-- @return ops, stats, desired, winner
function M.plan(entries, rules, options)
  options = options or {}
  rules = rules or {}
  local policy = options.propagate_folders or 'fill_unmatched'

  -- tolerate the old single boolean as well as the per-kind table
  local clear_unmatched = {}
  do
    local cu = options.clear_unmatched
    for _, k in ipairs(KINDS) do
      clear_unmatched[k] = (type(cu) == 'table') and (cu[k] == true) or (cu == true)
    end
  end

  prepare_all(rules)

  -- 1. winner per entry, plus each entry's rank within its gradient group
  --    (a gradient needs the group size before any colour can be chosen)
  --
  -- A group is a rule's matches that belong together. `gradient_scope` decides
  -- what separates one group from the next: nothing ('all'), an object the rule
  -- does not win ('run'), a folder edge ('folder'), or either ('both').

  local needs_folders = false
  for _, r in ipairs(rules.track or {}) do
    if r.enabled and r.color2 and
       (r.gradient_scope == 'folder' or r.gradient_scope == 'both') then
      needs_folders = true
      break
    end
  end
  local fg = needs_folders and folder_groups(entries) or nil

  local winner, rank, groupsize, gid = {}, {}, {}, {}
  local groups = {}   -- rule id -> { [group id] = count }. Nested rather than a
                      -- concatenated string key: this loop runs over every
                      -- track on every auto-loop tick, and per-entry string
                      -- garbage there is not free.

  -- All per KIND: markers and regions are interleaved by targets.markers, so a
  -- marker must not split a run of regions.
  local last_rule, last_track, last_fold = {}, {}, {}
  local run_seq, both_seq = {}, {}
  local nrun, nboth = 0, 0
  local matched, scanned = 0, 0

  for i = 1, #entries do
    local e = entries[i]
    local k = e.kind
    if not e.context then scanned = scanned + 1 end
    local r = resolve(e, rules[k] or {})

    -- Run bookkeeping happens for EVERY entry, won or not -- an entry this rule
    -- does not win is precisely what ends a run. Context entries take part in
    -- full: targets.tracks returns every track under selected_only and flags
    -- the unselected ones as context, so if grouping skipped them then
    -- "apply to selection" would give different colours from "apply all" for
    -- the very same tracks.
    local fold = (fg and fg[i]) or 0
    local gap  = (r == nil) or (last_rule[k] ~= r.id)
              -- items are enumerated per track, so without this a run would
              -- ramp straight across a track boundary
              or (k == 'item' and last_track[k] ~= e.track_guid)

    if gap then nrun = nrun + 1; run_seq[k] = nrun end
    if gap or last_fold[k] ~= fold then nboth = nboth + 1; both_seq[k] = nboth end

    last_rule[k]  = r and r.id or nil
    last_track[k] = (k == 'item') and e.track_guid or nil
    last_fold[k]  = fold

    if r then
      if not e.context then matched = matched + 1 end
      winner[i] = r

      local scope = r.color2 and r.gradient_scope or 'all'
      local g = 0
      if     scope == 'run'    then g = run_seq[k]
      elseif scope == 'folder' then g = fold
      elseif scope == 'both'   then g = both_seq[k] end
      gid[i] = g

      local gg = groups[r.id]
      if not gg then gg = {}; groups[r.id] = gg end
      local n = (gg[g] or 0) + 1
      gg[g] = n
      rank[i] = n
    end
  end

  -- where each match sits in its gradient, for the "why is it this colour?" report
  local grad = {}
  for i = 1, #entries do
    local r = winner[i]
    if r then
      groupsize[i] = groups[r.id][gid[i]]
      if r.color2 then
        grad[i] = { rank = rank[i], size = groupsize[i], group = gid[i] }
      end
    end
  end

  -- 2. colours
  local desired = {}
  for i = 1, #entries do
    local r = winner[i]
    if r then
      if r.color2 then
        desired[i] = colors.gradient(r.color, r.color2, rank[i], groupsize[i])
      else
        desired[i] = r.color
      end
    end
  end

  -- 3. folder propagation, carrying the "also colour items" flag with the
  --    colour so items under a cascading folder inherit too
  local cascade = {}
  if policy ~= 'off' then
    local stack = {}
    for i = 1, #entries do
      local e = entries[i]
      if e.kind == 'track' then
        local own_c = desired[i]
        local own_x = (winner[i] and winner[i].cascade_items) == true
        local top   = stack[#stack]
        local inh_c = top and top.color or nil
        local inh_x = top and top.cascade or false

        local fc, fx
        if policy == 'force' and inh_c ~= nil then
          fc, fx = inh_c, inh_x
        elseif own_c ~= nil then
          fc, fx = own_c, own_x
        else
          fc, fx = inh_c, inh_x
        end

        desired[i], cascade[i] = fc, fx

        local fd = e.folderdepth or 0
        if fd >= 1 then
          for _ = 1, fd do
            stack[#stack + 1] = { color = fc, cascade = fx }
          end
        elseif fd < 0 then
          for _ = 1, -fd do
            if #stack == 0 then break end
            stack[#stack] = nil
          end
        end
      end
    end
  else
    for i = 1, #entries do
      if entries[i].kind == 'track' then
        cascade[i] = (winner[i] and winner[i].cascade_items) == true
      end
    end
  end

  -- 4. track colour -> its items, where the track rule asked for it and no
  --    item rule already claimed the item
  local tcolor, tcascade = {}, {}
  for i = 1, #entries do
    local e = entries[i]
    if e.kind == 'track' and e.guid then
      tcolor[e.guid], tcascade[e.guid] = desired[i], cascade[i]
    end
  end

  local from_track = {}
  for i = 1, #entries do
    local e = entries[i]
    if e.kind == 'item' and desired[i] == nil and e.track_guid then
      if tcascade[e.track_guid] and tcolor[e.track_guid] ~= nil then
        desired[i] = tcolor[e.track_guid]
        from_track[i] = true
      end
    end
  end

  -- 5. ops, already pruned of no-ops
  local ops = {}
  local cleared, unchanged = 0, 0

  for i = 1, #entries do
    local e = entries[i]
    if not e.context then
      local want = desired[i]
      local cur  = colors.from_native(e.color)

      -- A take colour can hide the item colour, so an item is only "already
      -- right" when nothing is masking it.
      local masked = (e.kind == 'item' and e.take_color == true)

      if want ~= nil then
        if cur ~= want or masked then
          ops[#ops + 1] = { entry = e, rgb = want, cur = cur, rule = winner[i],
                            from_track = from_track[i] }
        else
          unchanged = unchanged + 1
        end
      elseif clear_unmatched[e.kind] and (cur ~= nil or masked) then
        ops[#ops + 1] = { entry = e, rgb = nil, cur = cur, clear = true }
        cleared = cleared + 1
      end
    end
  end

  local stats = {
    scanned = scanned, matched = matched, unchanged = unchanged,
    writes = #ops, cleared = cleared,
  }

  -- `desired`, `winner`, `from_track` and `grad` are parallel to `entries`. The auto
  -- loop needs `desired` to tell "the user recoloured this" from "we set it";
  -- the GUI preview needs all three so it can show what Apply will ACTUALLY do
  -- rather than re-deriving a guess.
  return ops, stats, desired, winner, from_track, grad
end

--- Per-rule match counts under true first-match-wins, plus how many objects
--- each rule WOULD have matched had an earlier rule not taken them. The
--- "shadowed" number is what explains most "why isn't my rule working".
function M.tally(entries, rules)
  prepare_all(rules)
  local won, shadowed = {}, {}
  for _, kind in ipairs(KINDS) do
    for _, r in ipairs(rules[kind] or {}) do won[r.id], shadowed[r.id] = 0, 0 end
  end

  for i = 1, #entries do
    local e = entries[i]
    if not e.context then
      local taken = false
      for _, r in ipairs(rules[e.kind] or {}) do
        if r.enabled and predicates.test(r.only, e.kind, e) then
          local hit = matcher.test(r, e.name)
          if r.invert then hit = not hit end
          if hit then
            if taken then shadowed[r.id] = shadowed[r.id] + 1
            else won[r.id] = won[r.id] + 1; taken = true end
          end
        end
      end
    end
  end
  return won, shadowed
end

--- Plan a reset to default colours.
-- @param mode 'matched' -- only objects the current rules claim (the closest
--                          honest answer to "things this tool coloured")
--             'all'     -- every object that has any custom colour
-- The 'selected' scope is expressed by passing only selected entries.
function M.plan_clear(entries, rules, mode, options)
  -- For 'matched', ask the real pipeline what it would claim rather than
  -- re-resolving here. That matters for items coloured by a track rule's
  -- cascade: no ITEM rule matches them, but the rules did put that colour
  -- there, so releasing them is exactly what the user means.
  local claimed
  if mode == 'matched' then
    local _, _, desired = M.plan(entries, rules or {}, options or {})
    claimed = desired
  end

  local ops = {}
  for i = 1, #entries do
    local e   = entries[i]
    local cur = (not e.context) and colors.from_native(e.color) or nil
    local masked = (not e.context) and e.kind == 'item' and e.take_color == true
    if cur ~= nil or masked then            -- nothing to clear on a default colour
      local take = (mode ~= 'matched') or (claimed[i] ~= nil)
      if take then
        ops[#ops + 1] = { entry = e, rgb = nil, cur = cur, clear = true }
      end
    end
  end
  return ops
end

-------------------------------------------------------------------- commit
--- Write the planned ops. The ONLY function in the project that changes colours.
-- @param options { no_undo = bool }   no_undo is for the auto loop, which must
--                not add an undo point every time a track is renamed.
-- @return written, failures
function M.commit(ops, desc, options)
  if #ops == 0 then return 0, {} end
  options = options or {}

  local big = #ops > 50
  if big then reaper.PreventUIRefresh(1) end
  if not options.no_undo then reaper.Undo_BeginBlock() end

  local mask, written, failures = 0, 0, {}
  for _, op in ipairs(ops) do
    local ok, err = targets.set(op.entry, op.rgb)
    if ok then
      written = written + 1
      mask = mask | (KIND_UNDO[op.entry.kind] or 0)
    elseif err then
      failures[#failures + 1] = err
    end
  end

  if not options.no_undo then
    reaper.Undo_EndBlock(desc or 'Colorize by name', mask)
  elseif written > 0 then
    reaper.MarkProjectDirty(0)
  end
  if big then reaper.PreventUIRefresh(-1) end

  if written > 0 then
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
  end

  return written, failures
end

--------------------------------------------------------------- convenience
--- Enumerate, plan and commit in one go.
-- @param scope { selected_only=bool, want_tracks=bool, want_items=bool,
--               want_markers=bool }
function M.run(proj, rules, options, scope, desc)
  scope = scope or {}
  local entries = targets.all(proj, scope)
  local ops, stats = M.plan(entries, rules, options)
  local written, failures = M.commit(ops, desc, options)
  stats.written = written
  stats.failures = failures
  return stats
end

return M
