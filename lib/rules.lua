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

-- How far a gradient spreads before it starts over.
M.GRADIENT_SCOPES = { 'all', 'run', 'folder', 'both' }

-- All four read as answers to "spread the gradient across:".
M.GRADIENT_LABEL = {
  all    = 'all matches',
  run    = 'runs',
  folder = 'folders',
  both   = 'runs & folders',
}

-- what the combo shows when closed; the full labels are in the dropdown
M.GRADIENT_SHORT = {
  all    = 'all',
  run    = 'runs',
  folder = 'folders',
  both   = 'both',
}

M.GRADIENT_HELP = {
  all    = 'One ramp across every match in the project.',
  run    = 'A run is an unbroken stretch this rule wins. Anything it does not ' ..
           'win ends one and starts the next.',
  folder = 'One ramp inside each folder.',
  both   = 'A new ramp at a gap or a folder edge, whichever comes first.',
}

local MODE_SET = {}
for _, m in ipairs(M.MODES) do MODE_SET[m] = true end

local KIND_SET = {}
for _, k in ipairs(M.KINDS) do KIND_SET[k] = true end

local GRADIENT_SET = {}
for _, g in ipairs(M.GRADIENT_SCOPES) do GRADIENT_SET[g] = true end

--- Can this kind use this grouping? Folder structure only means something for
--- tracks; everything else can at least be grouped into runs.
function M.gradient_scope_applies(scope, kind)
  if scope == 'all' or scope == 'run' then return true end
  return kind == 'track'          -- 'folder' and 'both' need folder structure
end

--- Regions and markers default to one ramp across everything, unlike tracks and
--- items. A song's regions are normally interleaved -- Verse, Chorus, Verse,
--- Chorus -- so a rule matching one of them rarely wins two in a row, and
--- grouping into runs would leave every group with a single member and no
--- visible gradient at all. Grouping is still available there, just not assumed.
function M.default_gradient_scope(kind)
  if kind == 'region' or kind == 'marker' then return 'all' end
  return 'run'
end

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

  -- Gradient grouping. Stored whatever the rule's colours are, so turning a
  -- gradient off and on again does not lose the choice.
  local default_scope = M.default_gradient_scope(kind)
  if not GRADIENT_SET[r.gradient_scope] then r.gradient_scope = default_scope end
  if not M.gradient_scope_applies(r.gradient_scope, kind) then
    -- Coerce rather than reject, the same as an inapplicable `only` filter:
    -- a hand-edited config should load with sane values, not break.
    r.gradient_scope = default_scope
  end

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
--- @param options the config options table, optional -- some warnings are about
---        how a rule interacts with a global setting
function M.warnings(r, options)
  local w = {}
  local by_folder = r.gradient_scope == 'folder' or r.gradient_scope == 'both'

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

  -- Two combinations quietly flatten a gradient to a single colour.
  if r.color2 and by_folder and r.only == 'folder' then
    w[#w + 1] = 'grouped by folder, but this rule only matches folder parents -- ' ..
                'each one is alone in its group, so every match gets the first colour'
  end

  if r.color2 and by_folder and options and options.propagate_folders == 'force' then
    w[#w + 1] = 'grouped by folder while folder colours are set to "force" -- ' ..
                'each parent overwrites its children, so the whole gradient ' ..
                'collapses to the first colour'
  end

  if r.cascade_items and r.color2 then
    w[#w + 1] = 'items take the track\'s final colour, so each track\'s items all ' ..
                'get that track\'s shade of the gradient'
  end

  return w
end

return M
