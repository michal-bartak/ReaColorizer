--[[
  entry.lua -- shared plumbing for the action scripts (no ImGui).

  Keeps reporting consistent and, importantly, keeps the action scripts quiet:
  the colours changing is the feedback, so the console only opens when there is
  something the user actually needs to know.
]]

local config = require 'config'

local M = {}

------------------------------------------------------------------ messaging
function M.msg(text, title)
  reaper.ShowMessageBox(text, title or 'Name Colorizer', 0)
end

function M.console(text)
  reaper.ShowConsoleMsg(text .. '\n')
end

----------------------------------------------------------------- SWS conflict
--- SWS Auto Color is a live colour engine too. If it is switched on while we
--- are also applying, the two fight over the same tracks and markers and the
--- result looks like a random flicker. Worth one cheap check.
-- @return boolean, list of the enabled SWS keys
function M.sws_conflict()
  local path = reaper.GetResourcePath() .. '/sws-autocoloricon.ini'
  local f = io.open(path, 'r')
  if not f then return false end
  local text = f:read('a') or ''
  f:close()

  local on = {}
  for _, key in ipairs({ 'AutoColorEnable', 'AutoColorMarkerEnable', 'AutoColorRegionEnable' }) do
    if text:match(key .. '%s*=%s*1') then on[#on + 1] = key end
  end
  if #on == 0 then return false end
  return true, on
end

function M.warn_sws_once()
  local clash, keys = M.sws_conflict()
  if not clash then return false end
  M.msg('SWS Auto Color is currently enabled (' .. table.concat(keys, ', ') .. ').\n\n' ..
        'Both it and Name Colorizer set colours automatically, so they will ' ..
        'fight over the same tracks and markers.\n\n' ..
        'Turn one of them off: SWS > Auto Color/Icon/Layout.',
        'Name Colorizer: conflict')
  return true
end

--------------------------------------------------------------------- config
--- Load the rule set and surface anything the user needs to know about it.
function M.load_config()
  local cfg, info = config.load()

  if info.corrupt then
    M.msg('Your rule file could not be read:\n\n  ' .. tostring(info.err) ..
          '\n\nIt has been kept as:\n  ' .. config.badpath() ..
          '\n\nStarting from defaults so nothing is lost.',
          'Name Colorizer: unreadable config')
  elseif info.created then
    M.console('Name Colorizer: created a starter rule set at ' .. config.path())
  elseif info.readonly then
    M.msg('This rule file was written by a newer version of Name Colorizer.\n\n' ..
          'It will be used as-is, but not saved over, so no settings are lost.',
          'Name Colorizer: newer config')
  end

  return cfg, info
end

--------------------------------------------------------------------- results
--- Report the outcome of a sweep. Silent when it plainly worked.
function M.summary(what, stats, opts)
  opts = opts or {}

  if stats.failures and #stats.failures > 0 then
    local seen, uniq = {}, {}
    for _, f in ipairs(stats.failures) do
      if not seen[f] then seen[f] = true; uniq[#uniq + 1] = f end
    end
    M.msg(what .. ':\n\n' .. stats.written .. ' object(s) coloured, ' ..
          #stats.failures .. ' failed.\n\n' .. table.concat(uniq, '\n'),
          'Name Colorizer: some writes failed')
    return
  end

  if stats.scanned == 0 then
    M.msg(what .. ':\n\nThere was nothing to colour ' ..
          (opts.selection and '-- nothing is selected.' or 'in this project.'),
          'Name Colorizer')
    return
  end

  if stats.matched == 0 then
    M.msg(what .. ':\n\nNone of your rules matched any of the ' .. stats.scanned ..
          ' object(s) scanned.\n\nOpen the Name Colorizer window to see which ' ..
          'rules match what.', 'Name Colorizer: no matches')
    return
  end

  if stats.written == 0 then
    -- Everything already had the right colour. Say so rather than looking broken.
    M.console(string.format('Name Colorizer: %s -- already up to date (%d matched, %d scanned)',
                            what, stats.matched, stats.scanned))
    return
  end

  M.console(string.format('Name Colorizer: %s -- %d coloured%s (%d matched of %d scanned)',
                          what, stats.written,
                          stats.cleared > 0 and (', ' .. stats.cleared .. ' cleared') or '',
                          stats.matched, stats.scanned))
end

return M
