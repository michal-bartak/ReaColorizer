--[[
  rules.lua -- the rule record.

  A rule belongs to exactly one object kind, decided by which list it lives in
  (see config.lua). That is why there is no "targets" field any more: a rule in
  the track list colours tracks, full stop. It removes a whole class of
  confusion, like a region rule offering an "is a folder track" filter.

  Rules arrive from three places (the GUI, the config file, the starter set) and
  all three go through normalise(), so the rest of the code can assume every
  field is present and of the right type.
]]

local predicates = require 'predicates'

local M = {}

M.KINDS = { 'track', 'item', 'region', 'marker' }

M.KIND_LABEL = {
  track  = 'Tracks',
  item   = 'Items',
  region = 'Regions',
  marker = 'Markers',
}

M.KIND_NOUN = {
  track  = 'track',
  item   = 'item',
  region = 'region',
  marker = 'marker',
}

M.MODES = { 'substring', 'glob', 'regex' }

local MODE_SET = {}
for _, m in ipairs(M.MODES) do MODE_SET[m] = true end

local KIND_SET = {}
for _, k in ipairs(M.KINDS) do KIND_SET[k] = true end

M.MODE_LABEL = {
  substring = 'contains',
  glob      = 'glob',
  regex     = 'regex',
}

function M.valid_kind(k) return KIND_SET[k] == true end

------------------------------------------------------------------------ ids
local counter = 0
local seeded = false

--- Stable-enough unique id. Used as the ImGui widget id, the cache key and the
--- handle the preview and undo stack refer to, so it must not change once set.
function M.newid()
  if not seeded then
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
    seeded = true
  end
  counter = counter + 1
  return string.format('r_%05x%03x', math.random(0, 0xFFFFF), counter % 0x1000)
end

-------------------------------------------------------------------- creation
function M.new(kind, o)
  o = o or {}
  o.kind = kind
  return M.normalize(o, kind)
end

--- Coerce anything rule-shaped into a well-formed rule of `kind`. Never throws:
--- a config that has been hand-edited into nonsense should load with sane
--- values rather than taking the whole rule set down.
function M.normalize(r, kind)
  r = type(r) == 'table' and r or {}
  if not KIND_SET[kind] then kind = 'track' end
  r.kind = kind

  if type(r.id) ~= 'string' or r.id == '' then r.id = M.newid() end
  if type(r.label) ~= 'string' then r.label = '' end
  if type(r.note)  ~= 'string' then r.note  = '' end

  r.enabled = (r.enabled ~= false)
  -- Case-insensitive by default: people type track names casually, and a rule
  -- that silently misses "Bass" because it was written "bass" is a bad default.
  r.ci      = (r.ci ~= false)
  r.invert  = (r.invert == true)

  if not MODE_SET[r.mode] then r.mode = 'substring' end
  if type(r.pattern) ~= 'string' then r.pattern = '' end

  -- Legacy: the 'master' filter is gone -- REAPER does not honour a custom
  -- colour on the master track, so the filter never did anything visible.
  -- Just dropping it would leave a rule with an empty pattern matching EVERY
  -- object, so disable the rule and say why instead.
  if r.only == 'master' then
    r.only, r.enabled = nil, false
    local why = 'disabled: the "master track" filter was removed ' ..
                '(REAPER ignores custom colours on the master)'
    r.note = (r.note ~= '') and (r.note .. ' | ' .. why) or why
  end

  if r.only == '' then r.only = nil end
  -- A filter that cannot apply to this kind is dropped rather than left to
  -- sit there never matching.
  if r.only ~= nil and not predicates.applies(r.only, kind) then r.only = nil end

  local function clampcolor(c)
    if type(c) ~= 'number' then return nil end
    c = math.floor(c)
    if c < 0 then return nil end
    return c & 0xFFFFFF
  end
  r.color  = clampcolor(r.color) or 0x808080
  r.color2 = clampcolor(r.color2)

  -- Only track rules can push their colour onto the items sitting on them.
  if kind == 'track' then
    r.cascade_items = (r.cascade_items == true)
  else
    r.cascade_items = nil
  end

  r.targets = nil        -- v1 leftover; the list a rule lives in decides this

  return r
end

------------------------------------------------------------------ inspection
--- Non-fatal warnings to surface in the GUI. Advisory: none of these stops a
--- rule from being applied.
function M.warnings(r)
  local w = {}

  if r.pattern == '' and r.only == nil then
    w[#w + 1] = 'matches every ' .. (M.KIND_NOUN[r.kind] or 'object') ..
                ' -- add a pattern or a filter'
  end

  if r.only == 'unnamed' and r.pattern ~= '' then
    w[#w + 1] = 'an unnamed object has no name to match, so the pattern never matches'
  end

  if r.color2 and r.kind == 'item' then
    w[#w + 1] = 'gradients over items are recomputed in full on every change -- ' ..
                'slow on very large projects'
  end

  if r.cascade_items and r.color2 then
    w[#w + 1] = 'items take the track\'s final colour, so each track\'s items all ' ..
                'get that track\'s shade of the gradient'
  end

  return w
end

return M
