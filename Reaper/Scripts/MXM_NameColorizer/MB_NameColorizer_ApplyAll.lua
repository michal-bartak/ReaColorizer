--[[
  MB_NameColorizer_ApplyAll.lua
  Apply the rule set to every track, item, region and marker in the project.
  One undo point. Objects that already have the right colour are not rewritten.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local apply  = require 'apply'
local config = require 'config'
local entry  = require 'entry'

local cfg = entry.load_config()
entry.warn_sws_once()

-- Applying by hand means the rules take precedence again, so tell the
-- background loop to drop any "the user recoloured this" marks it is holding.
config.bump_override_rev()

local stats = apply.run(0, cfg.rules, cfg.options, {}, 'Colorize by name')
entry.summary('Apply to project', stats)
