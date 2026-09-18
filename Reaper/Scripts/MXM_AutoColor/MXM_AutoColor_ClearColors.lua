--[[
  MXM_AutoColor_ClearColors.lua
  Reset colours to default.

  Two scopes are offered here:
    - the selected tracks and items
    - everything the current rules match (the honest stand-in for "things this
      tool coloured", since a one-shot script has no memory of past runs)

  Clearing EVERY custom colour in a project is deliberately not offered from a
  single keystroke; it lives in the GUI where it can be confirmed properly.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local apply   = require 'apply'
local targets = require 'targets'
local entry   = require 'entry'

local cfg = entry.load_config()

local choice = reaper.ShowMessageBox(
  'Clear colours on which objects?\n\n' ..
  'YES     = the selected tracks and items\n' ..
  'NO      = everything the current rules match\n' ..
  'CANCEL  = do nothing',
  'AutoColor: clear colours', 3)          -- 3 = Yes / No / Cancel

if choice == 2 then return end                 -- cancel
local selection = (choice == 6)

local scope = selection
  and { selected_only = true, want_markers = false }
  or  {}

local entries = targets.all(0, scope)
local ops     = apply.plan_clear(entries, cfg.rules,
                                 selection and 'all' or 'matched', cfg.options)

if #ops == 0 then
  entry.msg('Nothing to clear -- none of those objects has a custom colour.')
  return
end

if not targets.can_clear_markers() then
  local n = 0
  for _, op in ipairs(ops) do
    if op.entry.kind == 'region' or op.entry.kind == 'marker' then n = n + 1 end
  end
  if n > 0 then
    entry.msg('This REAPER build cannot clear marker/region colours ' ..
              '(SetProjectMarker4 treats colour 0 as "leave unchanged").\n\n' ..
              n .. ' marker(s)/region(s) will be skipped; tracks and items are fine.')
  end
end

local written, failures = apply.commit(ops, 'Clear colours set by name')
entry.summary('Clear colours', {
  scanned = #entries, matched = #ops, written = written,
  cleared = written, failures = failures,
})
