--[[
  MB_NameColorizer_Dump.lua -- read-only diagnostic.

  Prints every track, item, region and marker with its name, GUID and current
  colour. Writes nothing. Run this first on a new project to confirm the target
  adapters read everything correctly -- especially items with no take and the
  marker/region API.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local targets = require 'targets'
local colors  = require 'colors'

local buf = {}
local function w(fmt, ...)
  buf[#buf + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
end

local function showcolor(raw)
  local rgb = colors.from_native(raw)
  if rgb == nil then return 'default' end
  return colors.tohex(rgb)
end

local function section(title, list)
  w('\n--- %s (%d) ---', title, #list)
  for _, e in ipairs(list) do
    if e.kind == 'track' then
      w('  [%3s] %-34s  fd=%-2d depth=%d  color=%-8s guid=%s',
        tostring(e.idx),
        '"' .. e.name .. '"', e.folderdepth, e.depth,
        showcolor(e.color), e.guid)
    elseif e.kind == 'item' then
      w('  [%3d] %-34s  take=%-5s color=%-8s guid=%s',
        e.idx, '"' .. e.name .. '"', e.take and 'yes' or 'NONE',
        showcolor(e.color), e.guid)
    else
      w('  [%3d] %-34s  %-6s pos=%.3f%s color=%-8s guid=%s',
        e.idx, '"' .. e.name .. '"', e.kind, e.pos,
        e.isrgn and string.format('..%.3f', e.rgnend) or '',
        showcolor(e.color), e.guid)
    end
  end
end

reaper.ClearConsole()
w('=== NameColorizer target dump ===')
w('REAPER %s   marker colours clearable: %s',
  reaper.GetAppVersion(), tostring(targets.can_clear_markers()))

local ok, err = pcall(function()
  local tracks = targets.tracks(0, {})
  local items  = targets.items(0, {})
  local marks  = targets.markers(0)

  section('TRACKS', tracks)
  section('ITEMS', items)
  section('MARKERS & REGIONS', marks)

  local unnamed = 0
  for _, e in ipairs(items) do if e.name == '' then unnamed = unnamed + 1 end end
  w('\n%d tracks, %d items (%d with no name), %d markers/regions',
    #tracks, #items, unnamed, #marks)
end)

if not ok then
  w('\n!! ERROR: %s', tostring(err))
end

w('')
reaper.ShowConsoleMsg(table.concat(buf, '\n'))
