-- End-to-end: run the real action scripts against a mock REAPER.
package.path = os.getenv('SP') .. '/?.lua;' .. package.path
local mock = require 'mockreaper'

local NC  = os.getenv('NC')
local TMP = os.getenv('SP') .. '/proj'
os.execute('rm -rf "' .. TMP .. '" && mkdir -p "' .. TMP .. '/NameColorizer"')

local pass, fail, fails = 0, 0, {}
local function check(ok, label, detail)
  if ok then pass = pass + 1
  else fail = fail + 1; fails[#fails+1] = label .. (detail and ('  -- ' .. detail) or '') end
end

local P = mock.install{ resource = TMP, script = NC .. '/MB_NameColorizer_ApplyAll.lua' }

package.path = NC .. '/?.lua;' .. NC .. '/lib/?.lua;' .. package.path
local config = require 'config'
local rules  = require 'rules'
local colors = require 'colors'

--------------------------------------------------------------- the project
-- Mirrors the scenario in the plan: master, a folder with two children, a
-- non-ASCII name, an item with no take, an item with a named take, a marker
-- and a region.
local RED, ORANGE, PURPLE, BLUE, GREEN, TEAL = 0xB5453C, 0xC97B3F, 0x6B4FA8, 0x3F7FA8, 0x4FA85C, 0x3FA8A8

local t_drums = P.track('Drums', { fd = 1 })
local t_kick  = P.track('Kick In')
local t_snare = P.track('Snare Top', { fd = -1 })
local t_cz    = P.track('Kytara_hlavn\195\173')
local t_bass  = P.track('Sub Bass', { sel = true })
P.item(nil,          { track = t_kick })   -- empty item, no take at all
P.item('gtr_dry_03', { track = t_cz, sel = true })
P.item('',           { track = t_cz })     -- a take with a blank name
P.item('anything',   { track = t_bass })   -- name matches nothing; cascade target
P.mark('Intro', false)
P.mark('Chorus 1', true, { rgnend = 8.0 })

--------------------------------------------------------------- the rules
local cfg = config.defaults()
local function r(kind, o)
  local l = cfg.rules[kind]; l[#l + 1] = rules.new(kind, o)
end
r('track', { label = 'Kick',  mode = 'regex', pattern = '^kick\\b', color = RED })
r('track', { label = 'Snare', mode = 'regex', pattern = '^snare\\b', color = ORANGE })
r('track', { label = 'Bass',  mode = 'regex', pattern = '\\bbass\\b', color = PURPLE,
             cascade_items = true })
r('track', { label = 'Drum bus', mode = 'substring', pattern = 'drum', only = 'folder',
             color = GREEN })
r('item',  { label = 'Gtr items', mode = 'glob', pattern = 'gtr_*', color = BLUE })
r('region',{ label = 'Chorus', mode = 'regex', pattern = '^Chorus', color = TEAL })
assert(config.save(cfg))

------------------------------------------------------------------ apply all
dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')

local function tcolor(name)
  for _, t in ipairs(P.tracks) do
    if t.name == name then return colors.from_native(t.color) end
  end
  return 'NO SUCH TRACK'
end
local function icolor(i) return colors.from_native(P.items[i].color) end
local function mcolor(name)
  for _, m in ipairs(P.marks) do
    if m.name == name then return colors.from_native(m.color) end
  end
end

check(tcolor('Drums')     == GREEN,  'folder predicate coloured the bus', tostring(tcolor('Drums')))
check(tcolor('Kick In')   == RED,    'child matched its own rule')
check(tcolor('Snare Top') == ORANGE, 'second child matched its own rule')
check(tcolor('Sub Bass')  == PURPLE, 'bass rule matched')
check(tcolor('Kytara_hlavn\195\173') == nil, 'unmatched non-ASCII track left alone')
check(P.master.color == 0, 'master track untouched by default')
check(icolor(1) == nil,  'item with no take is left alone')
check(icolor(2) == BLUE, 'item matched on its active take name')
check(icolor(3) == nil,  'item with a blank take name is left alone')
check(icolor(4) == PURPLE, 'an item with no matching name takes its track colour',
      tostring(icolor(4)))
check(mcolor('Chorus 1') == TEAL, 'region rule matched')
check(mcolor('Intro') == nil, 'marker not targeted by any rule')

check(#P.undo == 1 and P.undo[1].open == false, 'exactly one undo block, closed')
do
  local f = P.undo[1].flags
  -- tracks(1) + items(4) + markers(8) were all written
  check(f == (1|4|8), 'undo flags cover only what was written', 'got ' .. tostring(f))
end

------------------------------------------------- idempotence (the key property)
local before = #P.undo
P.console = {}
dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')
check(#P.undo == before, 'a second Apply writes nothing and adds NO undo point',
      (#P.undo - before) .. ' new undo blocks')
check(P.consoletext():find('already up to date') ~= nil,
      'second Apply reports that it is up to date', P.consoletext())

------------------------------------------------------------ folder policies
do
  local c2 = config.load()
  c2.options.propagate_folders = 'force'
  assert(config.save(c2))
  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')
  check(tcolor('Kick In') == GREEN, 'force policy overrides a matched child')

  c2 = config.load(); c2.options.propagate_folders = 'fill_unmatched'
  assert(config.save(c2))
  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')
  check(tcolor('Kick In') == RED, 'switching back restores the child rule')
end

--------------------------------------------------------------- apply selection
do
  for _, t in ipairs(P.tracks) do t.color = 0 end
  for _, it in ipairs(P.items) do it.color = 0 end
  _G.reaper.get_action_context = function()
    return false, NC .. '/MB_NameColorizer_ApplySelection.lua', 0, 1, 0, 0, 0, ''
  end
  dofile(NC .. '/MB_NameColorizer_ApplySelection.lua')
  check(tcolor('Sub Bass') == PURPLE, 'selection apply coloured the selected track')
  check(tcolor('Kick In') == nil,     'selection apply left unselected tracks alone')
  check(icolor(2) == BLUE,            'selection apply coloured the selected item')
  check(icolor(4) == nil,             'and left unselected items alone')
end

--------------------------------------------------------------- clear colours
do
  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')     -- colour everything again
  check(tcolor('Kick In') == RED, 'recoloured before the clear test')

  -- answer the Yes/No/Cancel box with NO = "everything the rules match"
  local P2 = P
  _G.reaper.ShowMessageBox = function(msg, title, kind)
    P2.boxes[#P2.boxes+1] = { msg = msg, title = title, kind = kind }
    if kind == 3 then return 7 end                   -- NO
    return 1
  end
  _G.reaper.get_action_context = function()
    return false, NC .. '/MB_NameColorizer_ClearColors.lua', 0, 1, 0, 0, 0, ''
  end
  dofile(NC .. '/MB_NameColorizer_ClearColors.lua')

  check(tcolor('Kick In') == nil,   'clear reset a matched track')
  check(tcolor('Drums') == nil,     'clear reset the folder bus')
  check(mcolor('Chorus 1') == nil,  'clear reset the region (modern marker API)')
end

--------------------------------- older REAPER: markers cannot be cleared
do
  local P3 = mock.install{ resource = TMP, no_modern_markers = true,
                           script = NC .. '/MB_NameColorizer_ApplyAll.lua' }
  P3.now = 1000
  P3.track('Sub Bass'); P3.mark('Chorus 1', true, { rgnend = 8.0 })
  package.loaded['targets'] = nil                     -- re-probe APIExists
  local targets = require 'targets'
  check(targets.can_clear_markers() == false, 'older REAPER reports it cannot clear markers')
  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')
  local col
  for _, m in ipairs(P3.marks) do if m.name == 'Chorus 1' then col = m.color end end
  check(require('colors').from_native(col) == TEAL,
        'region still gets COLOURED on the fallback path')
end

--------------------------------------------------- take colours mask items
-- The real-world case: a take carries a custom colour, so the item's own
-- colour is invisible, and copy/paste drags that take colour to another track.
do
  local P4 = mock.install{ resource = TMP, script = NC .. '/MB_NameColorizer_ApplyAll.lua' }
  P4.now = 1000
  package.loaded['targets'] = nil; package.loaded['apply'] = nil
  local targets = require 'targets'
  local apply   = require 'apply'
  local colors2 = require 'colors'

  local STRUM, STRINGS = 0xCC5533, 0x3355CC
  local t_strum   = P4.track('Strum')
  local t_strings = P4.track('Strings')

  local c = config.defaults()
  c.options.propagate_folders = 'off'
  c.rules.track[1] = rules.new('track', { label = 'Strum', mode = 'substring',
                                          pattern = 'Strum', color = STRUM,
                                          cascade_items = true })
  c.rules.track[2] = rules.new('track', { label = 'Strings', mode = 'substring',
                                          pattern = 'Strings', color = STRINGS,
                                          cascade_items = true })
  assert(config.save(c))

  -- an item pasted onto Strings whose TAKE carries the old Strum colour
  local pasted = P4.item('06-Strum', { track = t_strings,
                                       take_color = colors2.to_native(STRUM) })
  check(colors2.from_native(pasted.take.color) == STRUM, 'the take starts out coloured')

  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')

  check(colors2.from_native(pasted.color) == STRINGS,
        'the item gets its track colour', tostring(colors2.from_native(pasted.color)))
  check(colors2.norm(pasted.take.color) == 0,
        'and the take colour is cleared so it is actually visible',
        tostring(colors2.from_native(pasted.take.color)))
  check(colors2.from_native(reaper.GetDisplayedMediaItemColor2(pasted, pasted.take)) == STRINGS,
        'REAPER would now display the item colour')

  -- an item whose item colour is ALREADY right but is masked by a take colour
  -- must still be fixed, not skipped as "up to date"
  local masked = P4.item('anything', { track = t_strings,
                                       color = colors2.to_native(STRINGS),
                                       take_color = colors2.to_native(STRUM) })
  dofile(NC .. '/MB_NameColorizer_ApplyAll.lua')
  check(colors2.norm(masked.take.color) == 0,
        'an item with the right colour but a masking take is still fixed')

  -- and Clear releases both
  _G.reaper.ShowMessageBox = function(_, _, kind) return kind == 3 and 7 or 1 end
  _G.reaper.get_action_context = function()
    return false, NC .. '/MB_NameColorizer_ClearColors.lua', 0, 1, 0, 0, 0, ''
  end
  local stale = P4.item('x', { track = t_strings, take_color = colors2.to_native(STRUM) })
  dofile(NC .. '/MB_NameColorizer_ClearColors.lua')
  check(colors2.norm(stale.take.color) == 0,
        'Clear releases a take colour even when the item had none')
end

------------------------------------------------------------------- report
print('\n=== integration (mock REAPER) ===')
for _, f in ipairs(fails) do print('  FAIL  ' .. f) end
print(string.format('%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
