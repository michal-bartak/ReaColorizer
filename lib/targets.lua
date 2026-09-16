--[[
  targets.lua -- the only module that knows how REAPER stores names and colours.

  Everything else works on plain entry tables:

    { kind    = 'track'|'item'|'region'|'marker',
      obj     = the REAPER object (or marker index bundle),
      name    = string,          -- '' when unnamed
      guid    = string,          -- stable identity for the auto-loop cache
      color   = number,          -- raw I_CUSTOMCOLOR reading, un-normalised
      -- tracks only:
      folderdepth = number, depth = number, idx = number,
      spacer_above = boolean,    -- a REAPER visual spacer sits above it
      -- items only:
      track_guid = string,       -- which track it sits on, for the cascade
      -- any kind:
      context = true }           -- present for context only; never written to

  Marker/region note: reading uses EnumProjectMarkers3 and writing uses
  SetProjectMarker4. Both are long-stable. The 7.62+ GetRegionOrMarker family is
  used for exactly one thing -- CLEARING a colour -- because SetProjectMarker4
  treats colour 0 as "leave unchanged" and so physically cannot clear. That call
  is guarded by APIExists with a graceful fallback.
]]

local colors = require 'colors'

local M = {}

-- Read by marker selection, marker clearing and the marker writes, all of
-- which sit in different sections of this file -- so it lives up here.
local HAS_MODERN_MARKER_API = nil
local function modern_marker_api()
  if HAS_MODERN_MARKER_API == nil then
    HAS_MODERN_MARKER_API = reaper.APIExists('GetRegionOrMarker')
                        and reaper.APIExists('SetRegionOrMarkerInfo_Value')
  end
  return HAS_MODERN_MARKER_API
end


local floor = math.floor

------------------------------------------------------------------- tracks
--- Every track, in project order, with folder depth tracked as we go.
--- ALL tracks are always returned. Under `selected_only` the unselected ones
--- come back flagged `context = true`: the apply pipeline uses them for folder
--- inheritance and track->item cascade but never writes to them. Without that,
--- "apply to selection" inside a folder would get the inherited colour wrong.
-- @param opts { selected_only = bool }
-- The master track is deliberately NOT enumerated: REAPER does not honour a
-- custom colour on it, so colouring it is not something this tool can do.
--- Which selection did the user actually mean?
---
--- A track selection and an item selection can both be live at once -- select
--- a track, then click some items, and the track selection just sits there.
--- REAPER answers this for its own "...depending on focus" actions with the
--- cursor context, so do the same rather than inventing a rule.
---
--- Measured, not assumed (MB_NameColorizer_FocusProbe.lua): GetCursorContext()
--- is useless from a script -- it reported "unknown" (-1) on every single run,
--- because the running action is not the arrange view. GetCursorContext2 with
--- want_last_valid keeps the last real answer and tracked clicks correctly.
---
--- The counts are checked BEFORE the context, and that ordering matters: the
--- context goes stale. The probe caught a run reading "items" with zero items
--- selected, which would otherwise have coloured nothing at all.
---
--- Markers and regions are a separate axis and are always honoured when
--- selected: the cursor context has no value for them (0/1/2 are track panels,
--- items and envelopes), so there is nothing to arbitrate with. A marker
--- selection left over from earlier cannot be told from a deliberate one.
---
--- How many markers/regions are selected. There is no CountSelectedMarkers,
--- so this enumerates; it runs on a button press, never in the auto loop.
function M.count_selected_markers(proj)
  if not modern_marker_api() then return 0 end      -- unknowable on old builds
  local n, i = 0, 0
  while true do
    local rv = reaper.EnumProjectMarkers3(proj, i)
    if rv == 0 then break end
    local ok, sel = pcall(function()
      local mk = reaper.GetRegionOrMarker(proj, i, '')
      return mk ~= nil and reaper.GetRegionOrMarkerInfo_Value(proj, mk, 'B_UISEL') ~= 0
    end)
    if ok and sel then n = n + 1 end
    i = i + 1
  end
  return n
end

--- @return 'tracks'|'items'|'both'|nil, n_tracks, n_items, n_markers
function M.selection_focus(proj)
  local ntr = reaper.CountSelectedTracks(proj)
  local nit = reaper.CountSelectedMediaItems(proj)
  local nmk = M.count_selected_markers(proj)

  if ntr == 0 and nit == 0 then return nil,     ntr, nit, nmk end
  if nit == 0              then return 'tracks', ntr, nit, nmk end
  if ntr == 0              then return 'items',  ntr, nit, nmk end

  local c
  if reaper.APIExists('GetCursorContext2') then
    c = reaper.GetCursorContext2(true)
  end
  if c == 1 then return 'items',  ntr, nit, nmk end
  if c == 0 then return 'tracks', ntr, nit, nmk end

  -- Envelopes, or no answer at all: honour both, which is what this did before
  -- the context was consulted. Guessing is worse than doing as you are told.
  return 'both', ntr, nit, nmk
end

--- @param opts.tracks_as_context  every track is context, so nothing is written
---        to any of them. Used when the cursor context says the item selection
---        is what was meant -- the tracks are still enumerated, because folder
---        inheritance and the track->item cascade need them.
function M.tracks(proj, opts)
  opts = opts or {}
  local list = {}
  local depth = 0

  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local ok, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if not ok or name == nil then name = '' end
    local fd = floor(reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH'))
    -- REAPER 7 visual spacers. Stored on the track BELOW the gap:
    --   I_SPACER : int * : 1=TCP track spacer above this track
    local spacer = reaper.GetMediaTrackInfo_Value(tr, 'I_SPACER') ~= 0

    list[#list + 1] = {
      kind = 'track', obj = tr, idx = i,
      name = name,
      folderdepth = fd, depth = depth, spacer_above = spacer,
      guid = reaper.GetTrackGUID(tr),
      color = reaper.GetMediaTrackInfo_Value(tr, 'I_CUSTOMCOLOR'),
      context = opts.selected_only
                and (opts.tracks_as_context or not reaper.IsTrackSelected(tr))
                or nil,
    }

    if fd >= 1 then
      depth = depth + fd
    elseif fd < 0 then
      depth = depth + fd            -- can close several levels at once (-2, -3)
      if depth < 0 then depth = 0 end
    end
  end

  return list
end

-------------------------------------------------------------------- items
--- One entry per media item. Items are matched on their ACTIVE TAKE's name; an
--- item with no take, or a take with a blank name, gets name = '' (which the
--- 'unnamed' filter can still target deliberately).
---
--- `track_guid` is what lets a track rule cascade its colour onto the items
--- sitting on it. Enumerating per track gives it for free and needs only
--- long-standing API, which is why it is done that way rather than asking each
--- item for its track.
function M.items(proj, opts)
  opts = opts or {}
  local list = {}

  local function entry(it, trguid)
    local name = ''
    local take = reaper.GetActiveTake(it)
    if take then
      local ok, nm = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
      if ok and nm then name = nm end
    end
    local _, guid = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
    -- A custom colour on the TAKE can hide the item's colour entirely,
    -- depending on a REAPER preference. Record it so an item whose colour is
    -- already right but is being masked still gets rewritten.
    local masked = false
    if take then
      local tc = reaper.GetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR')
      masked = colors.norm(tc) ~= 0
    end
    return {
      kind = 'item', obj = it, idx = #list, take = take,
      name = name, guid = guid or tostring(it),
      track_guid = trguid,
      take_color = masked,
      color = reaper.GetMediaItemInfo_Value(it, 'I_CUSTOMCOLOR'),
    }
  end

  if opts.selected_only then
    local can_ask = reaper.APIExists('GetMediaItem_Track')
    for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
      local it = reaper.GetSelectedMediaItem(proj, i)
      local trguid
      if can_ask then
        local tr = reaper.GetMediaItem_Track(it)
        if tr then trguid = reaper.GetTrackGUID(tr) end
      end
      list[#list + 1] = entry(it, trguid)
    end
  else
    for t = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, t)
      local trguid = reaper.GetTrackGUID(tr)
      for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
        list[#list + 1] = entry(reaper.GetTrackMediaItem(tr, i), trguid)
      end
    end
  end

  return list
end

--------------------------------------------------------- markers & regions
--- Both markers and regions, in project order. `kind` distinguishes them.
---
--- Under `selected_only` the unselected ones come back flagged `context`
--- rather than being left out, exactly as tracks do: a gradient grouped into
--- runs needs its neighbours, so dropping them would give a selected region a
--- different colour from the one Apply All gives it.
---
--- Selection comes from B_UISEL ("selected in arrange view"), read through
--- GetRegionOrMarkerInfo_Value. Verified against the REAPER binary's own API
--- table rather than assumed -- there is no IsMarkerSelected, and this is the
--- only exposure of the state.
function M.markers(proj, opts)
  opts = opts or {}
  local list = {}

  -- A build too old for the modern marker API cannot report selection at all.
  -- Flag everything as context there: colouring the lot would be worse than
  -- colouring none, and that build cannot clear marker colours either.
  local sel_known = opts.selected_only and modern_marker_api()
  local blind     = opts.selected_only and not sel_known

  local i = 0
  while true do
    local rv, isrgn, pos, rgnend, name, idx, color = reaper.EnumProjectMarkers3(proj, i)
    if rv == 0 then break end

    local ctx
    if blind then
      ctx = true
    elseif sel_known then
      local ok, selected = pcall(function()
        local mk = reaper.GetRegionOrMarker(proj, i, '')
        if mk == nil then return false end
        return reaper.GetRegionOrMarkerInfo_Value(proj, mk, 'B_UISEL') ~= 0
      end)
      ctx = (not ok or not selected) or nil
    end

    list[#list + 1] = {
      context = ctx,
      kind  = isrgn and 'region' or 'marker',
      obj   = idx,                     -- markrgnindexnumber, for SetProjectMarker4
      idx   = i,
      isrgn = isrgn, pos = pos, rgnend = rgnend,
      name  = name or '',
      -- EnumProjectMarkers3 gives no GUID; index+position is stable enough for
      -- a cache whose only job is skipping unchanged objects.
      guid  = string.format('%s:%d:%.6f', isrgn and 'R' or 'M', idx, pos),
      color = color or 0,
    }
    i = i + 1
  end
  return list
end

-------------------------------------------------------------------- writes
--- True when this REAPER can clear a marker/region colour back to default.
function M.can_clear_markers()
  return modern_marker_api()
end

--- Write a colour to one entry. Pass rgb = nil to clear back to default.
--- @return true if the write happened, false plus a reason if it could not.
function M.set(entry, rgb)
  local kind = entry.kind
  local native = rgb and colors.to_native(rgb) or 0

  if kind == 'track' then
    reaper.SetMediaTrackInfo_Value(entry.obj, 'I_CUSTOMCOLOR', native)
    return true

  elseif kind == 'item' then
    reaper.SetMediaItemInfo_Value(entry.obj, 'I_CUSTOMCOLOR', native)
    -- Clear every take's own colour. Whether a take colour or the item colour
    -- is displayed is a REAPER preference, so leaving one in place can make the
    -- colour we just wrote invisible -- and take colours travel with a
    -- copy/paste, which is how a stale one ends up on the wrong track.
    -- Every take, not just the active one, so switching takes cannot bring a
    -- stale colour back.
    for i = 0, reaper.CountTakes(entry.obj) - 1 do
      local tk = reaper.GetTake(entry.obj, i)
      if tk then reaper.SetMediaItemTakeInfo_Value(tk, 'I_CUSTOMCOLOR', 0) end
    end
    return true

  elseif kind == 'region' or kind == 'marker' then
    if rgb == nil then
      -- SetProjectMarker4 reads colour 0 as "leave unchanged", so clearing has
      -- to go through the newer API.
      if not modern_marker_api() then
        return false, 'this REAPER cannot clear marker/region colours'
      end
      local ok, err = pcall(function()
        local mk = reaper.GetRegionOrMarker(0, entry.idx, '')
        reaper.SetRegionOrMarkerInfo_Value(0, mk, 'I_CUSTOMCOLOR', 0)
      end)
      if not ok then return false, tostring(err) end
      return true
    end
    reaper.SetProjectMarker4(0, entry.obj, entry.isrgn, entry.pos, entry.rgnend,
                             entry.name, native, 0)
    return true
  end

  return false, 'unknown kind ' .. tostring(kind)
end

--- Select one object and bring it into view. Used by the GUI's preview list.
function M.reveal(entry)
  if entry.kind == 'track' then
    reaper.SetOnlyTrackSelected(entry.obj)
    reaper.Main_OnCommand(40913, 0)            -- scroll track into view
  elseif entry.kind == 'item' then
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(entry.obj, true)
    reaper.UpdateArrange()
  else
    reaper.SetEditCurPos(entry.pos, true, false)
  end
end

--- Everything, in the order the apply pipeline wants it.
function M.all(proj, opts)
  opts = opts or {}
  local out = {}
  -- Tracks are always fetched, even for a selection-only apply: the unselected
  -- ones come back as context and make folder inheritance and the track->item
  -- cascade correct. M.tracks flags them; plan() never writes to them.
  if opts.want_tracks ~= false then
    for _, e in ipairs(M.tracks(proj, opts)) do out[#out + 1] = e end
  end
  if opts.want_items ~= false then
    for _, e in ipairs(M.items(proj, opts)) do out[#out + 1] = e end
  end
  if opts.want_markers ~= false then
    for _, e in ipairs(M.markers(proj, opts)) do out[#out + 1] = e end
  end
  return out
end

return M
