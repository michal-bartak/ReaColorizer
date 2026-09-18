--[[
  config.lua -- loading and saving the global rule set.

  Storage is one JSON file under the REAPER resource path, deliberately OUTSIDE
  Scripts/ so that updating or reinstalling the scripts can never clobber a
  user's rules:

      <resource path>/NameColorizer/config.json

  Rules are global (one set for every project), which is what was asked for.

  Every successful save bumps an ExtState revision counter. That counter is the
  only channel the background auto-apply script has for noticing that the GUI
  changed something, since the two run in separate Lua states.
]]

local json     = require 'json'
local rulesmod = require 'rules'

local M = {}

M.VERSION     = 2
M.EXT_SECTION = 'MXM_NameColorizer'

local function in_reaper()
  return type(reaper) == 'table' and reaper.GetResourcePath ~= nil
end

---------------------------------------------------------------------- paths
function M.dir()
  if in_reaper() then
    return reaper.GetResourcePath() .. '/NameColorizer'
  end
  return os.getenv('NC_TEST_DIR') or '.'
end

function M.path()    return M.dir() .. '/config.json'     end
function M.bakpath() return M.dir() .. '/config.bak.json' end
function M.badpath() return M.dir() .. '/config.bad.json' end

------------------------------------------------------------------- defaults
local OPTION_SPEC = {
  propagate_folders = { default = 'fill_unmatched',
                        enum = { off = true, fill_unmatched = true, force = true } },
  auto_undo         = { default = false, kind = 'boolean' },
  tick_interval     = { default = 0.20, kind = 'number', min = 0.05, max = 2.0 },
  cold_budget_ms    = { default = 4,    kind = 'number', min = 1,    max = 50 },
  -- How long the background loop may put off a full items-and-markers sweep
  -- when nothing cheap suggests one is needed. 0 sweeps on every project
  -- change, which is what it did before the gate existed.
  cold_interval     = { default = 5,    kind = 'number', min = 0,    max = 60 },
  font_size         = { default = 14,   kind = 'number', min = 8,    max = 32 },
}

--- Which kinds have their unmatched objects reset to the default colour.
--- Per kind because the answer genuinely differs: clearing unmatched ITEMS is
--- how you let them inherit their track's colour, but doing the same to tracks
--- would strip every colour you set by hand.
function M.default_clear_unmatched()
  local t = {}
  for _, k in ipairs(rulesmod.KINDS) do t[k] = false end
  return t
end

function M.default_options()
  local o = {}
  for k, spec in pairs(OPTION_SPEC) do o[k] = spec.default end
  o.clear_unmatched = M.default_clear_unmatched()
  return o
end

--- An empty rule set: one ordered list per object kind.
function M.empty_rules()
  local r = {}
  for _, k in ipairs(rulesmod.KINDS) do r[k] = {} end
  return r
end

function M.defaults()
  return { version = M.VERSION, options = M.default_options(), rules = M.empty_rules() }
end

--- A rule set that demonstrates all three modes and is genuinely usable as-is.
--- Installed on first run so the tool is not an empty window.
function M.starter()
  local cfg = M.defaults()
  local function r(kind, o) cfg.rules[kind][#cfg.rules[kind] + 1] = rulesmod.new(kind, o) end

  r('track', { label = 'Kick',    mode = 'regex', pattern = '^(kick|bd)\\b',
               color = 0xB5453C, cascade_items = true })
  r('track', { label = 'Snare',   mode = 'regex', pattern = '^(snare|sd)\\b',
               color = 0xC97B3F, cascade_items = true })
  r('track', { label = 'Hats',    mode = 'regex', pattern = '^(hh|hat)\\b',
               color = 0xC9A83F, cascade_items = true })
  r('track', { label = 'Toms',    mode = 'regex', pattern = '^tom\\s*\\d*',
               color = 0xA8823C, cascade_items = true })
  r('track', { label = 'Drum bus', mode = 'regex', pattern = '(drum|kit)',
               only = 'folder', color = 0x8A3A33 })
  r('track', { label = 'Bass',    mode = 'regex', pattern = '\\bbass\\b',
               color = 0x6B4FA8, cascade_items = true })
  r('track', { label = 'Guitars', mode = 'regex', pattern = '^(gtr|gui?tar)\\b',
               color = 0x3F7FA8, cascade_items = true })
  r('track', { label = 'Vocals',  mode = 'regex', pattern = '\\b(vox|vocals?)\\b',
               color = 0x3FA87F, cascade_items = true })
  r('track', { label = 'Keys',    mode = 'glob',  pattern = '*key*', color = 0x4FA85C })
  r('track', { label = 'FX',      mode = 'substring', pattern = 'fx', color = 0x7A7A8A })
  r('track', { label = 'Unnamed', mode = 'substring', pattern = '',
               only = 'unnamed', color = 0x555555 })

  r('item',  { label = 'Comps',   mode = 'glob', pattern = '*_comp*', color = 0x4F8AA8 })

  r('region', { label = 'Chorus', mode = 'regex', pattern = '^chorus', color = 0xA8574F })
  r('region', { label = 'Verse',  mode = 'regex', pattern = '^verse',  color = 0x4F7BA8 })

  r('marker', { label = 'Intro',  mode = 'regex', pattern = '^intro',  color = 0x6FA84F })

  return cfg
end

--------------------------------------------------------------- normalisation
local function normalize_options(o)
  o = type(o) == 'table' and o or {}
  local out = {}
  for k, spec in pairs(OPTION_SPEC) do
    local v = o[k]
    if spec.enum then
      out[k] = spec.enum[v] and v or spec.default
    elseif spec.kind == 'boolean' then
      out[k] = (v == true)
    elseif spec.kind == 'number' then
      v = tonumber(v)
      if v == nil then v = spec.default end
      if spec.min and v < spec.min then v = spec.min end
      if spec.max and v > spec.max then v = spec.max end
      out[k] = v
    end
  end

  -- clear_unmatched is a per-kind table. Older configs stored one boolean for
  -- everything; honour it by applying it to every kind.
  local cu = o.clear_unmatched
  out.clear_unmatched = {}
  for _, k in ipairs(rulesmod.KINDS) do
    if type(cu) == 'table' then
      out.clear_unmatched[k] = (cu[k] == true)
    else
      out.clear_unmatched[k] = (cu == true)
    end
  end

  return out
end

-- Rules carry runtime scratch at '_'-prefixed keys (the compiled matcher, its
-- error, the timeout counter). Those contain character-class tables with
-- INTEGER keys, which is not encodable as a JSON object -- so serialising a
-- live rule fails and, before this existed, silently lost every save made
-- after the first preview. Only ever write a cleaned copy.
local RULE_FIELDS = { 'id', 'label', 'enabled', 'mode', 'pattern', 'only',
                      'ci', 'invert', 'color', 'color2', 'note', 'cascade_items',
                      'gradient_scope' }

function M.serializable(cfg)
  local out = { version = cfg.version, options = {}, rules = {} }
  for k, v in pairs(cfg.options or {}) do out.options[k] = v end
  for _, kind in ipairs(rulesmod.KINDS) do
    out.rules[kind] = {}
    for i, r in ipairs((cfg.rules or {})[kind] or {}) do
      local c = {}
      for _, f in ipairs(RULE_FIELDS) do c[f] = r[f] end
      out.rules[kind][i] = c
    end
  end
  return out
end

function M.normalize(cfg)
  cfg = type(cfg) == 'table' and cfg or {}
  cfg.version = tonumber(cfg.version) or M.VERSION
  cfg.options = normalize_options(cfg.options)

  local given = type(cfg.rules) == 'table' and cfg.rules or {}
  local out, seen = {}, {}
  for _, kind in ipairs(rulesmod.KINDS) do
    out[kind] = {}
    local list = type(given[kind]) == 'table' and given[kind] or {}
    for _, r in ipairs(list) do
      if type(r) == 'table' then
        local nr = rulesmod.normalize(r, kind)
        -- ids must be unique across every list: they key the GUI widgets,
        -- the preview and the undo stack.
        if seen[nr.id] then nr.id = rulesmod.newid() end
        seen[nr.id] = true
        out[kind][#out[kind] + 1] = nr
      end
    end
  end
  cfg.rules = out
  return cfg
end

--- Every rule across every kind, for callers that just want to count or scan.
function M.all_rules(cfg)
  local out = {}
  for _, kind in ipairs(rulesmod.KINDS) do
    for _, r in ipairs(cfg.rules[kind] or {}) do out[#out + 1] = r end
  end
  return out
end

-------------------------------------------------------------------- migration
-- migrations[n] upgrades a config at version n to version n+1.
local migrations = {}

--- v1 kept ONE ordered list, each rule carrying track/item/region/marker
--- checkboxes. v2 keeps one list per kind. A rule that ticked several boxes
--- becomes one rule in each of those lists, in the same relative order, so the
--- precedence you had is preserved within every kind.
migrations[1] = function(cfg)
  local old = type(cfg.rules) == 'table' and cfg.rules or {}
  local out = M.empty_rules()

  for _, r in ipairs(old) do
    if type(r) == 'table' then
      local t = type(r.targets) == 'table' and r.targets or { track = true }
      local first = true
      for _, kind in ipairs(rulesmod.KINDS) do
        if t[kind] == true then
          local copy = {}
          for _, f in ipairs(RULE_FIELDS) do copy[f] = r[f] end
          -- only the first copy may keep the original id; the rest need their own
          if not first then copy.id = nil end
          first = false
          out[kind][#out[kind] + 1] = copy
        end
      end
    end
  end

  cfg.rules = out
  return cfg
end

--- Bring a config forward to the current version. Public so the test
--- suite can exercise the v1 -> v2 split directly.
function M.migrate(cfg)
  local v = tonumber(cfg.version) or 1
  while v < M.VERSION do
    local step = migrations[v]
    if not step then break end
    cfg = step(cfg) or cfg
    v = v + 1
  end
  cfg.version = v
  return cfg
end

------------------------------------------------------------------- file I/O
local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function write_file(path, data)
  local f, err = io.open(path, 'wb')
  if not f then return false, tostring(err) end
  f:write(data)
  f:close()
  return true
end

local function ensure_dir()
  if in_reaper() and reaper.RecursiveCreateDirectory then
    reaper.RecursiveCreateDirectory(M.dir(), 0)
  end
end

------------------------------------------------------------------ load/save
--- Load the rule set.
-- @return cfg, info   where info = { created=bool, corrupt=bool, err=string,
--                                    readonly=bool }
function M.load()
  local info = {}
  local raw = read_file(M.path())

  if raw == nil then
    -- First run: hand over a usable rule set rather than an empty window.
    info.created = true
    return M.normalize(M.starter()), info
  end

  local data, err = json.decode(raw)
  if data == nil then
    -- Never lose the user's file: park it and carry on with defaults.
    info.corrupt, info.err = true, err
    write_file(M.badpath(), raw)
    return M.normalize(M.defaults()), info
  end

  if (tonumber(data.version) or 1) > M.VERSION then
    -- Saved by a newer build. Load it, but do not let this build write over it
    -- and silently drop fields it does not understand.
    info.readonly = true
    return M.normalize(data), info
  end

  return M.normalize(M.migrate(data)), info
end

--- Write the rule set and signal the background script.
-- @return true, or false + message
function M.save(cfg)
  cfg = M.normalize(cfg)
  cfg.version = M.VERSION

  local data, err = json.encode(M.serializable(cfg))
  if not data then return false, 'could not encode config: ' .. tostring(err) end
  if data:find('\n') then return false, 'internal: encoded config contains a newline' end

  ensure_dir()

  local tmp = M.path() .. '.tmp'
  local ok, werr = write_file(tmp, data)
  if not ok then return false, 'could not write ' .. tmp .. ': ' .. tostring(werr) end

  local prev = read_file(M.path())
  if prev then write_file(M.bakpath(), prev) end

  os.remove(M.path())
  local rok, rerr = os.rename(tmp, M.path())
  if not rok then return false, 'could not replace config: ' .. tostring(rerr) end

  M.bump_rev()
  return true
end

------------------------------------------------------------ change signalling
--- Bump the revision the auto-apply loop polls. Not persisted: a fresh REAPER
--- session starts at 0 on both sides, which is consistent.
function M.bump_rev()
  if not in_reaper() then return end
  local n = tonumber(reaper.GetExtState(M.EXT_SECTION, 'config_rev')) or 0
  reaper.SetExtState(M.EXT_SECTION, 'config_rev', tostring(n + 1), false)
end

--- Ask the background loop to forget which objects the user recoloured by hand.
--- Apply Now means "the rules decide again", and the loop lives in a separate
--- Lua state, so this ExtState counter is the only way to reach it.
function M.bump_override_rev()
  if not in_reaper() then return end
  local n = tonumber(reaper.GetExtState(M.EXT_SECTION, 'override_rev')) or 0
  reaper.SetExtState(M.EXT_SECTION, 'override_rev', tostring(n + 1), false)
end

function M.override_rev()
  if not in_reaper() then return '0' end
  local v = reaper.GetExtState(M.EXT_SECTION, 'override_rev')
  return (v == nil or v == '') and '0' or v
end

function M.rev()
  if not in_reaper() then return '0' end
  local v = reaper.GetExtState(M.EXT_SECTION, 'config_rev')
  return (v == nil or v == '') and '0' or v
end

return M
