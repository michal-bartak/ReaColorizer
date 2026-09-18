package.path = os.getenv('SP') .. '/?.lua;' .. package.path
local mock = require 'mockreaper'
local NC, TMP = os.getenv('NC'), os.getenv('SP') .. '/proj2'
os.execute('rm -rf "' .. TMP .. '" && mkdir -p "' .. TMP .. '/AutoColor"')

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

-- a rule edit is HELD until something actually happens to an object
do
  local c = config.load()
  c.rules.track[2].color = 0x00FF00
  assert(config.save(c))                      -- bumps config_rev

  -- Editing a rule does NOT repaint the project on its own -- that is what
  -- Apply Now is for, and it matches how a colour or pattern change behaves.
  ticks(3)
  check(tcol(newtr) ~= 0x00FF00, 'a rule edit alone does not repaint the project',
        tostring(tcol(newtr)))

  -- Nor does a bare bump of the project state counter. Clicking empty space in
  -- the arrange, or a track panel in the mixer, changes the SELECTION -- which
  -- is project state -- so the counter moves while not one object has changed.
  -- Repainting there looks to the user like repainting at random.
  P.bump()
  ticks(4)
  check(tcol(newtr) ~= 0x00FF00,
        'nor does a click that changes nothing but the selection',
        tostring(tcol(newtr)))

  -- A real object change does take the edit up -- and takes it up for the WHOLE
  -- project, not just the object that moved, so nothing is left half on the old
  -- rules and half on the new.
  local second = P.track('gtr_second'); P.bump()
  ticks(4)
  check(tcol(newtr) == 0x00FF00, 'a real object change applies the new rules',
        tostring(tcol(newtr)))
  check(tcol(second) == 0x00FF00, 'and applies them to the whole project',
        tostring(tcol(second)))
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
  os.execute('rm -rf "' .. TMP2 .. '" && mkdir -p "' .. TMP2 .. '/AutoColor"')
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

-- ===================================================================
-- What a change COSTS.
--
-- REAPER offers one project-wide change counter, so a fader move and a rename
-- arrive looking identical. Everything here is about telling them apart without
-- re-reading the whole project for the privilege -- and about the one edit that
-- no cheap signal can see.
do
  local TMP3 = os.getenv('SP') .. '/gate'
  os.execute('rm -rf "' .. TMP3 .. '" && mkdir -p "' .. TMP3 .. '/AutoColor"')
  local P3 = mock.install{ resource = TMP3, script = NC .. '/x.lua' }
  for _, m in ipairs({ 'targets', 'apply', 'autoloop', 'config', 'matcher' }) do
    package.loaded[m] = nil
  end
  local config3, targets3 = require 'config', require 'targets'
  local apply3, autoloop3 = require 'apply', require 'autoloop'

  local c = config3.defaults()
  c.options.cold_interval = 30            -- long, so only the gate decides
  c.rules.track[1] = rules.new('track', { mode = 'substring', pattern = 'gtr',
                                          color = BLUE })
  c.rules.item[1]  = rules.new('item',  { mode = 'substring', pattern = 'take',
                                          color = RED })
  c.rules.item[2]  = rules.new('item',  { mode = 'substring', pattern = 'keeper',
                                          color = PINK })
  assert(config3.save(c))

  local gtr = P3.track('Gtr L')
  for i = 1, 8 do P3.item('take ' .. i, { track = gtr }) end
  local plain = P3.track('Audio 2')

  -- count what the loop actually asks REAPER for
  local n = { tracks = 0, items = 0, plans = 0 }
  local ot, oi, opl = targets3.tracks, targets3.items, apply3.plan
  targets3.tracks = function(...) n.tracks = n.tracks + 1; return ot(...) end
  targets3.items  = function(...) n.items  = n.items  + 1; return oi(...)  end
  apply3.plan     = function(...) n.plans  = n.plans  + 1; return opl(...) end
  local function counted() n.tracks, n.items, n.plans = 0, 0, 0 end

  local function tick3(k) for _ = 1, (k or 1) do P3.advance(0.3); autoloop3.tick() end end
  local function icol(i) return colors.from_native(P3.items[i].color) end

  autoloop3.reset()
  tick3(8)
  check(icol(1) == RED, 'gate: the first sweep colours everything', tostring(icol(1)))

  -- A change that renamed nothing: a fader, an FX tweak, an envelope point.
  counted()
  P3.bump()
  tick3(6)
  check(n.items == 0, 'a change that renames nothing never re-reads the items',
        n.items .. ' item scans')
  check(n.plans == 0, 'and nothing is re-planned at all', n.plans .. ' plans')
  check(n.tracks > 0,
        'tracks are still read -- a rename is only visible by reading names')

  -- A track rename. The items are swept once, because a track rule can cascade
  -- onto them, and the tracks are read once per settle pass -- the cold sweep
  -- reuses the list it was handed rather than reading them all again.
  counted()
  plain.name = 'Gtr R'; P3.bump()
  tick3(6)
  check(colors.from_native(plain.color) == BLUE, 'a rename is still immediate',
        tostring(colors.from_native(plain.color)))
  check(n.items == 1, 'a track change costs exactly one item scan', n.items)
  check(n.tracks == 3, 'and three track reads: two settle passes and the cold ' ..
        'sweep, which re-reads nothing', n.tracks .. ' track scans')

  -- The one edit nothing cheap can see: an item renamed in place. Nothing is
  -- added, nothing is removed, no track changes.
  do
    local c2 = config3.load()
    c2.options.cold_interval = 10
    assert(config3.save(c2))
    P3.bump(); tick3(6)                        -- let the rule change settle

    P3.items[3].take.name = 'keeper 3'
    P3.bump()
    tick3(3)                                   -- under a second of mock time
    check(icol(3) == RED, 'an item renamed in place is not chased straight away',
          tostring(icol(3)))

    P3.advance(12); autoloop3.tick()           -- ...now the net is overdue
    check(icol(3) == PINK,
          'but the safety net picks it up without the project changing again',
          tostring(icol(3)))
  end

  -- Deleted objects must not sit in the cache for the life of the session.
  do
    local doomed = P3.items[#P3.items]
    local dguid  = doomed.guid
    P3.delete_item(doomed)                     -- bumps the change counter
    tick3(8)
    check(autoloop3.state.cache[dguid] == nil,
          'a deleted object is dropped from the cache')

    -- The invariant, rather than a proxy for it: nothing in the cache may
    -- belong to an object the project no longer has. Counting entries instead
    -- measures which sweeps happened to have run, which is not the point.
    local live = {}
    for _, t in ipairs(P3.tracks) do live[t.guid] = true end
    for _, it in ipairs(P3.items) do live[it.guid] = true end
    local stale = 0
    for guid in pairs(autoloop3.state.cache) do
      if not live[guid] then stale = stale + 1 end
    end
    check(stale == 0, 'the cache holds nothing the project has stopped holding',
          stale .. ' stale entries')
  end
end

-- ===================================================================
-- The cold queue is drained in chunks, and what it is holding can be deleted
-- out from under it.
--
-- `write_cost` is the honest clock here: the budget is spent on WRITES. An
-- earlier version timed the loop that merely copied ops into a batch, where 4 ms
-- buys some fifteen thousand iterations, so the whole queue went out in a single
-- tick -- and the mock, which advanced time on every reading, hid it.
do
  local TMP4 = os.getenv('SP') .. '/chunk'
  os.execute('rm -rf "' .. TMP4 .. '" && mkdir -p "' .. TMP4 .. '/AutoColor"')
  local P4 = mock.install{ resource = TMP4, script = NC .. '/x.lua',
                           write_cost = 0.002 }
  for _, m in ipairs({ 'targets', 'apply', 'autoloop', 'config', 'matcher' }) do
    package.loaded[m] = nil
  end
  local config4   = require 'config'
  local autoloop4 = require 'autoloop'

  local c = config4.defaults()
  c.options.cold_budget_ms = 4                 -- two writes per tick, at 2 ms each
  c.options.cold_interval  = 0
  c.rules.item[1] = rules.new('item', { mode = 'substring', pattern = 'it',
                                        color = BLUE })
  assert(config4.save(c))

  local tr = P4.track('T')
  for i = 1, 40 do P4.item('it' .. i, { track = tr }) end

  local function tick4() P4.advance(0.3); autoloop4.tick() end
  local function left()
    local q = autoloop4.state.cold
    return q and (#q.ops - q.i + 1) or 0
  end

  autoloop4.reset()
  local guard = 0
  while autoloop4.state.cold == nil and guard < 20 do tick4(); guard = guard + 1 end
  check(autoloop4.state.cold ~= nil,
        'the cold queue outlives the tick that planned it')

  local left1 = left()
  tick4()
  local left2 = left()
  check(left2 > 0, 'a 4 ms budget does not write forty items in one tick',
        left1 .. ' -> ' .. left2)
  check(left2 < left1, 'but it does make progress on every tick',
        left1 .. ' -> ' .. left2)

  -- Pull an object out from under the queue. In REAPER this is a write through
  -- a freed pointer; here it is only a wrong answer, which is what we can test.
  local victim = P4.items[#P4.items]
  local was    = victim.color
  P4.delete_item(victim)

  guard = 0
  while autoloop4.state.cold ~= nil and guard < 200 do tick4(); guard = guard + 1 end
  check(victim.color == was, 'a queued write to a deleted object is dropped',
        tostring(victim.color))

  local wrong = 0
  for _, it in ipairs(P4.items) do
    if colors.from_native(it.color) ~= BLUE then wrong = wrong + 1 end
  end
  check(wrong == 0, 'and every surviving item still gets its colour',
        wrong .. ' left over')
end

-- ===================================================================
-- A region keeps its identity when it moves.
--
-- The fallback identity is index+position, so nudging a region used to make it
-- a different object as far as the cache was concerned -- which lost the fact
-- that its colour had been picked by hand, and leaked an entry per move.
do
  local TMP5 = os.getenv('SP') .. '/rgnid'
  os.execute('rm -rf "' .. TMP5 .. '" && mkdir -p "' .. TMP5 .. '/AutoColor"')
  local P5 = mock.install{ resource = TMP5, script = NC .. '/x.lua' }
  for _, m in ipairs({ 'targets', 'apply', 'autoloop', 'config', 'matcher' }) do
    package.loaded[m] = nil
  end
  local config5   = require 'config'
  local autoloop5 = require 'autoloop'

  local c = config5.defaults()
  c.options.cold_interval = 0                  -- sweep every change: no gate here
  c.rules.region[1] = rules.new('region', { mode = 'substring', pattern = 'chorus',
                                            color = BLUE })
  assert(config5.save(c))

  local rgn = P5.mark('Chorus 1', true, { pos = 4.0 })
  local function tick5(k) for _ = 1, (k or 1) do P5.advance(0.3); autoloop5.tick() end end
  local function rcol() return colors.from_native(rgn.color) end

  autoloop5.reset()
  tick5(8)
  check(rcol() == BLUE, 'a region is coloured by its rule', tostring(rcol()))

  rgn.color = reaper.ColorToNative(0xFF, 0x00, 0xAA) | 0x1000000   -- by hand
  P5.bump(); tick5(6)
  check(rcol() == PINK, 'a hand-picked region colour survives', tostring(rcol()))

  rgn.pos = rgn.pos + 12.5                     -- ...and the user drags it
  P5.bump(); tick5(8)
  check(rcol() == PINK, 'moving a region does not hand it back to the rules',
        tostring(rcol()))
end

-- auto sweeps must not litter the undo history
check(#P.undo == 0, 'the auto loop creates no undo points by default',
      #P.undo .. ' undo blocks')
check(P.dirty > 0, 'but it does mark the project dirty')

print('\n=== autoloop (mock REAPER) ===')
for _, f in ipairs(fails) do print('  FAIL  ' .. f) end
print(string.format('%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
