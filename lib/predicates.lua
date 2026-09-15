--[[
  predicates.lua -- optional non-name filters on a rule.

  SWS has the same idea as its "(folder)" / "(unnamed)" keyword filters, but
  there the keyword REPLACES the name filter. Here it NARROWS it, which is
  strictly more useful: an empty pattern with only='folder' gives "every folder
  track", and the same predicate with '^Drums' gives "folder tracks named
  Drums...".

  Deliberately pure: callers pass a plain info table rather than a REAPER
  object, so this is unit-testable outside REAPER and does no API calls of its
  own. targets.lua is what fills the table in.
]]

local M = {}

-- Order here is the order shown in the GUI dropdown.
M.LIST = { 'folder', 'children', 'unnamed' }

M.LABEL = {
  folder   = 'is a folder track',
  children = 'is inside a folder',
  unnamed  = 'has no name',
}

-- Which object kinds each predicate can meaningfully apply to. The GUI greys
-- out the rest so a rule cannot be built that silently never matches.
M.KINDS = {
  folder   = { track = true },
  children = { track = true },
  unnamed  = { track = true, item = true, region = true, marker = true },
}

--- The predicates worth offering for a given object kind. Tracks have folder
--- structure to talk about; items, regions and markers only have a name.
function M.for_kind(kind)
  local out = {}
  for _, k in ipairs(M.LIST) do
    if M.KINDS[k][kind] then out[#out + 1] = k end
  end
  return out
end

--- Is `only` a predicate this build knows about?
function M.valid(only)
  return only == nil or M.KINDS[only] ~= nil
end

--- Can `only` ever match objects of `kind`?
function M.applies(only, kind)
  if only == nil then return true end
  local k = M.KINDS[only]
  return k ~= nil and k[kind] == true
end

--- Evaluate a predicate.
-- @param only  nil | 'folder' | 'children' | 'unnamed'
-- @param kind  'track' | 'item' | 'region' | 'marker'
-- @param info  { name=string, folderdepth=number, depth=number }
function M.test(only, kind, info)
  if only == nil then return true end

  if only == 'unnamed' then
    return (info.name or '') == ''
  end

  -- Everything else is track-only.
  if kind ~= 'track' then return false end

  if only == 'folder' then
    return info.folderdepth == 1
  elseif only == 'children' then
    return (info.depth or 0) > 0
  end

  return false
end

return M
