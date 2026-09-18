-- The GUI's logic layer (gui/app.lua) touches no ImGui, so it can be tested
-- headlessly against the mock REAPER.
package.path = os.getenv('SP') .. '/?.lua;' .. package.path
local mock = require 'mockreaper'
local NC, TMP = os.getenv('NC'), os.getenv('SP') .. '/proj3'
os.execute('rm -rf "' .. TMP .. '" && mkdir -p "' .. TMP .. '/AutoColor"')

local pass, fail, fails = 0, 0, {}
local function check(ok, label, detail)
  if ok then pass = pass + 1
  else fail = fail + 1; fails[#fails+1] = label .. (detail and ('  -- ' .. detail) or '') end
end

local P = mock.install{ resource = TMP, script = NC .. '/x.lua' }
P.now = 1000                                  -- past the debounce windows
reaper.GetSelectedTrack = function() return P.tracks[1] end

package.path = NC .. '/?.lua;' .. NC .. '/lib/?.lua;' .. package.path
local colors = require 'colors'
local config = require 'config'
local app    = require 'gui.app'

P.track('Kick In'); P.track('Sub Bass'); P.track('Audio 7')
P.item('gtr_dry_01')
P.mark('Chorus 1', true, { rgnend = 4 }); P.mark('Chorus 2', true, { rgnend = 8 })

---------------------------------------------------------------- first run
local cfg = app.load()
check(cfg ~= nil, 'app.load returns a config')
check(#cfg.rules.track > 0, 'first run installs the starter rules',
      #cfg.rules.track .. ' track rules')
check(app.st.info.created == true, 'first run is flagged as created')

---------------------------------------------------------------- preview
P.advance(1)
app.refresh_entries(true)
-- 3 tracks + 1 item + 2 regions. The master is not enumerated at all: REAPER
-- does not honour a custom colour on it.
check(#app.st.entries == 6, 'refresh_entries scans the project', #app.st.entries .. ' entries')
do
  local has_master = false
  for _, e in ipairs(app.st.entries) do if e.name == 'MASTER' then has_master = true end end
  check(not has_master, 'the master is not scanned')
end
P.advance(1)
app.recompute_preview()
check(next(app.st.won) ~= nil, 'tallies are computed')

do
  local hit = false
  for _, p in ipairs(app.st.preview.track) do
    if p.name == 'Kick In' then hit = true end
  end
  check(hit, 'the preview lists a track the starter rules match')
end

-- the preview must agree with what Apply actually does
do
  app.apply_all()
  local kick
  for _, t in ipairs(P.tracks) do if t.name == 'Kick In' then kick = t end end
  local shown
  for _, p in ipairs(app.st.preview.track) do
    if p.name == 'Kick In' then shown = p.rule.color end
  end
  check(colors.from_native(kick.color) == shown,
        'preview colour matches what Apply wrote',
        tostring(colors.from_native(kick.color)) .. ' vs ' .. tostring(shown))
end

---------------------------------------------------------------- mutation
local n0 = #app.st.cfg.rules.track
local r = app.add_rule('track')
check(#app.st.cfg.rules.track == n0 + 1, 'add_rule appends')
check(app.st.sel_id == r.id, 'the new rule is selected')

app.move_rule('track', #app.st.cfg.rules.track, 1)
check(app.st.cfg.rules.track[1].id == r.id, 'move_rule reorders')

app.duplicate_rule('track', 1)
check(#app.st.cfg.rules.track == n0 + 2, 'duplicate_rule inserts a copy')
check(app.st.cfg.rules.track[2].id ~= app.st.cfg.rules.track[1].id,
      'the copy gets a fresh id')

app.remove_rule('track', 1); app.remove_rule('track', 1)
check(#app.st.cfg.rules.track == n0, 'remove_rule deletes')

---------------------------------------------------------------- undo stack
do
  local before = #app.st.cfg.rules.track
  local firstlabel = app.st.cfg.rules.track[1].label
  app.snapshot()
  app.st.cfg.rules.track[1].label = 'CHANGED'
  app.mark_dirty()
  check(app.can_undo(), 'undo is available after a snapshot')
  app.undo()
  check(app.st.cfg.rules.track[1].label == firstlabel, 'undo restores the label',
        app.st.cfg.rules.track[1].label)
  check(#app.st.cfg.rules.track == before, 'undo does not change the rule count')
end
do -- the stack is bounded
  for i = 1, 40 do
    app.snapshot(); app.st.cfg.rules.track[1].label = 'x' .. i
  end
  local depth = 0
  while app.can_undo() do app.undo(); depth = depth + 1 end
  check(depth <= 20, 'the undo stack is capped at 20', depth .. ' deep')
end

---------------------------------------------------------------- saving
do
  app.snapshot()
  app.st.cfg.rules.track[1].label = 'Persisted'
  app.mark_dirty()
  app.flush(false)                       -- too soon: debounced
  check(app.st.dirty == true, 'a save is debounced, not immediate')
  P.advance(1)
  app.flush(false)
  check(app.st.dirty == false, 'the save happens once the debounce elapses')

  local reloaded = config.load()
  check(reloaded.rules.track[1].label == 'Persisted', 'the edit reached the file')
end

---------------------------------------------------------------- tester
do
  -- The tester is a scratch pad: its own mode and pattern, nothing to do with
  -- the selected rule.
  local t = app.st.tester
  app.st.sel_id = nil
  t.mode, t.pattern, t.subject = 'regex', '^(\\d+)_(\\w+)$', '01_Kick'
  app.run_tester()
  local res = t.result
  check(res and res.ok, 'tester reports a match with no rule selected')
  check(res.caps and res.caps[1] == '01' and res.caps[2] == 'Kick',
        'tester returns capture groups')
  check(res.span and res.span[1] == 1, 'tester returns the matched span')

  t.subject = 'nope'
  app.run_tester()
  check(t.result.ok == false, 'tester reports a non-match')

  t.pattern = '(unclosed'
  app.run_tester()
  check(t.result.err ~= nil, 'tester reports an invalid pattern')
  check(t.result.pos ~= nil, 'tester reports the error position')

  t.pattern = '^(a+)+$'
  t.subject = string.rep('a', 40) .. '!'
  app.run_tester()
  check(t.result.budget == true, 'tester flags a pattern that is too slow')

  t.pattern = ''
  app.run_tester()
  check(t.result.note ~= nil, 'tester explains an empty pattern')

  -- The other two modes report a span as well, so the match is highlighted
  -- whatever mode you are in.
  t.mode, t.pattern, t.subject = 'substring', 'Gtr', '01 Gtr L'
  app.run_tester()
  check(t.result.ok and t.result.span[1] == 4 and t.result.span[2] == 6,
        'substring mode reports where it matched')

  t.mode, t.pattern, t.subject = 'glob', '*Gtr*', '01 Gtr L'
  app.run_tester()
  check(t.result.ok and t.result.span ~= nil, 'glob mode matches and reports a span')

  -- Changing the selected rule must not disturb any of it.
  local rr = app.st.cfg.rules.track[1]
  rr.mode, rr.pattern = 'regex', '^never$'
  app.st.sel_id = rr.id
  app.run_tester()
  check(t.result.ok == true, 'the selected rule has no say in the result')
  app.st.sel_id = nil
end

---------------------------------------------------------------- auto status
check(app.auto_running() == false, 'auto reports off with no heartbeat')
reaper.SetExtState(config.EXT_SECTION, 'auto_heartbeat', tostring(os.time()), false)
check(app.auto_running() == true, 'auto reports on with a fresh heartbeat')
reaper.SetExtState(config.EXT_SECTION, 'auto_heartbeat', tostring(os.time() - 60), false)
check(app.auto_running() == false, 'a stale heartbeat reads as off')

app.set_auto_paused(true)
check(app.auto_paused() == true, 'pause flag round trips')
app.set_auto_paused(false)
check(app.auto_paused() == false, 'resume clears the pause flag')

---------------------------------------------------------------- clearing
do
  app.st.cfg = config.starter()
  app.apply_all()
  local any = false
  for _, t in ipairs(P.tracks) do if t.color ~= 0 then any = true end end
  check(any, 'apply_all coloured something before the clear test')

  app.clear_colors('all')
  local left = 0
  for _, t in ipairs(P.tracks) do if t.color ~= 0 then left = left + 1 end end
  check(left == 0, 'clear_colors("all") resets every track', left .. ' left')
end

------------------------------------------ regions and markers can be selected
do
  local targets = require 'targets'
  local function clear_sel()
    for _, t in ipairs(P.tracks) do t.sel = false end
    for _, i in ipairs(P.items)  do i.sel = false end
    for _, m in ipairs(P.marks)  do m.sel = false end
    P.set_cursor_context(nil)
  end

  clear_sel()
  check(targets.count_selected_markers(0) == 0, 'no selected regions to start')
  P.marks[1].sel = true
  check(targets.count_selected_markers(0) == 1, 'B_UISEL is read back')

  -- Unselected markers must still be ENUMERATED, as context: a gradient
  -- grouped into runs needs its neighbours, so leaving them out would give a
  -- selected region a different colour from the one Apply All gives it.
  local es = targets.all(0, { selected_only = true })
  local nregion, nctx = 0, 0
  for _, e in ipairs(es) do
    if e.kind == 'region' then
      nregion = nregion + 1
      if e.context then nctx = nctx + 1 end
    end
  end
  check(nregion == 2, 'both regions are enumerated', nregion .. ' seen')
  check(nctx == 1, 'and the unselected one is context, not missing', nctx .. ' context')

  -- the bug: clearing the selection ignored regions and markers entirely
  app.st.cfg = config.starter()
  P.marks[1].color = 0x1FF0000
  P.marks[2].color = 0x100FF00
  app.clear_colors('selected')
  check(P.marks[1].color == 0, 'the selected region IS cleared')
  check(P.marks[2].color ~= 0, 'and an unselected one is left alone')

  clear_sel()
end

---------------------------------------------- which selection was meant
do
  local targets = require 'targets'
  local function sel(tracks, items, ctx)
    for _, t in ipairs(P.tracks) do t.sel = false end
    for _, i in ipairs(P.items)  do i.sel = false end
    for _, i in ipairs(tracks) do P.tracks[i].sel = true end
    for _, i in ipairs(items)  do P.items[i].sel  = true end
    P.set_cursor_context(ctx)
    return (targets.selection_focus(0))
  end

  check(sel({}, {}, nil) == nil, 'nothing selected has no focus')
  check(sel({ 1 }, {}, 1) == 'tracks',
        'a stale "items" context loses to an empty item selection')
  check(sel({}, { 1 }, 0) == 'items',
        'and a stale "tracks" context loses to an empty track selection')

  -- the case this whole thing exists for
  check(sel({ 1 }, { 1 }, 1) == 'items',
        'both selected, context says items -> items')
  check(sel({ 1 }, { 1 }, 0) == 'tracks',
        'both selected, context says track panels -> tracks')
  check(sel({ 1 }, { 1 }, 2) == 'both',
        'an envelope context decides nothing, so honour both')
  check(sel({ 1 }, { 1 }, nil) == 'both',
        'and so does a build with no GetCursorContext2')

  for _, t in ipairs(P.tracks) do t.sel = false end
  for _, i in ipairs(P.items)  do i.sel = false end
  P.set_cursor_context(nil)
end

do -- a remembered track selection is not written to when items are what is meant
  app.st.cfg = config.starter()
  app.clear_colors('all')
  for _, t in ipairs(P.tracks) do t.sel = false end
  for _, i in ipairs(P.items)  do i.sel = false end

  P.tracks[1].sel = true      -- selected earlier and left behind
  P.items[1].sel  = true      -- what the user actually clicked
  P.set_cursor_context(1)     -- ...and the context agrees

  app.apply_selection()
  check(P.tracks[1].color == 0, 'the left-over track selection is not coloured')
  check(app.current_toast():find('item') ~= nil,
        'and the status line names what it used', tostring(app.current_toast()))

  -- same selection, context says the track panel instead
  app.clear_colors('all')
  P.set_cursor_context(0)
  app.apply_selection()
  check(P.tracks[1].color ~= 0, 'with the focus on the panel the track IS coloured')

  for _, t in ipairs(P.tracks) do t.sel = false end
  for _, i in ipairs(P.items)  do i.sel = false end
  P.set_cursor_context(nil)
  app.clear_colors('all')
end

do -- clearing the selection touches the selection and nothing else
  app.st.cfg = config.starter()
  for _, t in ipairs(P.tracks) do t.sel = false end
  app.apply_all()

  local coloured = {}
  for _, t in ipairs(P.tracks) do coloured[#coloured + 1] = t.color end
  local pick
  for i, t in ipairs(P.tracks) do if t.color ~= 0 and t.name then pick = i break end end
  check(pick ~= nil, 'a coloured track to select')

  if pick then
    P.tracks[pick].sel = true
    app.clear_colors('selected')

    check(P.tracks[pick].color == 0, 'the selected track is cleared')
    local others_kept = true
    for i, t in ipairs(P.tracks) do
      if i ~= pick and t.color ~= coloured[i] then others_kept = false end
    end
    check(others_kept, 'and every unselected track keeps its colour')
    -- Unselected tracks come back from targets.all as context. If plan_clear
    -- ever stopped skipping context entries this is what would catch it.
    check(app.current_toast():find('selection') ~= nil,
          'the status line says the selection was what changed',
          tostring(app.current_toast()))

    P.tracks[pick].sel = false
  end
end

do -- and says so plainly when there is no selection at all
  app.st.cfg = config.starter()
  for _, t in ipairs(P.tracks) do t.sel = false end
  for _, i in ipairs(P.items) do i.sel = false end
  app.clear_colors('selected')
  check(app.current_toast() == 'Nothing is selected.',
        'an empty selection is reported as empty, not as "nothing to clear"',
        tostring(app.current_toast()))
end

print('\n=== gui logic (mock REAPER) ===')
for _, f in ipairs(fails) do print('  FAIL  ' .. f) end
print(string.format('%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
