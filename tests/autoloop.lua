package.path = os.getenv('SP') .. '/?.lua;' .. package.path
local mock = require 'mockreaper'
local NC, TMP = os.getenv('NC'), os.getenv('SP') .. '/proj2'
os.execute('rm -rf "' .. TMP .. '" && mkdir -p "' .. TMP .. '/NameColorizer"')

local pass, fail, fails = 0, 0, {}
local function check(ok, label, detail)
  if ok then pass = pass + 1
  else fail = fail + 1; fails[#fails+1] = label .. (detail and ('  -- ' .. detail) or '') end
end

local P = mock.install{ resource = TMP, script = NC .. '/x.lua' }
package.path = NC .. '/?.lua;' .. NC .. '/lib/?.lua;' .. package.path

local config, rules, colors = require 'config', require 'rules', require 'colors'
local autoloop = require 'autoloop'

local RED, BLUE, PINK = 0xB5453C, 0x3F7FA8, 0xFF00AA

local cfg = config.defaults()
cfg.rules.track[1] = rules.new('track', { label = 'Kick', mode = 'regex',
                                          pattern = '^kick\\b', color = RED })
cfg.rules.track[2] = rules.new('track', { label = 'Gtr', mode = 'glob',
                                          pattern = 'gtr*', color = BLUE })
cfg.rules.item[1]  = rules.new('item',  { label = 'Gtr items', mode = 'glob',
                                          pattern = 'gtr*', color = BLUE })
assert(config.save(cfg))

local kick = P.track('Kick In')
local other = P.track('Audio 3')
P.item('gtr_dry_01')

local function ticks(n)
  for _ = 1, (n or 1) do P.advance(0.3); autoloop.tick() end
end
local function tcol(t) return colors.from_native(t.color) end

autoloop.reset()
ticks(1)
check(tcol(kick) == RED, 'first tick colours tracks immediately', tostring(tcol(kick)))

ticks(4)
check(colors.from_native(P.items[1].color) == BLUE, 'items follow in the cold sweep')

-- idle must be genuinely idle: no writes, and our own writes must not retrigger
local writes_before = autoloop.state.stats.writes
local scc_before = P.scc
ticks(6)
check(autoloop.state.stats.writes == writes_before, 'idle ticks write nothing',
      (autoloop.state.stats.writes - writes_before) .. ' writes')
check(P.scc == scc_before, 'idle ticks do not touch the project at all')

-- a rename must be picked up
kick.name = 'gtr_amp_L'; P.bump()
ticks(2)
check(tcol(kick) == BLUE, 'renaming a track re-applies the rules', tostring(tcol(kick)))

-- renaming AWAY from every rule keeps the old colour, because clear_unmatched
-- is off by default. Pinning this so the behaviour cannot drift silently.
do
  local tmp = P.track('gtr_temp'); P.bump(); ticks(3)
  check(tcol(tmp) == BLUE, 'temp track coloured')
  tmp.name = 'Nothing Matches This'; P.bump(); ticks(3)
  check(tcol(tmp) == BLUE, 'renaming out of every rule leaves the old colour alone')
end

-- THE important one: a manual colour must not be reverted
kick.color = reaper.ColorToNative(0xFF, 0x00, 0xAA) | 0x1000000
P.bump()
ticks(6)
check(tcol(kick) == PINK, 'a hand-picked colour is NOT reverted', tostring(tcol(kick)))
check(autoloop.state.stats.skipped > 0, 'the override was counted as skipped')

-- ...until the object is renamed, which hands control back to the rules
kick.name = 'Kick In'; P.bump()
ticks(3)
check(tcol(kick) == RED, 'renaming clears the override and the rule takes over',
      tostring(tcol(kick)))

-- a new track appearing gets coloured
local newtr = P.track('gtr_amp'); P.bump()
ticks(3)
check(tcol(newtr) == BLUE, 'a newly added track is picked up')
check(tcol(other) == nil, 'an unmatched track is still left alone')

-- changing the rules through the config revision invalidates the cache
do
  local c = config.load()
  c.rules.track[2].color = 0x00FF00
  assert(config.save(c))                      -- bumps config_rev

  -- Editing a rule does NOT repaint the project on its own -- that is what
  -- Apply Now is for, and it matches how a colour or pattern change behaves.
  ticks(3)
  check(tcol(newtr) ~= 0x00FF00, 'a rule edit alone does not repaint the project',
        tostring(tcol(newtr)))

  -- ...but the cache was dropped, so the next project change re-evaluates
  -- everything against the new rules rather than leaving a half-applied state.
  P.bump()
  ticks(3)
  check(tcol(newtr) == 0x00FF00, 'the next project change applies the new rules',
        tostring(tcol(newtr)))
end

-- recording must pause the loop entirely
do
  P.playstate = 5                             -- playing + recording
  local w = autoloop.state.stats.writes
  P.track('Kick 2'); P.bump()
  ticks(3)
  check(autoloop.state.stats.writes == w, 'the loop does nothing while recording')
  P.playstate = 0
  ticks(3)
  check(autoloop.state.stats.writes > w, 'and resumes once recording stops')
end

-- Apply Now (from the GUI or the action) must reach across into this loop and
-- clear the "user recoloured this by hand" marks. The two live in separate Lua
-- states, so an ExtState counter is the only channel.
do
  local t = P.track('Kick 3'); P.bump(); ticks(3)
  check(tcol(t) == RED, 'new track coloured by the rules')

  t.color = reaper.ColorToNative(0xFF, 0x00, 0xAA) | 0x1000000   -- user picks pink
  P.bump(); ticks(3)
  check(tcol(t) == PINK, 'hand-picked colour survives, as before')

  config.bump_override_rev()                                     -- <- Apply Now
  P.bump(); ticks(3)
  check(tcol(t) == RED, 'after Apply Now the rules take the object back',
        tostring(tcol(t)))
end

-- the track -> item cascade must work in the background loop as well, which
-- needs the cold sweep to carry the tracks in as context
do
  local c = config.load()
  c.rules.track[1].cascade_items = true
  c.rules.item = {}                        -- no item rules: cascade only
  assert(config.save(c))
  local t = P.track('Kick 9')
  local it = P.item('no_rule_matches_this', { track = t })
  P.bump(); ticks(6)
  check(tcol(t) == RED, 'the track got its colour')
  check(colors.from_native(it.color) == RED,
        'and its item cascaded in the background loop',
        tostring(colors.from_native(it.color)))
end

-- A cold sweep is chunked across ticks. If a config change lands while one is
-- still draining, its queued ops are (rightly) discarded -- they were planned
-- against the old rules. But part of that sweep has already been written, so
-- the loop has to finish the job or the project is left half-applied with
-- nothing scheduled to reconcile it. That looked like "it just stops
-- recolouring".
do
  local TMP2 = os.getenv('SP') .. '/coldint'
  os.execute('rm -rf "' .. TMP2 .. '" && mkdir -p "' .. TMP2 .. '/NameColorizer"')
  -- time creeps on every reading, so the cold budget really does expire
  local P2 = mock.install{ resource = TMP2, script = NC .. '/x.lua', tick_cost = 0.002 }
  P2.now = 1000
  for _, m in ipairs({ 'targets', 'apply', 'autoloop', 'config' }) do
    package.loaded[m] = nil
  end
  local config2   = require 'config'
  local autoloop2 = require 'autoloop'
  local colors2   = require 'colors'

  local t = P2.track('Str1')
  for i = 1, 60 do P2.item('it' .. i, { track = t }) end

  local c = config2.defaults()
  c.options.propagate_folders = 'off'
  c.options.cold_budget_ms = 1
  c.rules.item[1] = rules.new('item', { label = 'Items', mode = 'substring',
                                        pattern = 'it', color = 0x00FF00 })
  assert(config2.save(c))
  autoloop2.reset()

  local function tick2() P2.advance(0.3); autoloop2.tick() end
  local function uncoloured()
    local n = 0
    for _, it in ipairs(P2.items) do
      if colors2.from_native(it.color) == nil then n = n + 1 end
    end
    return n
  end

  local queued = false
  for _ = 1, 12 do
    tick2()
    if autoloop2.state.cold then queued = true break end
  end
  check(queued, 'a cold sweep really does queue work across ticks')

  local c2 = config2.load()
  c2.rules.item[1].color = 0x0000FF
  assert(config2.save(c2))                 -- the interruption

  for _ = 1, 300 do tick2() end
  check(uncoloured() == 0,
        'an interrupted cold sweep is finished, not abandoned',
        uncoloured() .. ' items left uncoloured')

  local wrong = 0
  for _, it in ipairs(P2.items) do
    if colors2.from_native(it.color) ~= 0x0000FF then wrong = wrong + 1 end
  end
  check(wrong == 0, 'and it finishes with the NEW rules, not the ones it started on',
        wrong .. ' items on the old colour')

  -- put the shared mock back for anything after this
  for _, m in ipairs({ 'targets', 'apply', 'autoloop', 'config' }) do
    package.loaded[m] = nil
  end
  mock.install{ resource = TMP, script = NC .. '/x.lua' }
end

-- auto sweeps must not litter the undo history
check(#P.undo == 0, 'the auto loop creates no undo points by default',
      #P.undo .. ' undo blocks')
check(P.dirty > 0, 'but it does mark the project dirty')

print('\n=== autoloop (mock REAPER) ===')
for _, f in ipairs(fails) do print('  FAIL  ' .. f) end
print(string.format('%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
