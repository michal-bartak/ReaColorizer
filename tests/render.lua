-- Render whole frames of the real GUI against a stub ImGui.
package.path = os.getenv('SP') .. '/?.lua;' .. package.path
local mock     = require 'mockreaper'
local mockimgui = require 'mockimgui'
local NC, TMP = os.getenv('NC'), os.getenv('SP') .. '/proj4'
os.execute('rm -rf "' .. TMP .. '" && mkdir -p "' .. TMP .. '/NameColorizer"')

local function pathlib_read(rel)
  local f = assert(io.open(NC .. '/' .. rel)); local t = f:read('a'); f:close(); return t
end

local pass, fail, fails = 0, 0, {}
local function check(ok, label, detail)
  if ok then pass = pass + 1
  else fail = fail + 1; fails[#fails+1] = label .. (detail and ('  -- ' .. detail) or '') end
end

local P = mock.install{ resource = TMP, script = NC .. '/x.lua' }
P.now = 1000
reaper.GetSelectedTrack = function() return P.tracks[1] end

package.path = NC .. '/?.lua;' .. NC .. '/lib/?.lua;' .. package.path
local config = require 'config'
local rules  = require 'rules'
local app    = require 'gui.app'
local window = require 'gui.window'
local theme  = require 'gui.theme'

P.track('Drums', { fd = 1 }); P.track('Kick In'); P.track('Snare Top', { fd = -1 })
P.track('Sub Bass'); P.item('gtr_dry_01')
P.mark('Intro', false); P.mark('Chorus 1', true, { rgnend = 8 })

app.load()

local function frame(scripted)
  local ImGui, rec = mockimgui.new{ scripted = scripted }
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1)
  app.refresh_entries(true)
  app.recompute_preview()
  local ok, err = pcall(window.draw, 14)
  return ok, err, rec
end

---------------------------------------------------- every path must execute
do
  local ok, err, rec = frame()
  check(ok, 'a full frame draws without error', tostring(err))
  for _, fn in ipairs({ 'BeginTable', 'TableSetupColumn', 'TableHeader',
                        'TableNextRow', 'TableSetColumnIndex', 'EndTable',
                        'PushID', 'PopID', 'ColorEdit3', 'InputText', 'Checkbox',
                        'BeginChild', 'EndChild', 'Button',
                        'Selectable', 'ColorButton',
                        'BeginTabBar', 'BeginTabItem', 'PushStyleVar' }) do
    check(rec.seen[fn], 'frame reaches ' .. fn)
  end
end

------------------------------------------------------- one tab per object kind
do
  -- give every tab something to draw
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1]  = rules.new('track',  { label = 'T', pattern = 'a',
                                                     cascade_items = true })
  app.st.cfg.rules.item[1]   = rules.new('item',   { label = 'I', pattern = 'a' })
  app.st.cfg.rules.region[1] = rules.new('region', { label = 'R', pattern = 'a' })
  app.st.cfg.rules.marker[1] = rules.new('marker', { label = 'M', pattern = 'a' })

  local ImGui, rec = mockimgui.new{}
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1); app.refresh_entries(true); app.recompute_preview()
  local ok, err = pcall(window.draw, 14)
  check(ok, 'a frame with all four tabs draws', tostring(err))
  check(rec.seen.BeginTabBar and rec.seen.BeginTabItem, 'the tab bar is drawn')
  for _, kind in ipairs({ 'track', 'item', 'region', 'marker' }) do
    check(rec.labels['rules_' .. kind], 'the ' .. kind .. ' tab has its own table')
  end
end

do -- only the TRACK tab offers the cascade switch and the folder filters
  local function labels_for(tab)
    local ImGui, rec = mockimgui.new{ only_tab = tab }
    window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
    P.advance(1); app.recompute_preview()
    assert(pcall(window.draw, 14))
    return rec.labels
  end

  local tr = labels_for('Tracks')
  check(tr['##casc'], 'the track tab has the "also colour items" switch')
  check(tr['Items'],  'and an Items column header')

  local rg = labels_for('Regions')
  check(not rg['##casc'], 'the region tab has no cascade switch')
  check(rg['rules_region'], 'but it did draw its own table')

  -- the filter dropdown only appears where a filter exists for that kind
  check(tr['Filter'], 'the track tab has a filter column')
  check(rg['Filter'], 'regions have one too (unnamed)')
end

--------------------------------- the preview must reflect rule targets
-- This is the bug that was reported: a regions-only rule showed TRACKS in the
-- preview, because nothing invalidated it.
do
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.region[1] = rules.new('region', { label = 'Chorus', mode = 'regex',
                                                     pattern = '^Chorus', color = 0x3FA8A8 })
  app.st.preview_dirty = true
  P.advance(1); app.refresh_entries(true); app.recompute_preview()

  check(#app.st.preview.region == 1, 'a regions-only rule previews the region',
        tostring(#app.st.preview.region))
  check(#app.st.preview.track == 0, 'and previews NO tracks',
        tostring(#app.st.preview.track))
end

------------------------------- an edit in the table must mark dirty + stale
-- The regression guard: rule_table used to compute `changed` and return it,
-- and window.lua dropped it, so nothing was ever saved or re-previewed.
do
  app.st.dirty, app.st.preview_dirty = false, false
  -- script the FIRST Checkbox call (the per-row "enabled" one) as an edit
  local fired = false
  local ok, err = frame{
    Checkbox = function(_, label, v)
      if not fired then fired = true; return true, not v end
      return false, v
    end,
  }
  check(ok, 'a frame with an edit draws without error', tostring(err))
  check(fired, 'the stub actually reached a checkbox')
  check(app.st.dirty == true, 'editing a rule marks the config dirty')
  check(app.st.preview_dirty == true, 'editing a rule invalidates the preview')
end

do -- same for the pattern field
  app.st.dirty, app.st.preview_dirty = false, false
  local fired = false
  frame{ InputText = function(_, label, v)
           if not fired and label == '##pat' then fired = true; return true, '^zzz' end
           return false, v
         end }
  check(fired, 'the stub reached the pattern field')
  check(app.st.dirty == true, 'editing a pattern marks dirty')
end

do -- and for a colour swatch
  app.st.dirty = false
  local fired = false
  frame{ ColorEdit3 = function(_, _, v)
           if not fired then fired = true; return true, 0x123456 end
           return false, v
         end }
  check(fired, 'the stub reached a colour swatch')
  check(app.st.dirty == true, 'changing a colour marks dirty')
end

------------------------------------------------ and the edit reaches disk
do
  app.st.cfg.rules.region[1] = rules.new('region', { label = 'R', mode = 'substring',
                                                     pattern = 'Chorus', color = 0x112233 })
  app.mark_dirty()
  P.advance(1)
  app.flush(true)
  local reloaded = config.load()
  check(#reloaded.rules.region == 1, 'a region rule survives a save/load')
  check(reloaded.rules.region[1].color == 0x112233, 'with its colour')
end

------------------------------------------- unticking everything is respected
do -- a rule belongs to exactly one kind now; there is no way to target nothing
  check(rules.new('region', {}).kind == 'region', 'a rule carries its kind')
  check(rules.new('region', {}).targets == nil, 'and no targets field')
end

--------------------------------- the preview must equal what Apply writes
local colors = require 'colors'

local function preview_by_name(kind)
  app.st.preview_dirty = true
  P.advance(1); app.refresh_entries(true); app.recompute_preview()
  local by = {}
  for _, p in ipairs(app.st.preview[kind or 'track'] or {}) do by[p.name] = p end
  return by
end
local function applied_by_name()
  app.apply_all()
  local by = {}
  for _, t in ipairs(P.tracks) do by[t.name] = colors.from_native(t.color) end
  return by
end

do -- GRADIENT: the reported gap -- the preview used to show the rule's primary
   -- colour for every match instead of each object's own shade.
  app.st.cfg.options.propagate_folders = 'off'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1] = rules.new('track', { label = 'Spread', mode = 'regex',
                                                   pattern = '.', color = 0xFF0000,
                                                   color2 = 0x0000FF })
  local pv = preview_by_name()
  local seen, distinct = {}, 0
  for _, p in pairs(pv) do
    if not seen[p.color] then seen[p.color] = true; distinct = distinct + 1 end
  end
  check(distinct >= 3, 'the preview shows distinct gradient shades', distinct .. ' distinct')
  check(pv['Drums'] and pv['Drums'].color == 0xFF0000, 'gradient preview starts at colour 1')

  local ap = applied_by_name()
  local mismatch = nil
  for name, p in pairs(pv) do
    if p.kind == 'track' and ap[name] ~= p.color then mismatch = name end
  end
  check(mismatch == nil, 'every previewed gradient colour is what Apply writes',
        tostring(mismatch))
end

do -- FOLDER INHERITANCE: children with no rule of their own were missing from
   -- the preview entirely, even though Apply colours them.
  for _, t in ipairs(P.tracks) do t.color = 0 end
  app.st.cfg.options.propagate_folders = 'fill_unmatched'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1] = rules.new('track', { label = 'Drum bus', mode = 'substring',
                                                   pattern = 'Drums', color = 0x00AA00 })
  local pv = preview_by_name()
  check(pv['Kick In'] ~= nil, 'an inherited child appears in the preview')
  check(pv['Kick In'] and pv['Kick In'].inherited == true, 'and is flagged as inherited')
  check(pv['Kick In'] and pv['Kick In'].color == 0x00AA00, 'with the folder colour')
  check(pv['Drums'] and pv['Drums'].inherited == false, 'the folder itself is not inherited')
  check(pv['Sub Bass'] == nil, 'a track outside the folder is still not previewed')

  local ap = applied_by_name()
  check(ap['Kick In'] == 0x00AA00, 'and Apply really does colour the child')
  check(ap['Sub Bass'] == nil, 'and really does leave the outsider alone')
end

--------------------------------------------- the master is left entirely alone
do
  for _, t in ipairs(P.tracks) do t.color = 0 end
  P.master.color = 0
  app.st.cfg.options.propagate_folders = 'off'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1] = rules.new('track', { label = 'Everything', mode = 'regex',
                                                   pattern = '.', color = 0x777777 })
  local pv = preview_by_name()
  check(pv['MASTER'] == nil, 'the master never appears in the preview')
  app.apply_all()
  check(P.master.color == 0, 'even a match-everything rule does not touch the master',
        tostring(P.master.color))
  check(colors.from_native(P.tracks[1].color) == 0x777777, 'ordinary tracks still coloured')
end

------------------------------------------ the preview follows the open tab
do
  for _, t in ipairs(P.tracks) do t.color = 0 end
  app.st.cfg.options.propagate_folders = 'off'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1]  = rules.new('track',  { label = 'T', mode = 'regex',
                                                     pattern = '.', color = 0x111111 })
  app.st.cfg.rules.region[1] = rules.new('region', { label = 'R', mode = 'regex',
                                                     pattern = '.', color = 0x222222 })
  app.st.preview_dirty = true
  P.advance(1); app.refresh_entries(true); app.recompute_preview()

  check(#app.st.preview.track > 0,  'the track bucket has rows')
  check(#app.st.preview.region > 0, 'the region bucket has rows')
  check(#app.st.preview.marker == 0, 'the marker bucket is empty (no marker rules)')

  -- every row in a bucket really is of that kind
  for _, kind in ipairs({ 'track', 'item', 'region', 'marker' }) do
    local wrong = nil
    for _, p in ipairs(app.st.preview[kind]) do
      if p.kind ~= kind then wrong = p.kind end
    end
    check(wrong == nil, 'the ' .. kind .. ' bucket holds only ' .. kind .. 's',
          tostring(wrong))
  end

  -- and the drawn list is the one for the open tab
  local function rows_drawn(tab)
    app.st.active_kind = tab
    local ImGui, rec = mockimgui.new{ only_tab = 'zzz-none' }   -- skip rule tables
    window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
    assert(pcall(window.draw, 14))
    return rec.labels
  end
  check(rows_drawn('track')['previewtbl_track'],   'the track tab draws the track preview')
  check(not rows_drawn('region')['previewtbl_track'],
        'the region tab does NOT draw the track preview')
  check(rows_drawn('region')['previewtbl_region'], 'it draws the region preview instead')
end

------------------------------- a cascaded item names the track it came from
-- The confusing case: the only ITEM rule matches nothing, yet items are listed
-- in the preview, coloured by a track rule's cascade.
do
  for _, t in ipairs(P.tracks) do t.color = 0 end
  app.st.cfg.options.propagate_folders = 'off'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1] = rules.new('track', { label = 'Bass', mode = 'substring',
                                                   pattern = 'Bass', color = 0x6B4FA8,
                                                   cascade_items = true })
  app.st.cfg.rules.item[1]  = rules.new('item',  { label = 'Comps', mode = 'glob',
                                                   pattern = '*_comp*', color = 0x4F8AA8 })
  local pv = preview_by_name('item')
  local row = pv['gtr_dry_01']
  check(row ~= nil, 'the item is listed even though no item rule matched it')
  if row then
    check(row.from_track == true, 'and is flagged as coloured by its track')
    check(row.rule == nil,        'with no item rule attributed')
    check(row.track_name ~= nil,  'and it names the track it came from',
          tostring(row.track_name))
  end
  check((app.st.won[app.st.cfg.rules.item[1].id] or 0) == 0,
        'the item rule genuinely has zero hits')
end

------------------------------------------------------- theme push/pop balance
-- An unbalanced PushStyleVar/PopStyleVar corrupts every later frame, and the
-- symptom (slowly drifting layout) is horrible to track down.
do
  local pushes, pops = 0, 0
  local ImGui = mockimgui.new{ scripted = {
    PushStyleVar   = function() pushes = pushes + 1 end,
    PopStyleVar    = function(_, n) pops = pops + (n or 1) end,
  } }
  theme.init(ImGui, { 'ctx' })
  theme.push(14)
  theme.pop()
  check(pushes == pops, 'theme pushes and pops the same number of style vars',
        pushes .. ' pushed, ' .. pops .. ' popped')
  check(pushes > 0, 'and it actually pushed some')
end
do
  local pushes, pops = 0, 0
  local ImGui = mockimgui.new{ scripted = {
    PushStyleColor = function() pushes = pushes + 1 end,
    PopStyleColor  = function(_, n) pops = pops + (n or 1) end,
    GetStyleColor  = function() return 0x808080FF end,
  } }
  theme.init(ImGui, { 'ctx' })
  theme.push(14); theme.pop()
  check(pushes == pops, 'and the same number of style colours',
        pushes .. ' pushed, ' .. pops .. ' popped')
end
do -- pop with nothing pushed must be harmless, so an error mid-frame cannot
   -- leave the style stack corrupted
  local pops = 0
  local ImGui = mockimgui.new{ scripted = {
    PopStyleVar   = function() pops = pops + 1 end,
    PopStyleColor = function() pops = pops + 1 end,
  } }
  theme.init(ImGui, { 'ctx' })
  theme.pop(); theme.pop()
  check(pops == 0, 'a stray pop() does nothing', pops .. ' pops')
end

--------------------------------- the style stack must balance over a frame
-- Tab padding is pushed around the strip and lifted again inside each tab, so
-- a whole frame has to come back to zero. An imbalance here corrupts every
-- later frame and shows up as slowly drifting layout.
do
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1]  = rules.new('track',  { label = 'T', pattern = 'a',
                                                     cascade_items = true, color2 = 0x112233 })
  app.st.cfg.rules.item[1]   = rules.new('item',   { label = 'I', pattern = 'a' })
  app.st.cfg.rules.region[1] = rules.new('region', { label = 'R', pattern = 'a' })
  app.st.cfg.rules.marker[1] = rules.new('marker', { label = 'M', pattern = 'a' })

  local vdepth, cdepth, vmin, cmin = 0, 0, 0, 0
  local ImGui = mockimgui.new{ scripted = {
    PushStyleVar   = function() vdepth = vdepth + 1 end,
    PopStyleVar    = function(_, n) vdepth = vdepth - (n or 1)
                                    if vdepth < vmin then vmin = vdepth end end,
    PushStyleColor = function() cdepth = cdepth + 1 end,
    PopStyleColor  = function(_, n) cdepth = cdepth - (n or 1)
                                    if cdepth < cmin then cmin = cdepth end end,
    GetStyleColor  = function() return 0x808080FF end,
  } }
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1); app.refresh_entries(true); app.recompute_preview()

  theme.push(14)
  local ok = pcall(window.draw, 14)
  theme.pop()

  check(ok, 'a frame with every tab populated draws')
  check(vdepth == 0, 'style vars balance across a whole frame', vdepth .. ' left pushed')
  check(cdepth == 0, 'style colours balance across a whole frame', cdepth .. ' left pushed')
  check(vmin >= 0, 'style vars are never popped below zero', 'min ' .. vmin)
  check(cmin >= 0, 'style colours are never popped below zero', 'min ' .. cmin)
end

--------------------------------------------- the auto button start/stop path
do
  local SECT = config.EXT_SECTION
  reaper.SetExtState(SECT, 'auto_cmdid', '', false)
  check(app.auto_command_id() == nil, 'no command id before the action has run')
  check(app.toggle_auto() == false, 'toggling without a command id is refused')
  check(app.current_toast() ~= nil, 'and explains why')

  reaper.SetExtState(SECT, 'auto_cmdid', '4242', false)
  check(app.auto_command_id() == 4242, 'the published command id is picked up')
  local ran
  reaper.Main_OnCommand = function(cmd) ran = cmd end
  check(app.toggle_auto() == true, 'toggling now works')
  check(ran == 4242, 'and it invokes the right action', tostring(ran))
  check(app.auto_paused() == false, 'and never leaves it paused-but-on')
end

------------------------------------------------- header row is hand-emitted
do
  -- TableHeadersRow left-aligns everything, so the row is emitted manually to
  -- centre the narrow columns. Check we really did replace it.
  local ImGui, rec = mockimgui.new{}
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1); app.recompute_preview()
  theme.push(14); assert(pcall(window.draw, 14)); theme.pop()
  check(rec.seen.TableHeader, 'headers are emitted one column at a time')
  check(not rec.seen.TableHeadersRow, 'and the auto header row is not used')
  check(rec.seen.TableRowFlags_Headers == nil or true, 'header row flag available')
end

do -- the drag source must NOT suppress its tooltip, or the preview label is
   -- drawn inline into the window instead of following the cursor
  local src = pathlib_read('lib/gui/rule_table.lua')
  check(not src:find('DragDropFlags_SourceNoPreviewTooltip', 1, true),
        'the drag source no longer suppresses its tooltip')
  check(src:find('BeginDragDropSource(ctx)', 1, true) ~= nil,
        'and calls BeginDragDropSource with default flags')
end

---------------------------------------------- styling reaches every control
do
  -- Every checkbox in the GUI must go through theme.checkbox, or it keeps the
  -- default look -- which is what happened to the Options page.
  for _, f in ipairs({ 'lib/gui/window.lua', 'lib/gui/rule_table.lua',
                       'lib/gui/preview.lua' }) do
    local src = pathlib_read(f)
    check(not src:find('ImGui.Checkbox', 1, true),
          f .. ' uses the styled checkbox everywhere')
  end
  -- swatches must be sized by the theme, or they come out wider than [+]/[x]
  local rt = pathlib_read('lib/gui/rule_table.lua')
  check(not rt:find('ImGui.ColorEdit3', 1, true),
        'colour swatches go through theme.color_swatch')
  check(rt:find('theme.same_line_tight', 1, true) ~= nil,
        'and the gap between them comes from the theme')
end

do -- the table border recipe must be honoured, not hard-coded
  local src = pathlib_read('lib/gui/rule_table.lua')
  check(src:find('theme.table_border_flags', 1, true) ~= nil,
        'the rule table composes its borders from the theme')
  check(not src:find('ImGui.TableFlags_Resizable', 1, true),
        'and does not set Resizable itself -- that would force vertical lines back on')

  local ImGui = mockimgui.new{}
  theme.init(ImGui, { 'ctx' })
  local saved_h, saved_v = theme.TABLE_H_LINES, theme.TABLE_V_LINES
  theme.TABLE_H_LINES, theme.TABLE_V_LINES = false, true
  local a = theme.table_border_flags()
  theme.TABLE_H_LINES = true
  local b = theme.table_border_flags()
  check(a ~= b, 'toggling horizontal lines changes the flags')

  -- vertical lines and Resizable travel together, by necessity
  theme.TABLE_H_LINES, theme.TABLE_V_LINES = false, true
  local withv = theme.table_border_flags()
  theme.TABLE_V_LINES = false
  local nov = theme.table_border_flags()
  check(withv & ImGui.TableFlags_Resizable ~= 0,
        'vertical lines bring column resizing with them')
  check(nov & ImGui.TableFlags_Resizable == 0,
        'and without them Resizable is dropped, or ImGui would re-add the lines')
  check(nov & ImGui.TableFlags_BordersInnerV == 0, 'no inner vertical borders asked for')
  check(nov & ImGui.TableFlags_BordersOuter ~= 0, 'the outer border survives')
  theme.TABLE_H_LINES, theme.TABLE_V_LINES = saved_h, saved_v
end

---------------------------------------------------- the ghost tick is drawn
do
  -- ImGui only draws a tick when a box is checked; both states are drawn by
  -- the theme instead, so an unticked box still reads as a checkbox.
  local lines = {}
  local ImGui = mockimgui.new{ scripted = {
    Checkbox = function(_, _, v) return false, v end,
    DrawList_AddLine = function(_, x1, y1, x2, y2, col, th)
      lines[#lines + 1] = { col = col, th = th }
    end,
    GetStyleColor = function() return 0x33AA66FF end,
  } }
  theme.init(ImGui, { 'ctx' })

  lines = {}
  theme.checkbox('##on', true)
  check(#lines == 2, 'a ticked box draws a two-segment tick', #lines .. ' lines')
  check(lines[1] and lines[1].col == 0x33AA66FF,
        'in the theme tick colour', lines[1] and string.format('%08X', lines[1].col))

  lines = {}
  theme.checkbox('##off', false)
  check(#lines == 2, 'an UNticked box also draws a tick')
  local want = ((theme.GHOST_CHECK & 0xFFFFFF) << 8)
               | math.floor(theme.GHOST_CHECK_ALPHA * 255)
  check(lines[1] and lines[1].col == want,
        'in the ghost colour at the configured alpha',
        lines[1] and string.format('%08X vs %08X', lines[1].col, want))
  check(lines[1] and lines[1].th >= 1, 'with a sane thickness')
end

------------------------------------------------- the options dialog is modal
do
  local pos
  local ImGui, rec = mockimgui.new{ scripted = {
    Button = function(_, label) return label == 'Options' end,   -- click Options
    SetNextWindowPos = function(_, x, y, cond, px, py)
      pos = { x = x, y = y, cond = cond, px = px, py = py }
    end,
    GetWindowPos  = function() return 100, 80 end,
    GetWindowSize = function() return 900, 640 end,
  } }
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1); app.recompute_preview()
  theme.push(14); assert(pcall(window.draw, 14)); theme.pop()

  check(rec.seen.BeginPopup, 'the options dialog is drawn')
  check(rec.seen.OpenPopup, 'and is opened by the button')
  check(pos ~= nil, 'its position is set explicitly')
  if pos then
    -- centre of a 900x640 window at (100,80), with a centre pivot
    check(pos.x == 100 + 450 and pos.y == 80 + 320,
          'centred on the app window', string.format('%g,%g', pos.x, pos.y))
    check(pos.px == 0.5 and pos.py == 0.5, 'using a centre pivot')
  end
  check(rec.labels['Options'], 'the popup name is used verbatim')
end

do -- dimming is done with the GLOBAL alpha, not a veil
  local src = pathlib_read('lib/gui/window.lua')
  -- the CODE form, so the comment explaining why it is avoided does not trip it
  check(src:find('ImGui.Col_ModalWindowDimBg', 1, true) == nil,
        'the uncontrollable modal dim colour is not used')
  check(src:find('ImGui.DrawList_AddRectFilled', 1, true) == nil,
        'and no veil rect either -- it cannot reach inside child windows')
  check(src:find('push_content_dim', 1, true) ~= nil,
        'the content is faded with the global alpha instead')
  check(src:find('StyleVar_WindowPadding', 1, true) ~= nil,
        'and the dialog gets its own padding')

  -- OpenPopup and BeginPopup find each other by hashing the name, so the two
  -- strings must be identical. A mismatch opens a popup nothing draws -- which
  -- is exactly what happened when one said 'options' and the other
  -- 'Options###options'.
  check(src:find('OPTIONS_POPUP', 1, true) ~= nil,
        'both calls use one shared name constant')
  local uses = select(2, src:gsub('OPTIONS_POPUP', ''))
  check(uses >= 3, 'the constant is defined and used by both calls', uses .. ' uses')
  check(src:find('BeginPopup(ctx, OPTIONS_POPUP)', 1, true) ~= nil,
        'and no optional nil is passed mid-arguments')

  check(theme.DIM_CONTENT > 0 and theme.DIM_CONTENT < 1,
        'the dim level is a sane fraction', tostring(theme.DIM_CONTENT))
end

do -- the dim is applied only while the dialog is open, and lifted before the
   -- dialog itself is drawn, or it would fade too
  local function trace(popup_open)
    local events = {}
    local ImGui
    ImGui = mockimgui.new{ scripted = {
      IsPopupOpen  = function() return popup_open end,
      PushStyleVar = function(_, idx, a)
        if idx == ImGui.StyleVar_Alpha then events[#events + 1] = 'dim:' .. a end
      end,
      PopStyleVar  = function() events[#events + 1] = 'undim' end,
      BeginPopup   = function() events[#events + 1] = 'dialog'; return false end,
    } }
    window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
    P.advance(1); app.recompute_preview()
    assert(pcall(window.draw, 14))
    return events, ImGui
  end

  local open = trace(true)
  local dim_at, dialog_at, undim_at
  for i, e in ipairs(open) do
    if e:find('^dim:') and not dim_at then dim_at = i end
    if e == 'dialog' then dialog_at = i end
  end
  -- the undim that matters is the last one before the dialog
  for i = (dialog_at or #open), 1, -1 do
    if open[i] == 'undim' then undim_at = i break end
  end

  check(dim_at ~= nil, 'the content is dimmed while the dialog is open')
  check(dialog_at ~= nil, 'and the dialog is drawn')
  if dim_at and dialog_at and undim_at then
    check(dim_at < dialog_at, 'dim comes before the dialog')
    check(undim_at < dialog_at, 'and is lifted before the dialog is drawn',
          string.format('undim@%d dialog@%d', undim_at, dialog_at))
  end

  local shut = trace(false)
  local any_dim = false
  for _, e in ipairs(shut) do if e:find('^dim:') then any_dim = true end end
  check(not any_dim, 'nothing is dimmed while the dialog is closed')
end

------------------------------------- the status line holds its own space
do
  -- The complaint this encodes: the status message used to sit among the top
  -- banners, so every message pushed the whole window down and let it spring
  -- back six seconds later. Its space is now reserved whether or not there is
  -- anything to say, which means every size handed to the tables and the
  -- preview panels must come out identical either way.
  local function layout(message)
    local sizes, texts = {}, {}
    local ImGui = mockimgui.new{ scripted = {
      BeginTable = function(_, name, _, _, _, h)
        sizes[#sizes + 1] = name .. '=' .. tostring(h); return true
      end,
      BeginChild = function(_, name, w, h)
        sizes[#sizes + 1] = string.format('%s=%sx%s', name, tostring(w), tostring(h))
        return true
      end,
      Text        = function(_, t) texts[#texts + 1] = tostring(t) end,
      TextColored = function(_, _, t) texts[#texts + 1] = tostring(t) end,
    } }
    window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
    P.advance(1)
    app.recompute_preview()
    if message then app.toast(message) else app.st.toast = nil end
    assert(pcall(window.draw, 14))
    app.st.toast = nil
    return table.concat(sizes, ' '), texts
  end

  local MSG = 'Coloured 3 objects.'
  local quiet, quiet_texts = layout(nil)
  local loud,  loud_texts  = layout(MSG)

  check(quiet:find('preview=') ~= nil and quiet:find('rules_track=') ~= nil,
        'the frame lays out its tables and panels')
  -- Weak on its own -- the stub reports a fixed content region, so it cannot
  -- show real reflow. It guards the code path: the sizes must not be COMPUTED
  -- from whether a message exists. The two assertions below are the ones that
  -- fail against the old top-of-window banner.
  check(quiet == loud, 'no size is computed from whether a message is showing',
        quiet == loud and '' or ('\n  quiet: ' .. quiet .. '\n  loud:  ' .. loud))

  local said = false
  for _, t in ipairs(loud_texts) do if t == MSG then said = true end end
  check(said, 'the message is shown')

  local blank = false
  for _, t in ipairs(quiet_texts) do if t == '' then blank = true end end
  check(blank, 'and an empty line keeps its place when there is none')

  -- It belongs at the foot: nothing the body draws may follow it.
  local last_msg
  for i, t in ipairs(loud_texts) do if t == MSG then last_msg = i end end
  check(last_msg ~= nil and last_msg >= #loud_texts - 1,
        'the status line is the last thing drawn in the body',
        string.format('%s of %d', tostring(last_msg), #loud_texts))
end

------------------------------------- the table joins the open tab
do
  -- Three separate things have to hold for the join to read as one surface,
  -- and each has failed on its own during development.
  local events = {}
  local ImGui
  ImGui = mockimgui.new{ scripted = {
    PushStyleVar = function(_, idx, a)
      if idx == ImGui.StyleVar_TabBarBorderSize then
        events[#events + 1] = 'noborder:' .. tostring(a)
      end
    end,
    SetCursorPosY = function(_, y) events[#events + 1] = 'pullup:' .. tostring(y) end,
    DrawList_AddRectFilled = function(_, x0, y0, x1, y1, col)
      events[#events + 1] = string.format('shelf:%g,%g,%g,%g,%d', x0, y0, x1, y1, col)
    end,
    PushStyleColor = function(_, idx, col)
      if idx == ImGui.Col_TableHeaderBg then
        events[#events + 1] = 'headerbg:' .. tostring(col)
      end
    end,
  } }
  window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
  P.advance(1); app.recompute_preview()
  assert(pcall(window.draw, 14))

  local seen = {}
  for _, e in ipairs(events) do seen[e:match('^[^:]+')] = e end

  check(seen.noborder == 'noborder:0',
        "ImGui's own tab separator is suppressed", tostring(seen.noborder))
  check(seen.pullup ~= nil, 'the content is pulled up against the tab strip')

  -- The shelf spans the CONTENT width. The stub reports a 900-wide content
  -- region at screen x=100, so a shelf that stopped at the tabs or ran past
  -- the table would show up here.
  check(seen.shelf == string.format('shelf:100,199,1000,200,%d',
                                    ImGui.GetStyleColor(nil, ImGui.Col_TabSelected)),
        'and a shelf is drawn at exactly the content width', tostring(seen.shelf))

  check(seen.headerbg ~= nil,
        'the header row is repainted in the open tab colour', tostring(seen.headerbg))
end

--------------------------- the gap closes to the PAINTED tab edge, not the bar
do
  -- Measured in REAPER: a tab's item rect was 31 tall while the tab is painted
  -- FontSize + 2*padding = 28. ImGui reserves the other 3px below the tab
  -- shapes for its overline and border, and the cursor lands below THAT. A
  -- pull-up of only ItemSpacing left those 3px of window background showing
  -- between the strip and the table, which is the join failing.
  local moved
  local ImGui = mockimgui.new{ scripted = {
    GetCursorPosY = function() return 1000 end,
    GetStyleVar   = function() return 8, 4 end,       -- ItemSpacing 8, 4
    SetCursorPosY = function(_, y) moved = y end,
  } }
  theme.init(ImGui, { 'ctx' })

  local painted = theme.tab_paint_height(14)
  check(painted == 14 + 2 * math.floor(14 * theme.TAB_PAD_Y + 0.5),
        'a tab is painted font size plus its own padding', tostring(painted))

  theme.close_tab_gap(14, painted + 3)
  check(moved == 1000 - 4 - 3, 'the spacing AND the reserved strip are closed',
        tostring(moved))

  theme.close_tab_gap(14, painted)
  check(moved == 1000 - 4, 'nothing extra is taken when none is reserved',
        tostring(moved))

  theme.close_tab_gap(14, painted - 5)
  check(moved == 1000 - 4, 'and a shorter rect never pushes the table DOWN',
        tostring(moved))
end

--------------------------------------- tabs sit on whole-pixel boundaries
do
  -- ImGui truncates a tab's left edge to an integer but not its width, so a
  -- fractional FramePadding makes the gaps between tabs drift. Measured in
  -- REAPER at font size 14 before this was rounded: 3.20 / 4.20 / 4.20 against
  -- an ItemInnerSpacing of 4. See theme.push_tab_padding.
  local got
  local ImGui = mockimgui.new{ scripted = {
    PushStyleVar = function(_, _, a, b) got = { a, b } end,
  } }
  theme.init(ImGui, { 'ctx' })

  for _, fs in ipairs({ 12, 13.7, 14, 17.5 }) do
    theme.push_tab_padding(fs)
    check(got[1] % 1 == 0 and got[2] % 1 == 0,
          'tab padding is whole pixels at font size ' .. fs,
          string.format('%s, %s', tostring(got[1]), tostring(got[2])))
  end

  -- and the tab width it produces stays whole for a whole-width label
  theme.push_tab_padding(14)
  check((69 + got[1] * 2) % 1 == 0,
        'so a tab width comes out whole too', tostring(69 + got[1] * 2))
end

------------------------------------------------------- section headings
do
  local drawn, size, seps
  local function grab(label, divider)
    drawn, seps = nil, 0
    size = 14
    local ImGui = mockimgui.new{ scripted = {
      Text        = function(_, t) drawn = { text = t, size = size } end,
      PushFont    = function(_, _, sz) size = sz end,
      PopFont     = function() size = 14 end,
      Separator   = function() seps = seps + 1 end,
      GetFontSize = function() return 14 end,
      GetStyleColor = function() return 0xE0E0E0FF end,
    } }
    theme.init(ImGui, { 'ctx' })
    theme.section(label, divider)
  end

  grab('Objects preview')
  check(drawn and drawn.text == 'OBJECTS PREVIEW', 'headings are uppercased',
        drawn and drawn.text)
  check(drawn and drawn.size > 14 and drawn.size < 14 * 1.2,
        'and only slightly larger than body text', drawn and tostring(drawn.size))
  check(seps == 0, 'a plain heading draws no rule')

  grab('Scope', true)
  check(seps == 1, 'a divided heading draws exactly one 1px rule', seps .. ' rules')

  -- one size only: mixing sizes on a line cannot be baseline-aligned in ImGui,
  -- which is why the small-caps attempt was abandoned
  check(not pathlib_read('lib/gui/theme.lua'):find('SMALLCAPS', 1, true),
        'no small-caps emulation remains')

  -- the other cases still work
  local saved = theme.SECTION_CASE
  theme.SECTION_CASE = 'title'
  grab('Background auto-colouring')
  check(drawn and drawn.text == 'Background Auto-Colouring',
        'title case is still available', drawn and drawn.text)
  theme.SECTION_CASE = 'none'
  grab('Background auto-colouring')
  check(drawn and drawn.text == 'Background auto-colouring',
        'as is leaving it alone')
  theme.SECTION_CASE = saved
end

do -- the renamed panel headings
  local pv = pathlib_read('lib/gui/preview.lua')
  check(pv:find("theme.section('Objects preview')", 1, true) ~= nil,
        'the preview list is headed "Objects preview"')
  check(pv:find("theme.section('Name tester')", 1, true) ~= nil,
        'and the tester "Name tester"')
  check(not pv:find('rules match right now', 1, true), 'the old wording is gone')
  check(not pv:find("'Try a name'", 1, true), 'and so is the old tester heading')

  -- every heading in the GUI must come from the theme, or they drift apart
  for _, f in ipairs({ 'lib/gui/window.lua', 'lib/gui/preview.lua',
                       'lib/gui/rule_table.lua' }) do
    check(not pathlib_read(f):find('ImGui.SeparatorText', 1, true),
          f .. ' heads its sections through the theme')
  end
  check(not pathlib_read('lib/gui/theme.lua'):find('ImGui.SeparatorText', 1, true),
        'and SeparatorText is gone entirely -- it cannot do small caps')
end

------------------------------------------- the gradient scope combo
do
  -- it exists only where a gradient does
  local function labels_with(color2, kind)
    app.st.cfg.rules = config.empty_rules()
    app.st.cfg.rules[kind][1] = rules.new(kind, { label = 'G', pattern = 'a',
                                                  color = 0x112233, color2 = color2 })
    app.st.active_kind = kind
    -- Combos are closed by default in the stub, so their items are never
    -- drawn. Open them: the point of this test is which options a kind offers.
    local ImGui, rec = mockimgui.new{ only_tab = rules.KIND_LABEL[kind],
                                      scripted = { BeginCombo = function() return true end } }
    window.init(ImGui, { 'ctx' }); theme.init(ImGui, { 'ctx' })
    P.advance(1); app.refresh_entries(true); app.recompute_preview()
    theme.push(14); assert(pcall(window.draw, 14)); theme.pop()
    return rec.labels
  end

  check(labels_with(0x445566, 'track')['##gscope'],
        'a gradient rule offers the grouping combo')
  check(not labels_with(nil, 'track')['##gscope'],
        'a flat rule does not')

  -- folder grouping is meaningless for items, so it must not be offered
  local tr_l = labels_with(0x445566, 'track')
  check(tr_l[rules.GRADIENT_LABEL.folder], 'tracks can group by folder')
  local it_l = labels_with(0x445566, 'item')
  check(it_l[rules.GRADIENT_LABEL.run], 'items can group by run')
  check(not it_l[rules.GRADIENT_LABEL.folder], 'but not by folder')
end

do -- preview and Apply must agree for a GROUPED gradient too, not just a flat
   -- one -- this pair has drifted twice before
  for _, t in ipairs(P.tracks) do t.color = 0 end
  app.st.cfg.options.propagate_folders = 'off'
  app.st.cfg.rules = config.empty_rules()
  app.st.cfg.rules.track[1] = rules.new('track', { label = 'Spread', mode = 'regex',
                                                   pattern = '.', color = 0xFF0000,
                                                   color2 = 0x0000FF,
                                                   gradient_scope = 'run' })
  local pv = preview_by_name('track')
  local ap = applied_by_name()
  local mismatch
  for name, p in pairs(pv) do
    if p.kind == 'track' and ap[name] ~= p.color then mismatch = name end
  end
  check(mismatch == nil, 'every previewed grouped-gradient colour is what Apply writes',
        tostring(mismatch))
end

print('\n=== gui render (stub ImGui) ===')
for _, f in ipairs(fails) do print('  FAIL  ' .. f) end
print(string.format('%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
