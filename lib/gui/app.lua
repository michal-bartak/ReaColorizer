--[[
  gui/app.lua -- state and behaviour for the configuration window.

  The view modules draw; this module owns everything else: the loaded config,
  the debounced save, the in-app undo stack, the cached project scan and the
  preview tallies.

  Note what is NOT here: the GUI never runs the auto-apply loop itself. Two
  writers would fight over the same colours. It talks to the background script
  only through ExtState.
]]

local config     = require 'config'
local rulesmod   = require 'rules'
local apply      = require 'apply'
local targets    = require 'targets'
local matcher    = require 'matcher'
local json       = require 'json'
local entrylib   = require 'entry'
local regex      = require 'regex'

local M = {}

local SECT = config.EXT_SECTION
local SAVE_DEBOUNCE   = 0.5     -- seconds after the last edit
local PREVIEW_SETTLE  = 0.3     -- seconds after the last keystroke
local UNDO_DEPTH      = 20

local st = {
  cfg = nil, info = nil,
  dirty = false, dirty_at = 0,
  readonly = false,

  entries = {}, entries_scc = nil, entries_at = 0,
  won = {}, shadowed = {}, preview = {}, preview_total = {},
  preview_dirty = true, preview_at = 0,

  sel_id = nil,
  active_kind = 'track',
  filter = '',
  undo = {},
  toast = nil, toast_at = 0,

  tester = { subject = 'Kick In', result = nil },
}

M.st = st

------------------------------------------------------------------- lifecycle
function M.load()
  local cfg, info = config.load()
  st.cfg, st.info = cfg, info
  st.readonly = info.readonly == true
  st.preview_dirty = true
  if info.corrupt then
    M.toast('Rule file was unreadable; kept as config.bad.json. Started from defaults.')
  end
  return cfg
end

function M.toast(text)
  st.toast, st.toast_at = text, reaper.time_precise()
end

function M.current_toast()
  if not st.toast then return nil end
  if reaper.time_precise() - st.toast_at > 6 then st.toast = nil; return nil end
  return st.toast
end

---------------------------------------------------------------- undo (in-app)
-- Rule edits live in a config file, not the project, so REAPER's Ctrl+Z cannot
-- reach them. This is a small snapshot stack so the window has its own undo.
function M.snapshot()
  -- Same reason as config.save: never serialise the live rules, they carry
  -- unencodable runtime scratch.
  local s = json.encode(config.serializable(st.cfg))
  if not s then return end
  local top = st.undo[#st.undo]
  if top == s then return end
  st.undo[#st.undo + 1] = s
  while #st.undo > UNDO_DEPTH do table.remove(st.undo, 1) end
end

function M.can_undo() return #st.undo > 0 end

function M.undo()
  local s = table.remove(st.undo)
  if not s then return false end
  local data = json.decode(s)
  if not data then return false end
  st.cfg = config.normalize(data)
  M.mark_dirty(true)
  return true
end

---------------------------------------------------------------------- saving
--- Record an edit. Call snapshot() BEFORE mutating, this AFTER.
function M.mark_dirty(skip_preview)
  st.dirty, st.dirty_at = true, reaper.time_precise()
  matcher.clear_cache()
  if not skip_preview then st.preview_dirty = true end
end

function M.flush(force)
  if not st.dirty then return end
  if st.readonly then st.dirty = false; return end
  if not force and reaper.time_precise() - st.dirty_at < SAVE_DEBOUNCE then return end

  local ok, err = config.save(st.cfg)
  st.dirty = false
  if not ok then M.toast('Could not save rules: ' .. tostring(err)) end
end

------------------------------------------------------------ project scanning
--- Re-read the project, but only when it has actually changed.
function M.refresh_entries(force)
  local scc = reaper.GetProjectStateChangeCount(0)
  if not force and scc == st.entries_scc then return false end
  st.entries_scc = scc
  st.entries = targets.all(0, {})
  st.preview_dirty = true
  return true
end

--- Recompute per-rule tallies and the preview list. Never per frame.
function M.recompute_preview()
  local now = reaper.time_precise()
  if not st.preview_dirty then return end
  if now - st.preview_at < PREVIEW_SETTLE then return end
  st.preview_at, st.preview_dirty = now, false

  st.won, st.shadowed = apply.tally(st.entries, st.cfg.rules)

  -- Run the real pipeline and show its result. Deriving the preview any other
  -- way means it can disagree with Apply -- which it did: gradients were shown
  -- as the rule's primary colour, and tracks coloured by folder inheritance did
  -- not appear at all.
  local _, _, desired, winner, from_track =
    apply.plan(st.entries, st.cfg.rules, st.cfg.options)

  -- Bucketed by kind so the list can follow the selected tab. The 500 cap is
  -- per kind, otherwise a project full of items would crowd out every region.
  local list, total = {}, {}
  for _, k in ipairs(rulesmod.KINDS) do list[k], total[k] = {}, 0 end

  -- so a cascaded item can name the track it took its colour from
  local track_name = {}
  for _, e in ipairs(st.entries) do
    if e.kind == 'track' then track_name[e.guid] = e.name end
  end

  for i, e in ipairs(st.entries) do
    if not e.context and list[e.kind] then
      total[e.kind] = total[e.kind] + 1
      if desired[i] ~= nil and #list[e.kind] < 500 then
        local b = list[e.kind]
        b[#b + 1] = {
          kind       = e.kind,
          name       = e.name,
          entry      = e,
          color      = desired[i],          -- what will actually be written
          rule       = winner[i],           -- nil when it was not matched directly
          from_track = from_track[i] == true,
          track_name = e.track_guid and track_name[e.track_guid] or nil,
          inherited  = (winner[i] == nil),
        }
      end
    end
  end
  st.preview, st.preview_total = list, total
end

--- @return rule, index, kind
function M.rule_by_id(id)
  for _, kind in ipairs(rulesmod.KINDS) do
    for i, r in ipairs(st.cfg.rules[kind] or {}) do
      if r.id == id then return r, i, kind end
    end
  end
end

function M.list(kind) return st.cfg.rules[kind] or {} end

function M.count(kind)
  local n = 0
  for _, r in ipairs(M.list(kind)) do if r.enabled then n = n + 1 end end
  return n, #M.list(kind)
end

--------------------------------------------------------------- rule mutation
function M.add_rule(kind)
  kind = kind or st.active_kind
  M.snapshot()
  local list = st.cfg.rules[kind]
  local r = rulesmod.new(kind, { label = 'New rule', mode = 'substring', pattern = '' })
  list[#list + 1] = r
  st.sel_id = r.id
  M.mark_dirty()
  return r
end

function M.duplicate_rule(kind, i)
  local list = st.cfg.rules[kind]
  local src = list and list[i]
  if not src then return end
  M.snapshot()
  local holder = { options = {}, rules = { [kind] = { src } } }
  local clean  = config.serializable(holder).rules[kind][1]
  local copy   = rulesmod.normalize(json.decode(json.encode(clean)), kind)
  copy.id    = rulesmod.newid()
  copy.label = (src.label ~= '' and src.label or src.pattern) .. ' copy'
  table.insert(list, i + 1, copy)
  st.sel_id = copy.id
  M.mark_dirty()
end

function M.remove_rule(kind, i)
  local list = st.cfg.rules[kind]
  if not list or not list[i] then return end
  M.snapshot()
  table.remove(list, i)
  M.mark_dirty()
end

function M.move_rule(kind, from, to)
  local list = st.cfg.rules[kind]
  if not list then return end
  local n = #list
  if from < 1 or from > n or to < 1 or to > n or from == to then return end
  M.snapshot()
  table.insert(list, to, table.remove(list, from))
  M.mark_dirty()
end

------------------------------------------------------------------ auto status
--- Is the background script alive? It writes a heartbeat every tick.
function M.auto_running()
  local hb = tonumber(reaper.GetExtState(SECT, 'auto_heartbeat'))
  if not hb then return false end
  return (os.time() - hb) <= 3
end

function M.auto_paused()
  return reaper.GetExtState(SECT, 'auto_enabled') == '0'
end

function M.set_auto_paused(paused)
  reaper.SetExtState(SECT, 'auto_enabled', paused and '0' or '1', false)
end

--- The background script records its own command id the first time it runs;
--- without that there is no way for this window to invoke it.
function M.auto_command_id()
  return tonumber(reaper.GetExtState(SECT, 'auto_cmdid'))
end

--- Start it if stopped, stop it if running. The action is itself a toggle, so
--- one invocation does either.
function M.toggle_auto()
  local cmd = M.auto_command_id()
  if not cmd then
    M.toast('Run the action MB_NameColorizer_AutoToggle.lua once first -- ' ..
            'after that this button can start and stop it.')
    return false
  end
  M.set_auto_paused(false)          -- never leave it paused-but-"on"
  reaper.Main_OnCommand(cmd, 0)
  return true
end

--------------------------------------------------------------------- actions
function M.apply_all()
  M.flush(true)
  config.bump_override_rev()      -- the rules decide again, everywhere
  local stats = apply.run(0, st.cfg.rules, st.cfg.options, {}, 'Colorize by name')
  M.refresh_entries(true)
  if stats.written == 0 then
    M.toast(stats.matched == 0 and 'No rule matched anything.' or 'Already up to date.')
  else
    M.toast(string.format('Coloured %d object%s.', stats.written,
                          stats.written == 1 and '' or 's'))
  end
end

function M.apply_selection()
  M.flush(true)
  local stats = apply.run(0, st.cfg.rules, st.cfg.options,
                          { selected_only = true, want_markers = false },
                          'Colorize selection by name')
  M.refresh_entries(true)
  M.toast(stats.scanned == 0 and 'Nothing is selected.'
          or string.format('Coloured %d of %d selected.', stats.written, stats.scanned))
end

--- scope: 'matched' | 'all'
function M.clear_colors(scope)
  M.flush(true)
  local entries = targets.all(0, {})
  local ops = apply.plan_clear(entries, st.cfg.rules, scope, st.cfg.options)
  if #ops == 0 then M.toast('Nothing to clear.'); return end
  local written = apply.commit(ops, 'Clear colours')
  M.refresh_entries(true)
  M.toast(string.format('Cleared %d object%s.', written, written == 1 and '' or 's'))
end

-------------------------------------------------------------------- tester
--- Run the selected rule's pattern against the tester's subject string.
function M.run_tester()
  local r = st.sel_id and M.rule_by_id(st.sel_id)
  local t = st.tester
  if not r then t.result = nil; return end

  if r.pattern == '' then
    t.result = { ok = true, note = 'empty pattern: matches any name' }
    return
  end

  local m, err, pos = matcher.compile(r.mode, r.pattern, r.ci)
  if not m then
    t.result = { err = err, pos = pos }
    return
  end

  local hit, why = m:test(t.subject)
  local res = { ok = hit, budget = (why == 'budget') }

  -- For regex, also show the matched span and any capture groups.
  if r.mode == 'regex' and m.rx then
    local a, b, caps = m.rx:find(t.subject)
    if a then res.span = { a, b }; res.caps = caps end
  end
  t.result = res
end

------------------------------------------------------------------- warnings
function M.sws_warning()
  local clash, keys = entrylib.sws_conflict()
  if not clash then return nil end
  return 'SWS Auto Color is enabled (' .. table.concat(keys, ', ') ..
         ') and will fight with this tool.'
end

return M
