--[[
  MXM_NameColorizer_MakeTestProject.lua -- build a scratch project that exercises
  every awkward case, in a NEW PROJECT TAB so nothing you have open is touched.

  Covers: a folder with two children, a nested folder closing two levels at once,
  a non-ASCII track name, an unnamed track, an item with no take, an item with a
  named take, an item with a blank take name, a marker and a region.

  Purely a diagnostic aid -- delete it once you are happy the tool works.
]]

if reaper.ShowMessageBox(
     'Create a Name Colorizer test project?\n\n' ..
     'It opens in a NEW project tab; nothing you have open is modified.',
     'Name Colorizer', 4) ~= 6 then
  return
end

reaper.Main_OnCommand(40859, 0)          -- New project tab

local function track(name, folderdepth)
  local i = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(i, true)
  local tr = reaper.GetTrack(0, i)
  if name then reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', name, true) end
  if folderdepth then reaper.SetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH', folderdepth) end
  return tr
end

local function midi_item(tr, pos, len, takename)
  local it = reaper.CreateNewMIDIItemInProj(tr, pos, pos + len, false)
  local tk = reaper.GetActiveTake(it)
  if tk and takename then
    reaper.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', takename, true)
  end
  return it
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- a folder with two children
local drums = track('Drums', 1)
local kick  = track('Kick In')
local snare = track('Snare Top', -1)

-- nested folders that close two levels at once, to exercise I_FOLDERDEPTH -2
track('Outer', 1)
track('Inner', 1)
track('Leaf', -2)

-- names that stress the matcher
track('Kytara_hlavn\195\173')            -- non-ASCII
track('Sub Bass')
track('gtr_dry_03')
track('01_Kick')
track(nil)                               -- deliberately unnamed
local fx = track('FX 3')

-- items: one with a named take, one with a blank take name, one with NO take
midi_item(kick,  0.0, 2.0, 'kick_close_01')
midi_item(snare, 2.0, 2.0, 'gtr_dry_03')
midi_item(fx,    4.0, 2.0, '')           -- take exists, name is blank
local empty = reaper.AddMediaItemToTrack(fx)   -- no take at all
reaper.SetMediaItemInfo_Value(empty, 'D_POSITION', 7.0)
reaper.SetMediaItemInfo_Value(empty, 'D_LENGTH', 2.0)

-- a marker and a region
reaper.AddProjectMarker2(0, false, 1.0, 0,   'Intro', -1, 0)
reaper.AddProjectMarker2(0, true,  2.0, 8.0, 'Chorus 1', -1, 0)
reaper.AddProjectMarker2(0, true,  8.0, 12.0, 'Verse 2', -1, 0)

reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock('Name Colorizer test project', -1)

reaper.ShowMessageBox(
  'Test project created in a new tab.\n\n' ..
  'Now run:\n' ..
  '  1. MXM_NameColorizer_Dump.lua      (read-only)\n' ..
  '  2. MXM_NameColorizer_ApplyAll.lua  (then Cmd-Z to undo)\n' ..
  '  3. MXM_NameColorizer_ApplyAll.lua  again -- it must say "already up to date"',
  'Name Colorizer', 0)
