--[[
  MXM_AutoColor_ApplySelection.lua
  Apply the rule set to the selected tracks and items only. Never touches
  regions or markers, which have no meaningful "selection" here.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local apply = require 'apply'
local entry = require 'entry'

local cfg = entry.load_config()

local stats = apply.run(0, cfg.rules, cfg.options,
                        { selected_only = true, want_markers = false },
                        'Colorize selection by name')
entry.summary('Apply to selection', stats, { selection = true })
