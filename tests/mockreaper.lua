--[[ A small fake REAPER, enough to run the real action scripts headlessly.
     Models the awkward bits faithfully: P_NAME returns false on the master,
     items carry no name (only their active take does), I_CUSTOMCOLOR needs the
     0x1000000 bit to count, SetProjectMarker4 treats colour 0 as
     "leave unchanged" so it cannot clear, and ValidatePtr2 reports a deleted
     object as gone rather than crashing the way the real one would not.

     Two clocks, because they answer different questions. `tick_cost` advances
     time on every reading, which is a caricature; `write_cost` advances it per
     WRITE, which is where the real cost is, and is what any test about the
     cold sweep's time budget should use. ]]
local M = {}

function M.install(opts)
  opts = opts or {}
  local P = { tracks = {}, items = {}, marks = {}, undo = {}, console = {},
              boxes = {}, extstate = {}, dirty = 0 }

  local master = { name = nil, color = 0, guid = '{MASTER}', fd = 0, sel = false,
                   is_master = true }
  P.master = master

  local r = {}

  r.GetResourcePath = function() return opts.resource or '.' end
  r.GetAppVersion   = function() return '7.80/mock' end
  r.get_action_context = function() return false, opts.script or './x.lua', 0, 1, 0, 0, 0, '' end

  r.ShowConsoleMsg  = function(s) P.console[#P.console+1] = s end
  r.ClearConsole    = function() P.console = {} end
  r.ShowMessageBox  = function(msg, title, kind)
    P.boxes[#P.boxes+1] = { msg = msg, title = title, kind = kind }
    if kind == 3 then return opts.mb_answer or 2 end
    return 1
  end

  -- macOS byte order
  r.ColorToNative   = function(a,g,b) return (a<<16)|(g<<8)|b end
  r.ColorFromNative = function(v) return (v>>16)&0xFF, (v>>8)&0xFF, v&0xFF end

  r.GetMasterTrack  = function() return master end
  r.CountTracks     = function() return #P.tracks end
  r.GetTrack        = function(_, i) return P.tracks[i+1] end
  r.IsTrackSelected = function(t) return t.sel == true end
  r.GetTrackGUID    = function(t) return t.guid end
  r.GetSetMediaTrackInfo_String = function(t, parm, _, set)
    if parm == 'P_NAME' then
      if t.is_master then return false, '' end   -- master really does return NULL
      return true, t.name or ''
    end
    return false, ''
  end
  r.GetMediaTrackInfo_Value = function(t, parm)
    if parm == 'I_CUSTOMCOLOR' then return t.color or 0 end
    if parm == 'I_FOLDERDEPTH' then return t.fd or 0 end
    if parm == 'I_SPACER' then return t.spacer and 1 or 0 end
    return 0
  end
  r.SetMediaTrackInfo_Value = function(t, parm, v)
    if parm == 'I_CUSTOMCOLOR' then t.color = v end
    P.scc = P.scc + 1
    P.now = P.now + P.write_cost
  end

  -- items know which track they sit on (needed for the track->item cascade)
  r.CountTrackMediaItems = function(tr)
    local n = 0
    for _, it in ipairs(P.items) do if it.track == tr then n = n + 1 end end
    return n
  end
  r.GetTrackMediaItem = function(tr, i)
    local n = 0
    for _, it in ipairs(P.items) do
      if it.track == tr then
        if n == i then return it end
        n = n + 1
      end
    end
  end
  r.GetMediaItem_Track = function(it) return it.track end

  r.CountMediaItems = function() return #P.items end
  r.GetMediaItem    = function(_, i) return P.items[i+1] end
  r.CountSelectedTracks = function()
    local n = 0; for _, t in ipairs(P.tracks) do if t.sel then n = n + 1 end end; return n
  end
  -- The cursor context the focus probe measured. P.cursor_context is nil until
  -- a test sets it, and APIExists then reports GetCursorContext2 as missing --
  -- which is the case a build without it would present.
  r.GetCursorContext = function() return -1 end     -- as measured: always -1
  r.CountSelectedMediaItems = function()
    local n = 0; for _, it in ipairs(P.items) do if it.sel then n = n + 1 end end; return n
  end
  r.GetSelectedMediaItem = function(_, i)
    local n = 0
    for _, it in ipairs(P.items) do
      if it.sel then if n == i then return it end; n = n + 1 end
    end
  end
  r.GetActiveTake = function(it) return it.take end
  r.CountTakes = function(it) return it.take and 1 or 0 end
  r.GetTake = function(it, i) return i == 0 and it.take or nil end
  r.GetMediaItemTakeInfo_Value = function(tk, parm)
    if parm == 'I_CUSTOMCOLOR' then return tk.color or 0 end
    return 0
  end
  r.SetMediaItemTakeInfo_Value = function(tk, parm, v)
    if parm == 'I_CUSTOMCOLOR' then tk.color = v; P.scc = P.scc + 1 end
  end
  r.GetDisplayedMediaItemColor2 = function(it, tk)
    if tk and (tk.color or 0) ~= 0 then return tk.color end
    return it.color or 0
  end
  r.GetSetMediaItemTakeInfo_String = function(tk, parm)
    if parm == 'P_NAME' then return true, tk.name or '' end
    return false, ''
  end
  r.GetSetMediaItemInfo_String = function(it, parm)
    if parm == 'GUID' then return true, it.guid end
    return false, ''
  end
  r.GetMediaItemInfo_Value = function(it, parm)
    if parm == 'I_CUSTOMCOLOR' then return it.color or 0 end
    return 0
  end
  r.SetMediaItemInfo_Value = function(it, parm, v)
    if parm == 'I_CUSTOMCOLOR' then it.color = v end
    P.scc = P.scc + 1
    P.now = P.now + P.write_cost
  end

  r.EnumProjectMarkers3 = function(_, i)
    local m = P.marks[i+1]
    if not m then return 0 end
    return #P.marks, m.isrgn, m.pos, m.rgnend, m.name, m.idx, m.color
  end
  r.SetProjectMarker4 = function(_, idx, isrgn, pos, rgnend, name, color, flags)
    for _, m in ipairs(P.marks) do
      if m.idx == idx and m.isrgn == isrgn then
        -- 0 means "leave unchanged"
        if color ~= 0 then m.color = color; P.scc = P.scc + 1; P.now = P.now + P.write_cost end
        return true
      end
    end
    return false
  end
  function P.set_cursor_context(v)
    P.cursor_context = v
    r.GetCursorContext2 = v ~= nil and function() return v end or nil
  end
  r.APIExists = function(n)
    if opts.no_modern_markers then
      if n == 'GetRegionOrMarker' or n == 'SetRegionOrMarkerInfo_Value' then return false end
    end
    return r[n] ~= nil
  end
  r.CountProjectMarkers = function()
    local nm, nr = 0, 0
    for _, m in ipairs(P.marks) do
      if m.isrgn then nr = nr + 1 else nm = nm + 1 end
    end
    return #P.marks, nm, nr
  end
  r.GetRegionOrMarker = function(_, index) return P.marks[index+1] end
  -- A marker keeps its GUID across a move; index and position do not, which is
  -- why the auto-loop cache asks for this one.
  r.GetSetRegionOrMarkerInfo_String = function(_, mk, parm)
    if mk == nil then return false, '' end
    if parm == 'GUID'   then return true, mk.guid end
    if parm == 'P_NAME' then return true, mk.name or '' end
    return false, ''
  end
  -- Colours are planned in one tick and written in a later one, so the object
  -- can be gone by the time the write happens.
  r.ValidatePtr2 = function(_, obj, ctype)
    if obj == nil then return false end
    if ctype == 'MediaTrack*' then
      if obj == master then return true end
      for _, t in ipairs(P.tracks) do if t == obj then return true end end
      return false
    elseif ctype == 'MediaItem*' then
      for _, it in ipairs(P.items) do if it == obj then return true end end
      return false
    end
    return true
  end
  -- B_UISEL is how REAPER exposes "selected in arrange view" for a marker or
  -- region; there is no CountSelectedMarkers to go with it.
  r.GetRegionOrMarkerInfo_Value = function(_, mk, parm)
    if mk == nil then return 0 end
    if parm == 'B_UISEL'       then return mk.sel and 1 or 0 end
    if parm == 'I_CUSTOMCOLOR' then return mk.color or 0 end
    if parm == 'B_ISREGION'    then return mk.isrgn and 1 or 0 end
    return 0
  end
  r.SetRegionOrMarkerInfo_Value = function(_, mk, parm, v)
    if parm == 'I_CUSTOMCOLOR' then mk.color = v end
    return true
  end

  -- time and the project change counter --------------------------------
  P.now, P.scc = 0.0, 0
  -- Optionally let time creep forward on every reading. Without this the
  -- wall-clock budget in the auto-loop's cold sweep can never expire, so the
  -- chunking it exists for is never exercised.
  P.tick_cost = opts.tick_cost or 0
  -- What a single colour write costs. The cold sweep's budget is spent on
  -- writes, so this is the honest knob for testing that it chunks at all.
  P.write_cost = opts.write_cost or 0
  r.time_precise = function()
    P.now = P.now + P.tick_cost
    return P.now
  end
  function P.advance(dt) P.now = P.now + (dt or 0.25) end
  r.GetProjectStateChangeCount = function() return P.scc end
  r.EnumProjects = function() return 'PROJ0' end
  r.GetPlayState = function() return P.playstate or 0 end
  -- Real REAPER bumps the change counter on OUR writes too; model that, so the
  -- "do not retrigger on your own edits" logic is actually exercised.
  local function bump() P.scc = P.scc + 1 end
  P.bump = bump
  r.DeleteExtState = function(sec, k) if P.extstate[sec] then P.extstate[sec][k] = nil end end
  r.SetToggleCommandState = function() end
  r.RefreshToolbar2 = function() end
  r.atexit = function() end
  r.defer = function() end

  r.Undo_BeginBlock = function() P.undo[#P.undo+1] = { open = true } end
  r.Undo_EndBlock   = function(desc, flags)
    local last = P.undo[#P.undo]
    if last and last.open then last.open = false; last.desc = desc; last.flags = flags end
  end
  r.PreventUIRefresh = function() end
  r.UpdateArrange = function() end
  r.TrackList_AdjustWindows = function() end
  r.MarkProjectDirty = function() P.dirty = P.dirty + 1 end
  r.RecursiveCreateDirectory = function() return 1 end
  r.GetExtState = function(sec, k) return (P.extstate[sec] or {})[k] or '' end
  r.SetExtState = function(sec, k, v) P.extstate[sec] = P.extstate[sec] or {}; P.extstate[sec][k] = v end
  r.SetOnlyTrackSelected = function() end
  r.Main_OnCommand = function() end
  r.SelectAllMediaItems = function() end
  r.SetMediaItemSelected = function() end
  r.SetEditCurPos = function() end

  _G.reaper = r

  -- builders
  function P.track(name, o)
    o = o or {}
    local t = { name = name, color = o.color or 0, fd = o.fd or 0,
                spacer = o.spacer or false,
                sel = o.sel or false, guid = '{T' .. (#P.tracks+1) .. '}' }
    P.tracks[#P.tracks+1] = t
    return t
  end
  function P.item(takename, o)
    o = o or {}
    local it = { color = o.color or 0, sel = o.sel or false,
                 track = o.track or P.tracks[#P.tracks],   -- last track by default
                 guid = '{I' .. (#P.items+1) .. '}' }
    if takename ~= nil then it.take = { name = takename, color = o.take_color or 0 } end
    P.items[#P.items+1] = it
    return it
  end
  function P.mark(name, isrgn, o)
    o = o or {}
    local m = { name = name, isrgn = isrgn, pos = o.pos or (#P.marks * 1.0),
                rgnend = o.rgnend or 0, idx = #P.marks + 1, color = o.color or 0,
                sel = o.sel or false,
                guid = '{' .. (isrgn and 'R' or 'M') .. (#P.marks+1) .. '}' }
    P.marks[#P.marks+1] = m
    return m
  end

  -- Deleting objects, so a test can pull one out from under a queued write.
  local function drop(list, obj)
    for i, x in ipairs(list) do
      if x == obj then table.remove(list, i); P.scc = P.scc + 1; return true end
    end
    return false
  end
  function P.delete_track(t) return drop(P.tracks, t) end
  function P.delete_item(it) return drop(P.items, it) end
  function P.consoletext() return table.concat(P.console, '') end

  return P
end

return M
