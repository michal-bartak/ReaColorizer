--[[
  MB_NameColorizer_WhyThisColour.lua -- explain one object.

  Select a track or an item and run this. It reports what colour the rules
  would give it, which rule decided, and -- when nothing is happening -- why.
  Read-only: it changes nothing.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local config  = require 'config'
local apply   = require 'apply'
local targets = require 'targets'
local colors  = require 'colors'
local matcher = require 'matcher'

local out = {}
local function w(fmt, ...)
  out[#out + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
end
local function hex(rgb) return rgb and colors.tohex(rgb) or 'default (no custom colour)' end

local cfg, info = config.load()

-- what did the user select?
local item  = reaper.GetSelectedMediaItem(0, 0)
local track = reaper.GetSelectedTrack(0, 0)
if not item and not track then
  reaper.ShowMessageBox('Select a track or an item first, then run this again.',
                        'Name Colorizer', 0)
  return
end

local entries = targets.all(0, {})
local ops, stats, desired, winner, from_track =
  apply.plan(entries, cfg.rules, cfg.options)

-- locate the selected object in the plan
local want_guid
if item then
  local _, g = reaper.GetSetMediaItemInfo_String(item, 'GUID', '', false)
  want_guid = g
else
  want_guid = reaper.GetTrackGUID(track)
end

local me, idx
for i, e in ipairs(entries) do
  if e.guid == want_guid then me, idx = e, i break end
end

reaper.ClearConsole()
w('=== Why is this %s that colour? ===', item and 'item' or 'track')
w('')

if not me then
  w('That object was not found in the scan. (An item with no take on a track')
  w('with none of its own is the usual reason.)')
  reaper.ShowConsoleMsg(table.concat(out, '\n') .. '\n')
  return
end

w('name            : %s', me.name ~= '' and ('"' .. me.name .. '"') or '(no name)')
w('kind            : %s', me.kind)
w('colour now      : %s', hex(colors.from_native(me.color)))
if me.kind == 'item' then
  w('take colour     : %s', me.take_color
    and 'YES -- a custom take colour is set, and it HIDES the item colour'
    or  'none')
end
w('')

-- which rule, if any, claimed it
local r = winner[idx]
if r then
  w('MATCHED BY      : %s rule "%s"', me.kind,
    r.label ~= '' and r.label or '(no name)')
  w('  mode          : %s%s', r.mode, r.ci and ', ignore case' or '')
  w('  pattern       : "%s"', r.pattern)
  if r.only then w('  filter        : %s', r.only) end
elseif from_track[idx] then
  w('MATCHED BY      : nothing on the Items tab --')
  w('                  it takes the colour of the track it sits on,')
  w('                  because that track\'s rule has "also colour items" on.')
else
  w('MATCHED BY      : nothing')
end

w('')
w('rules would set : %s', hex(desired[idx]))

-- the track story, for items
if me.kind == 'item' then
  local tr_entry
  for _, e in ipairs(entries) do
    if e.kind == 'track' and e.guid == me.track_guid then tr_entry = e break end
  end
  w('')
  if tr_entry then
    local ti
    for i, e in ipairs(entries) do if e == tr_entry then ti = i break end end
    local tr_rule = winner[ti]
    w('its track       : "%s"', tr_entry.name)
    w('  track colour  : %s', hex(desired[ti]))
    if tr_rule then
      w('  track rule    : "%s"', tr_rule.label ~= '' and tr_rule.label or '(no name)')
      w('  also colour items: %s', tr_rule.cascade_items and 'YES' or
        'NO   <-- tick this if you want items to follow this track')
    else
      w('  track rule    : none matched')
    end
  else
    w('its track       : could not be identified')
  end
end

-- so what would happen?
w('')
w('-------------------------------------------------------------')
local cur = colors.from_native(me.color)
local clears = (cfg.options.clear_unmatched or {})[me.kind] == true

if desired[idx] == nil then
  if cur == nil and not (me.kind == 'item' and me.take_color) then
    w('VERDICT: no rule claims it, and it has no custom colour. Nothing to do.')
    if me.kind == 'item' then
      w('         REAPER draws it in its track\'s colour -- which is what you')
      w('         want if items should follow their tracks.')
    end
  elseif clears then
    w('VERDICT: no rule claims this %s, and "reset when unmatched" IS on for', me.kind)
    w('         %ss -- so Apply WOULD reset it to the default colour.', me.kind)
    w('         If it has not been reset, nothing has applied the rules yet:')
    w('         press "Apply now", or start MB_NameColorizer_AutoToggle.lua.')
  else
    w('VERDICT: no rule claims this %s, and "reset when unmatched" is OFF for', me.kind)
    w('         %ss, so its existing colour is LEFT ALONE. That is why an old', me.kind)
    w('         colour survives a copy/paste onto a different track.')
    w('         Fix: Options > Scope > tick "%s" under "Reset to the default',
      (me.kind == 'item') and 'Items' or me.kind)
    w('         colour when no rule matches".')
  end
elseif desired[idx] == cur then
  w('VERDICT: already the right colour. Apply would write nothing.')
else
  w('VERDICT: Apply WOULD change it, %s -> %s.', hex(cur), hex(desired[idx]))
  w('         If it has not changed, nothing has applied the rules yet:')
  w('         press "Apply now", or start MB_NameColorizer_AutoToggle.lua.')
end

-- environment, since "nothing happens" is usually one of these
w('')
w('-------------------------------------------------------------')
local hb = tonumber(reaper.GetExtState(config.EXT_SECTION, 'auto_heartbeat'))
local alive = hb and (os.time() - hb) <= 3
w('background auto-apply : %s', alive and 'RUNNING'
  or 'not running  (colours only change when you press Apply)')
if alive and reaper.GetExtState(config.EXT_SECTION, 'auto_enabled') == '0' then
  w('                        ...but PAUSED from the window')
end
w('rules file version    : %d  (%s)', cfg.version or 0, config.path())
local n = 0
for _, k in ipairs({ 'track', 'item', 'region', 'marker' }) do
  n = n + #(cfg.rules[k] or {})
  w('  %-7s rules        : %d', k, #(cfg.rules[k] or {}))
end
do
  local cu, on = cfg.options.clear_unmatched or {}, {}
  for _, k in ipairs({ 'track', 'item', 'region', 'marker' }) do
    if cu[k] then on[#on + 1] = k end
  end
  w('reset when unmatched  : %s', #on > 0 and table.concat(on, ', ') or 'nothing')
end
w('folder propagation    : %s', tostring(cfg.options.propagate_folders))
w('')

reaper.ShowConsoleMsg(table.concat(out, '\n') .. '\n')
