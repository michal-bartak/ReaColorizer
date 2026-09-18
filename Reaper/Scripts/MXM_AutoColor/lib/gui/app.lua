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
local ENTRIES_SETTLE  = 0.25    -- seconds between project scans
local SWS_SETTLE      = 5       -- seconds between reads of the SWS ini
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

  tester = { mode = 'substring', pattern = '', subject = '', result = nil },
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
--- Re-read the project, but only when it has actually changed -- and not more
--- than a few times a second even then.
---
--- The change counter alone is not enough of a brake. Dragging an item bumps it
--- on every frame, and this scan reads a name, a GUID and a colour for every
--- object in the project, so the window was re-reading the whole project at
--- frame rate for as long as the mouse was moving. The auto-apply loop is doing
--- its own scanning at the same time.
function M.refresh_entries(force)
  local now = reaper.time_precise()
  if not force then
    if now - st.entries_at < ENTRIES_SETTLE then return false end
    if reaper.GetProjectStateChangeCount(0) == st.entries_scc then return false end
  end
  st.entries_at  = now
  st.entries_scc = reaper.GetProjectStateChangeCount(0)
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
    M.toast('Run the action MXM_AutoColor_AutoToggle.lua once first -- ' ..
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

--- The scope for a selection action, once the cursor context has decided which
--- of two live selections was meant. Shared by apply and clear so the two can
--- never disagree about what "the selection" is.
--- @return opts, focus, noun
local function selection_scope()
  local focus, _, _, nmk = targets.selection_focus(0)
  -- Markers and regions ARE enumerated: targets.markers reads B_UISEL and
  -- flags the unselected ones as context, so they filter themselves while
  -- still anchoring a gradient's runs.
  local opts  = { selected_only = true }
  local noun  = 'object'

  if focus == 'items' then
    -- Tracks stay enumerated but none of them is writable: folder inheritance
    -- and the track->item cascade still need to see them.
    opts.tracks_as_context = true
    noun = 'item'
  elseif focus == 'tracks' then
    opts.want_items = false
    noun = 'track'
  end

  -- A selected region alongside a selected track makes "3 selected tracks" a
  -- lie, so fall back to the neutral noun rather than pick a side.
  if nmk and nmk > 0 and focus ~= nil then noun = 'object' end
  if focus == nil and nmk and nmk > 0 then noun = 'object' end
  return opts, focus, noun
end

function M.apply_selection()
  M.flush(true)
  local scope, _, noun = selection_scope()
  local stats = apply.run(0, st.cfg.rules, st.cfg.options, scope,
                          'Colorize selection by name')
  M.refresh_entries(true)
  M.toast(stats.scanned == 0 and 'Nothing is selected.'
          or string.format('Coloured %d of %d selected %s%s.',
                           stats.written, stats.scanned, noun,
                           stats.scanned == 1 and '' or 's'))
end

--- scope: 'matched' | 'all' | 'selected'
--- 'selected' narrows the enumeration instead of the plan: markers and regions
--- have no usable selection state, and unselected tracks still come back as
--- context, which plan_clear skips.
function M.clear_colors(scope)
  M.flush(true)
  local sel = (scope == 'selected')
  local sopts, _, noun = selection_scope()
  local entries = targets.all(0, sel and sopts or {})
  local ops = apply.plan_clear(entries, st.cfg.rules, scope, st.cfg.options)

  if #ops == 0 then
    if sel then
      -- "nothing selected" and "the selection has no colours to clear" are
      -- different answers and the first one is actionable.
      local n = 0
      for _, e in ipairs(entries) do if not e.context then n = n + 1 end end
      M.toast(n == 0 and 'Nothing is selected.'
              or ('No selected ' .. noun .. ' has a colour to clear.'))
    else
      M.toast('Nothing to clear.')
    end
    return
  end

  local written = apply.commit(ops, sel and 'Clear colours on selection'
                                        or 'Clear colours')
  M.refresh_entries(true)
  M.toast(string.format('Cleared %d %s%s%s.', written,
                        sel and noun or 'object',
                        written == 1 and '' or 's',
                        sel and ' in the selection' or ''))
end

-------------------------------------------------------------------- tester
--- Run the tester's own pattern against its own subject.
---
--- The tester is a scratch pad, deliberately unaware of the selected rule and
--- of the project: you work an expression out here, then type it into a rule.
function M.run_tester()
  local t = st.tester

  if t.pattern == '' then
    t.result = { ok = true, note = 'empty pattern: matches any name' }
    return
  end

  local m, err, pos = matcher.compile(t.mode, t.pattern, false)
  if not m then
    t.result = { err = err, pos = pos }
    return
  end

  local hit, why = m:test(t.subject)
  local res = { ok = hit, budget = (why == 'budget') }

  -- Where it matched, and what it captured. Glob compiles to a regex too, so
  -- both of those modes can show a span; substring finds its own.
  if hit then
    if m.rx then
      local a, b, caps = m.rx:find(t.subject)
      if a then res.span = { a, b }; res.caps = caps end
    else
      local a, b = string.find(t.subject, t.pattern, 1, true)
      if a then res.span = { a, b } end
    end
  end
  t.result = res
end

------------------------------------------------------------------- warnings
-- The answer lives in a file on disk, and the banner asks for it on every
-- frame. Nobody toggles SWS Auto Color mid-drag, so re-reading it once every
-- few seconds is as live as this needs to be.
local sws_text, sws_at = nil, nil

function M.sws_warning()
  local now = reaper.time_precise()
  if sws_at and now - sws_at < SWS_SETTLE then return sws_text end
  sws_at = now

  local clash, keys = entrylib.sws_conflict()
  sws_text = clash and ('SWS Auto Color is enabled (' .. table.concat(keys, ', ') ..
                        ') and will fight with this tool.') or nil
  return sws_text
end

return M
