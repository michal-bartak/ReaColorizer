--[[
  MXM_AutoColor_TakeColorProbe.lua -- does a TAKE colour actually show?

  Select one media item, run this. It sets a distinct colour on the active take
  (nothing else), reports what REAPER says it will display, then offers to put
  things back. Read-mostly: the only change is that take's colour, and it is a
  single undo point.
]]

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  reaper.ShowMessageBox('Select one media item first, then run this again.',
                        'Take colour probe', 0)
  return
end

local take = reaper.GetActiveTake(item)
if not take then
  reaper.ShowMessageBox('That item has no take (it is an empty item).',
                        'Take colour probe', 0)
  return
end

local ENABLE = 0x1000000
local function hex(v)
  if v == nil then return 'n/a' end
  v = math.floor(v)
  if v < 0 then v = v + 0x100000000 end
  v = v & 0x1FFFFFF
  if v == 0 then return 'default (no custom colour)' end
  local r, g, b = reaper.ColorFromNative(v & 0xFFFFFF)
  return string.format('#%02X%02X%02X', r, g, b)
end

local item_before = reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR')
local take_before = reaper.GetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR')
local disp_before = reaper.GetDisplayedMediaItemColor2(item, take)

-- a colour nothing else is likely to be using
local PROBE = reaper.ColorToNative(255, 0, 170) | ENABLE

reaper.Undo_BeginBlock()
reaper.SetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR', PROBE)
reaper.UpdateArrange()
reaper.Undo_EndBlock('Take colour probe', 4)

local disp_after = reaper.GetDisplayedMediaItemColor2(item, take)
local take_wins  = (math.floor(disp_after) == math.floor(PROBE))

local verdict
if take_wins then
  verdict = 'TAKE COLOUR WINS.\n\n' ..
            'REAPER reports it will display the take colour, so colouring takes\n' ..
            'separately is meaningful on this setup.'
else
  verdict = 'TAKE COLOUR IS IGNORED.\n\n' ..
            'The take now carries a custom colour, but REAPER reports it will\n' ..
            'display ' .. hex(disp_after) .. ' instead -- the item (or track)\n' ..
            'colour is winning.\n\n' ..
            'That is a REAPER preference, under\n' ..
            'Preferences > Appearance > Media.'
end

local msg = verdict .. '\n\n' ..
  '-------------------------------------------\n' ..
  'item colour        : ' .. hex(item_before) .. '\n' ..
  'take colour before : ' .. hex(take_before) .. '\n' ..
  'take colour now    : ' .. hex(PROBE) .. '  (pink)\n' ..
  'REAPER displays    : ' .. hex(disp_after) .. '\n' ..
  '  (before the probe it displayed ' .. hex(disp_before) .. ')\n' ..
  '-------------------------------------------\n\n' ..
  'Also just look at the item in the arrange view -- is it pink?\n\n' ..
  'Put the take colour back the way it was?'

if reaper.ShowMessageBox(msg, 'Take colour probe', 4) == 6 then
  reaper.Undo_BeginBlock()
  reaper.SetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR', take_before)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Restore take colour', 4)
end
