--[[
  MB_NameColorizer_AutoToggle.lua -- start/stop background auto-colouring.

  Run once to start (the toolbar button lights up), run again to stop. Only one
  instance can be live: the second launch clears the shared instance token,
  which the running one notices on its next tick and exits.

  Set the ExtState MB_NameColorizer / auto_debug to "1" for a periodic console
  readout of ticks, sweeps, writes and per-tick cost.
]]

local sep = package.config:sub(1, 1)
local _, thisFile, sectionID, cmdID = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local autoloop = require 'autoloop'
local config   = require 'config'
local entry    = require 'entry'

local SECT = config.EXT_SECTION

------------------------------------------------------- single-instance toggle
-- Remember how to invoke this action, so the configuration window can start
-- and stop it. A script's command id is only knowable from inside the script.
if sectionID and sectionID >= 0 and cmdID and cmdID ~= 0 then
  reaper.SetExtState(SECT, 'auto_cmdid', tostring(cmdID), true)
  reaper.SetExtState(SECT, 'auto_section', tostring(sectionID), true)
end

-- A second launch is "stop": clear the token and let the running one notice.
if reaper.GetExtState(SECT, 'auto_instance') ~= '' then
  reaper.SetExtState(SECT, 'auto_instance', '', false)
  return
end

math.randomseed(math.floor(reaper.time_precise() * 1e6) % 2147483647)
local TOKEN = string.format('%d:%d', os.time(), math.random(1, 1e9))
reaper.SetExtState(SECT, 'auto_instance', TOKEN, false)

local function set_toggle(state)
  if sectionID and sectionID >= 0 and cmdID and cmdID ~= 0 then
    reaper.SetToggleCommandState(sectionID, cmdID, state)
    reaper.RefreshToolbar2(sectionID, cmdID)
  end
end

set_toggle(1)
reaper.atexit(function()
  set_toggle(0)
  if reaper.GetExtState(SECT, 'auto_instance') == TOKEN then
    reaper.DeleteExtState(SECT, 'auto_instance', false)
  end
  reaper.DeleteExtState(SECT, 'auto_heartbeat', false)
end)

entry.warn_sws_once()
autoloop.reset()

--------------------------------------------------------------------- the loop
local errors = 0
local last_debug = 0

local function loop()
  -- Another instance (or the GUI) asked us to stop.
  if reaper.GetExtState(SECT, 'auto_instance') ~= TOKEN then return end

  if reaper.GetExtState(SECT, 'auto_enabled') ~= '0' then
    local ok, err = pcall(autoloop.tick)
    if not ok then
      errors = errors + 1
      -- Do not spam a broken loop at 5 Hz: say it once and stop cleanly.
      entry.msg('Background auto-colouring hit an error and has stopped:\n\n' ..
                tostring(err), 'Name Colorizer')
      return
    end
  end

  local now = os.time()
  reaper.SetExtState(SECT, 'auto_heartbeat', tostring(now), false)

  if reaper.GetExtState(SECT, 'auto_debug') == '1' and now - last_debug >= 5 then
    last_debug = now
    local s = autoloop.state.stats
    reaper.ShowConsoleMsg(string.format(
      'NameColorizer auto: %d ticks, %d sweeps, %d writes, %d left alone, last tick %.2f ms\n',
      s.ticks, s.sweeps, s.writes, s.skipped, s.last_ms))
  end

  reaper.defer(loop)
end

reaper.defer(loop)
