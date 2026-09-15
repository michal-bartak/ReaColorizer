--[[
  MB_NameColorizer_RunTests.lua -- assertions for the matching layer.

  Runs either inside REAPER (results go to the ReaScript console) or standalone
  from a terminal (`lua MB_NameColorizer_RunTests.lua`), which is much faster to
  iterate on. Nothing here touches project state.
]]

local IN_REAPER = (type(reaper) == 'table' and reaper.ShowConsoleMsg ~= nil)

local ROOT
if IN_REAPER then
  local _, thisFile = reaper.get_action_context()
  ROOT = thisFile:match('^(.*[\\/])')
else
  ROOT = (arg and arg[0] or ''):match('^(.*[/\\])') or './'
end
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib/?.lua;' .. package.path

local R = require 'regex'

------------------------------------------------------------------- harness
local pass, fail, failures = 0, 0, {}

local function out(s)
  if IN_REAPER then reaper.ShowConsoleMsg(s) else io.write(s) end
end

local function check(ok, label, detail)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = label .. (detail and ('  -- ' .. detail) or '')
  end
end

-- Match and return the matched text, or a sentinel describing what happened.
local function m(pat, subj, opts)
  local c, err, pos = R.compile(pat, opts)
  if not c then return '<compile:' .. err .. '@' .. tostring(pos) .. '>' end
  local a, b, caps = c:find(subj)
  if a == nil then
    if b == 'budget' then return '<budget>' end
    return nil
  end
  return subj:sub(a, b), caps
end

local function eq(pat, subj, expect, opts)
  local got = m(pat, subj, opts)
  check(got == expect, string.format('/%s/ on %q', pat, subj),
        string.format('expected %s, got %s', tostring(expect), tostring(got)))
end

local function caps_eq(pat, subj, expect, opts)
  local _, caps = m(pat, subj, opts)
  caps = caps or {}
  local okAll = #expect == #caps
  if okAll then
    for i = 1, #expect do
      if caps[i] ~= expect[i] then okAll = false break end
    end
  end
  local function show(t)
    local parts = {}
    for i = 1, #t do parts[i] = tostring(t[i]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  check(okAll, string.format('captures /%s/ on %q', pat, subj),
        'expected ' .. show(expect) .. ', got ' .. show(caps))
end

local function bad(pat, why)
  local c, err = R.compile(pat)
  check(c == nil, 'should reject /' .. pat .. '/ (' .. (why or '') .. ')',
        c and 'compiled anyway' or nil)
  if c == nil then
    check(type(err) == 'string' and #err > 0, 'error message for /' .. pat .. '/')
  end
end

---------------------------------------------------------------- literals
eq('bass',  'Bass Guitar', nil)
eq('bass',  'sub bass DI', 'bass')
eq('bass',  'Bass Guitar', 'Bass', { ci = true })
eq('BASS',  'sub bass DI', 'bass', { ci = true })
eq('(?i)bass', 'Bass Guitar', 'Bass')
eq('',      'anything',     '')

---------------------------------------------------------------- anchors
eq('^Kick',  'Kick In',      'Kick')
eq('^Kick',  'The Kick In',  nil)
eq('In$',    'Kick In',      'In')
eq('In$',    'Kick Inside',  nil)
eq('^$',     '',             '')
eq('^$',     'x',            nil)
eq('^Gtr$',  'Gtr',          'Gtr')

---------------------------------------------------------------- dot
eq('a.c',    'abc',   'abc')
eq('a.c',    'a\nc',  nil)      -- . does not cross a newline
eq('^.$',    'e',     'e')
eq('^.{3}$', 'abc',   'abc')
eq('^.{3}$', 'Kyt',   'Kyt')
-- one multi-byte character counts as one
eq('^.$',    'e\204\129', 'e\204\129' == 'e\204\129' and nil or nil)  -- combining: two sequences
eq('^.$',    '\195\169', '\195\169')             -- U+00E9
eq('^.$',    '\208\145', '\208\145')             -- U+0411
eq('^.$',    '\226\130\172', '\226\130\172')     -- U+20AC
eq('^.$',    '\240\159\165\129', '\240\159\165\129') -- U+1F941

---------------------------------------------------------------- classes
eq('[abc]+',   'xxcabyy',  'cab')
eq('[^abc]+',  'abXYZab',  'XYZ')
eq('[a-z]+',   'ABCdefGH', 'def')
eq('[a-z]+',   'ABCdefGH', 'ABCdefGH', { ci = true })
eq('[0-9]+',   'gtr12',    '12')
eq('[]]',      ']',        ']')        -- ] first in class is literal
eq('[a%-z]',   '%',        '%')        -- % is not special here
eq('[-a]+',    '-a',       '-a')       -- leading - is literal
eq('[a-]+',    'a-',       'a-')       -- trailing - is literal
eq('[\\]]',    ']',        ']')
eq('[\\d]+',   'ab12',     '12')
eq('[\\w]+',   ' ab_1 ',   'ab_1')
bad('[z-a]', 'reversed range')
bad('[abc',  'unterminated class')

---------------------------------------------------------------- class escapes
eq('\\d+',   'gtr12dry', '12')
eq('\\D+',   '12ab34',   'ab')
eq('\\w+',   ' _a1 ',    '_a1')
eq('\\W+',   'ab  cd',   '  ')
eq('\\s+',   'a \t b',   ' \t ')
eq('\\S+',   '  abc  ',  'abc')
-- non-ASCII bytes count as word characters
eq('^\\w+$', 'Kytara_hlavn\195\173', 'Kytara_hlavn\195\173')

---------------------------------------------------------------- word boundaries
eq('\\bbass\\b',  'sub bass DI',  'bass')
eq('\\bbass\\b',  'bassoon solo', nil)
eq('\\bbass',     'bassoon solo', 'bass')
eq('\\bKick\\b',  'Kick',         'Kick')   -- both boundaries at string edges
eq('\\Bass',      'bassoon',      'ass')
eq('\\bx\\b',     'x',            'x')
eq('\\b',         '',             nil)      -- no boundary in an empty string

---------------------------------------------------------------- alternation
eq('^(kick|snare|hh)',  'snare top',  'snare')
eq('^(kick|snare|hh)',  'hh closed',  'hh')
eq('^(kick|snare|hh)',  'tom 1',      nil)
eq('cat|catalog',       'catalog',    'cat')   -- leftmost-first, not longest
eq('a(b|)c',            'ac',         'ac')    -- empty branch
eq('^(a|b)+$',          'abab',       'abab')
caps_eq('^(kick|snare)_(\\d+)$', 'snare_12', { 'snare', '12' })

---------------------------------------------------------------- quantifiers
eq('ab*',     'a',        'a')
eq('ab*',     'abbb',     'abbb')
eq('ab+',     'a',        nil)
eq('ab+',     'abbb',     'abbb')
eq('ab?',     'a',        'a')
eq('ab?',     'ab',       'ab')
eq('a.*b',    'axxbxxb',  'axxbxxb')   -- greedy
eq('a.*?b',   'axxbxxb',  'axxb')      -- lazy
eq('a.+?b',   'axxbxxb',  'axxb')
eq('^a??b',   'ab',       'ab')
eq('<.+?>',   '<a><b>',   '<a>')
eq('<.+>',    '<a><b>',   '<a><b>')

---------------------------------------------------------------- bounded repeats
eq('^a{3}$',    'aaa',    'aaa')
eq('^a{3}$',    'aa',     nil)
eq('^a{2,4}$',  'aa',     'aa')
eq('^a{2,4}$',  'aaaa',   'aaaa')
eq('^a{2,4}$',  'a',      nil)
eq('^a{2,4}$',  'aaaaa',  nil)
eq('^a{2,}$',   'aaaaa',  'aaaaa')
eq('^a{0,2}$',  '',       '')
eq('a{2,4}',    'aaaaa',  'aaaa')     -- greedy within bounds
eq('a{2,4}?',   'aaaaa',  'aa')       -- lazy within bounds
eq('^\\d{2}_',  '01_Kick', '01_')
bad('a{3,1}', 'm < n')
bad('a{300}', 'bound too large')
-- a bare { that is not a quantifier is a literal
eq('a{b',  'a{b',  'a{b')
eq('x{b}', 'x{b}', 'x{b}')
-- but a real quantifier applied to an anchor is an error, as in PCRE/Python
bad('^{2}$', 'quantified anchor')

---------------------------------------------------------------- groups & captures
caps_eq('(a)(b)(c)',      'abc',      { 'a', 'b', 'c' })
caps_eq('(a(b(c)))',      'abc',      { 'abc', 'bc', 'c' })
caps_eq('(?:ab)(c)',      'abc',      { 'c' })
caps_eq('(x)?y',          'y',        { false })
caps_eq('(x)?y',          'xy',       { 'x' })
caps_eq('^(\\d+)_',       '01_Kick',  { '01' })
caps_eq('^(\\w+?)_(\\w+)$', 'a_b_c',  { 'a', 'b_c' })
-- captures must be restored correctly when the engine backtracks
caps_eq('^(?:(a)|b)+$',   'ab',       { 'a' })
caps_eq('(a+)(a+)',       'aaa',      { 'aa', 'a' })
bad('(ab',   'missing )')
bad('ab)',   'unmatched )')

---------------------------------------------------------------- case folding
eq('[a-z]+',     'ABC',    'ABC',  { ci = true })
eq('[A-Z]+',     'abc',    'abc',  { ci = true })
eq('[^a-z]+',    'ABC',    nil,    { ci = true })   -- negation folds too
eq('gtr\\d',     'GTR7',   'GTR7', { ci = true })
eq('^(?i)x', 'X', '<compile:(?i) is only allowed at the very start of the pattern@2>')

---------------------------------------------------------------- escapes
eq('a\\.c',    'a.c',   'a.c')
eq('a\\.c',    'abc',   nil)
eq('\\$\\^',   '$^',    '$^')
eq('\\x41+',   'xAAy',  'AA')
eq('a\\tb',    'a\tb',  'a\tb')
eq('\\\\',     'a\\b',  '\\')
bad('\\q',  'unknown escape')
bad('a\\',  'trailing backslash')
bad('(?=a)', 'lookaround')
bad('(a)\\1', 'backreference')

---------------------------------------------------------------- anchor repeat
bad('^*',   'nothing to repeat')
bad('*a',   'nothing to repeat')
bad('+a',   'nothing to repeat')
bad('a**',  'nested quantifier')

------------------------------------------------- zero-width loop termination
-- These must terminate (the PROGRESS guard), not spin.
eq('^(a*)*$',   'aaa',  'aaa')
eq('^(a*)*$',   '',     '')
eq('^(|x)*$',   '',     '')
eq('^(a?)+$',   '',     '')
eq('^()*$',     '',     '')

------------------------------------------------- catastrophic backtracking
-- Each of these would hang a naive backtracker. They must come back as
-- '<budget>' (or an honest non-match) in bounded time -- never hang REAPER.
local SUBJ40 = string.rep('a', 40) .. '!'
local function bounded(pat, subj, label)
  local t0 = os.clock()
  local got = m(pat, subj)
  local dt = os.clock() - t0
  check(got == '<budget>' or got == nil, label,
        'got ' .. tostring(got))
  check(dt < 0.5, label .. ' finishes fast', string.format('took %.3fs', dt))
end
bounded('^(a+)+$',   SUBJ40, 'catastrophic (a+)+$')
bounded('^(a|a)*$',  SUBJ40, 'catastrophic (a|a)*$')
bounded('^(a*)*b',   SUBJ40, 'catastrophic (a*)*b')
bounded('^(a|aa)+$', SUBJ40, 'catastrophic (a|aa)+$')

-- The compile-time program cap must reject the classic expansion bomb.
bad('(a{200}){200}', 'program size cap')

---------------------------------------------------------------- prefilter
-- The prefilter must never change the answer, only the speed.
eq('gtr\\d+',    'my gtr12 dry',  'gtr12')
eq('gtr\\d+',    'my GTR12 dry',  nil)
eq('gtr\\d+',    'my GTR12 dry',  'GTR12', { ci = true })
eq('^bass',      'bass',          'bass')
eq('x(abc)y',    'zzxabcyzz',     'xabcy')

---------------------------------------------------------------- realistic
eq('^\\d{2}[_ -]',            '01_Kick In',   '01_')
eq('(?i)^(gtr|gui?tar)\\b',   'Guitar DI',    'Guitar')
eq('(?i)^(gtr|gui?tar)\\b',   'Gtr L',        'Gtr')
eq('(?i)\\b(vox|vocal)s?\\b', 'Lead Vocals',  'Vocals')
eq('(?i)\\bbass\\b',          'Bassoon',      nil)
eq('(?i)\\bbass\\b',          'Sub Bass',     'Bass')
eq('_(dry|wet)$',             'gtr_dry',      '_dry')
eq('^FX\\s*\\d*$',            'FX 3',         'FX 3')


--=========================================================== matcher / modes
local MT = require 'matcher'

local function mt(mode, pat, subj, ci)
  local m, err = MT.compile(mode, pat, ci)
  if not m then return '<compile:' .. tostring(err) .. '>' end
  return m:test(subj) and true or false
end

local function mteq(mode, pat, subj, expect, ci)
  local got = mt(mode, pat, subj, ci)
  check(got == expect,
        string.format('%s /%s/ on %q%s', mode, pat, subj, ci and ' (ci)' or ''),
        string.format('expected %s, got %s', tostring(expect), tostring(got)))
end

-- substring: never interprets anything
mteq('substring', 'bass',  'Sub Bass DI', false)
mteq('substring', 'bass',  'sub bass di', true)
mteq('substring', 'bass',  'Sub Bass DI', true,  true)
mteq('substring', 'a.c',   'abc',        false)          -- '.' is literal
mteq('substring', 'a.c',   'xa.cx',      true)
mteq('substring', '*',     'a*b',        true)           -- '*' is literal
mteq('substring', '[a]',   'x[a]x',      true)
mteq('substring', '',      'anything',   true)

-- glob: implicitly anchored, so it matches the WHOLE name
mteq('glob', 'bass',    'sub bass',    false)
mteq('glob', 'bass',    'bass',        true)
mteq('glob', '*bass*',  'sub bass di', true)
mteq('glob', '*bass*',  'Sub Bass DI', false)
mteq('glob', '*bass*',  'Sub Bass DI', true,  true)
mteq('glob', 'Gtr_?',   'Gtr_L',       true)
mteq('glob', 'Gtr_?',   'Gtr_LR',      false)
mteq('glob', '[Bb]ass*', 'Bass Gtr',   true)
mteq('glob', '[Bb]ass*', 'bass',       true)
mteq('glob', '[Bb]ass*', 'Sass',       false)
mteq('glob', '[!ab]*',  'cat',         true)
mteq('glob', '[!ab]*',  'about',       false)
mteq('glob', '*.wav',   'kick.wav',    true)
mteq('glob', '*.wav',   'kickXwav',    false)            -- '.' escaped
mteq('glob', '*',       '',            true)
mteq('glob', '*',       'anything',    true)
mteq('glob', 'a+b',     'a+b',         true)             -- regex metachars escaped
mteq('glob', 'a+b',     'aab',         false)
mteq('glob', 'x[',      'x[',          true)             -- unterminated class is literal

-- regex mode is the engine, unchanged
mteq('regex', '^(kick|snare)$', 'snare', true)
mteq('regex', '^(kick|snare)$', 'snares', false)
mteq('regex', 'bass',           'BASS',  true, true)

check(MT.compile('nonsense', 'x') == nil, 'unknown mode rejected')

-- a bad pattern reports an error and then simply never matches
local badm, baderr, badpos = MT.compile('regex', '(a')
check(badm == nil, 'bad regex does not compile')
check(type(baderr) == 'string' and type(badpos) == 'number', 'bad regex reports msg+pos')

-- the cache must hand back the identical object
check(MT.compile('regex', '^a') == MT.compile('regex', '^a'), 'matcher cache reuses')
check(MT.compile('regex', '^a', true) ~= MT.compile('regex', '^a', false),
      'matcher cache keys on ci')

-- prepare() / test() over rule records
local rules = {
  { mode = 'regex',     pattern = '^kick', ci = true },
  { mode = 'substring', pattern = 'bass',  ci = false },
  { mode = 'regex',     pattern = '(',     ci = false },   -- deliberately broken
  { mode = 'regex',     pattern = '',      ci = false },   -- predicate-only rule
}
local nbad = MT.prepare(rules)
check(nbad == 1, 'prepare counts broken rules', 'got ' .. nbad)
check(rules[3]._err ~= nil, 'broken rule keeps its error message')
check(MT.test(rules[1], 'Kick In') == true,  'prepared regex rule matches')
check(MT.test(rules[2], 'sub bass') == true, 'prepared substring rule matches')
check(MT.test(rules[3], 'anything') == false, 'broken rule never matches')
check(MT.test(rules[4], 'anything') == true,  'empty pattern matches any name')

--=============================================================== predicates
local PR = require 'predicates'

local function pr(only, kind, info) return PR.test(only, kind, info) end

check(pr(nil, 'track', {}) == true, 'nil predicate always passes')
check(pr('folder',   'track', { folderdepth = 1 }) == true,  'folder: parent')
check(pr('folder',   'track', { folderdepth = 0 }) == false, 'folder: plain track')
check(pr('folder',   'track', { folderdepth = -1 }) == false, 'folder: last child')
check(pr('children', 'track', { depth = 1 }) == true,  'children: inside a folder')
check(pr('children', 'track', { depth = 0 }) == false, 'children: top level')
check(pr('unnamed',  'track', { name = '' }) == true,   'unnamed: empty')
check(pr('unnamed',  'track', { name = 'x' }) == false, 'unnamed: named')
check(pr('unnamed',  'item',  { name = '' }) == true,   'unnamed works on items')
check(pr('unnamed',  'region', { name = '' }) == true,  'unnamed works on regions')
-- track-only predicates must not silently pass for other kinds
check(pr('folder',   'item',  { folderdepth = 1 }) == false, 'folder is track-only')
check(pr('children', 'region', { depth = 5 }) == false, 'children is track-only')

check(PR.applies('folder', 'track') == true,  'applies: folder/track')
check(PR.applies('folder', 'item')  == false, 'applies: folder/item')
check(PR.applies('unnamed', 'item') == true,  'applies: unnamed/item')
check(PR.applies(nil, 'item')       == true,  'applies: nil/anything')
check(PR.valid('master') == false, 'valid: the removed master filter')
check(PR.valid('folder') == true,  'valid: known')
check(PR.valid(nil)      == true,  'valid: nil')
check(PR.valid('nope')   == false, 'valid: unknown')


--=============================================================== colors
-- Outside REAPER, stand in for the two native-colour calls. The stub models
-- macOS byte order; correctness on Windows comes from always routing through
-- these two functions rather than assuming a layout.
if not IN_REAPER then
  _G.reaper = _G.reaper or {}
  reaper.ColorToNative   = function(r, g, b) return (r << 16) | (g << 8) | b end
  reaper.ColorFromNative = function(v) return (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF end
end

local CO = require 'colors'

check(CO.pack(255, 128, 0) == 0xFF8000, 'pack')
do
  local r, g, b = CO.split(0xFF8000)
  check(r == 255 and g == 128 and b == 0, 'split')
end
check(CO.pack(CO.split(0x123456)) == 0x123456, 'pack/split round trip')

-- I_CUSTOMCOLOR can come back negative; norm must make both sides comparable
check(CO.norm(0) == 0, 'norm zero')
check(CO.norm(0x1FF8000) == 0x1FF8000, 'norm passthrough')
check(CO.norm(-16744448) == CO.norm(-16744448 + 0x100000000), 'norm negative')
check(CO.norm(0x7F000000 | 0x1123456) & CO.ENABLE ~= 0, 'norm keeps enable bit')

check(CO.to_native(0xFF8000) & CO.ENABLE ~= 0, 'to_native sets the enable bit')
check(CO.from_native(CO.to_native(0x123456)) == 0x123456, 'native round trip')
check(CO.from_native(0) == nil, 'from_native 0 means no colour, not black')
check(CO.from_native(CO.ENABLE) == 0x000000, 'enable bit alone is black')

-- HSL round trip across a spread of colours
for _, c in ipairs({ 0x000000, 0xFFFFFF, 0x808080, 0xFF0000, 0x00FF00, 0x0000FF,
                     0xC44A3B, 0x3B7FC4, 0x7FC43B, 0x123456, 0xFEDCBA }) do
  local back = CO.hsl_to_rgb(CO.rgb_to_hsl(c))
  local dr = math.abs(((back >> 16) & 0xFF) - ((c >> 16) & 0xFF))
  local dg = math.abs(((back >> 8) & 0xFF) - ((c >> 8) & 0xFF))
  local db = math.abs((back & 0xFF) - (c & 0xFF))
  check(dr <= 1 and dg <= 1 and db <= 1, 'hsl round trip ' .. CO.tohex(c),
        'got ' .. CO.tohex(back))
end

check(CO.lerp(0xFF0000, 0x00FF00, 0) == 0xFF0000, 'lerp at t=0')
check(CO.lerp(0xFF0000, 0x00FF00, 1) == 0x00FF00, 'lerp at t=1')
check(CO.gradient(0xFF0000, nil, 3, 5) == 0xFF0000, 'gradient without a second colour')
check(CO.gradient(0xFF0000, 0x00FF00, 1, 1) == 0xFF0000, 'gradient of one is the first colour')
check(CO.gradient(0xFF0000, 0x00FF00, 1, 4) == 0xFF0000, 'gradient starts at colour 1')
check(CO.gradient(0xFF0000, 0x00FF00, 4, 4) == 0x00FF00, 'gradient ends at colour 2')
do
  -- a 5-step gradient must produce 5 distinct colours
  local seen, n = {}, 0
  for i = 1, 5 do
    local c = CO.gradient(0xC44A3B, 0x3B7FC4, i, 5)
    if not seen[c] then seen[c] = true; n = n + 1 end
  end
  check(n == 5, 'gradient yields distinct steps', 'got ' .. n)
end
do
  -- hue takes the SHORT way round: red -> magenta must not detour via green
  local mid = CO.lerp(0xFF0000, 0xFF00FF, 0.5)
  local r, g, b = CO.split(mid)
  check(g < 64 and r > 128 and b > 64, 'lerp takes the short hue path',
        'got ' .. CO.tohex(mid))
end
do
  -- fading to grey must not swing through an unrelated hue
  local mid = CO.lerp(0xC44A3B, 0x808080, 0.5)
  local r, g, b = CO.split(mid)
  check(r >= g and g >= b, 'lerp to grey keeps the hue', 'got ' .. CO.tohex(mid))
end

check(CO.tohex(0xFF8000) == '#FF8000', 'tohex')
check(CO.fromhex('#FF8000') == 0xFF8000, 'fromhex with hash')
check(CO.fromhex('ff8000') == 0xFF8000, 'fromhex without hash')
check(CO.fromhex('nope') == nil, 'fromhex rejects junk')


--==================================================================== json
local J = require 'json'

local function roundtrip(v, label)
  local enc, eerr = J.encode(v)
  check(enc ~= nil, 'encode ' .. label, tostring(eerr))
  if not enc then return end
  check(not enc:find('\n'), 'encode ' .. label .. ' stays on one line')
  local dec, derr = J.decode(enc)
  check(dec ~= nil, 'decode ' .. label, tostring(derr))
  return enc, dec
end

roundtrip({ a = 1, b = 'two', c = true, d = { 1, 2, 3 } }, 'nested')
roundtrip({ 1, 2, 3 }, 'array')
roundtrip({}, 'empty table')

do
  local _, dec = roundtrip({ s = 'quote" back\\ nl\n tab\t ctrl\1' }, 'nasty string')
  check(dec and dec.s == 'quote" back\\ nl\n tab\t ctrl\1', 'string survives escaping')
end
do
  -- names contain non-ASCII; it must pass through as UTF-8, not get mangled
  local _, dec = roundtrip({ n = 'Kytara_hlavn\195\173' }, 'utf8 name')
  check(dec and dec.n == 'Kytara_hlavn\195\173', 'utf8 passes through')
end
do
  local enc = J.encode({ z = 1, a = 2, m = 3 })
  check(enc == '{"a":2,"m":3,"z":1}', 'object keys are sorted', enc)
  check(J.encode({ z = 1, a = 2, m = 3 }) == enc, 'encoding is stable across calls')
end
do
  local enc = J.encode({ i = 7, f = 1.5 })
  check(enc:find('"i":7', 1, true) ~= nil, 'integers encode without a decimal point', enc)
  check(enc:find('"f":1.5', 1, true) ~= nil, 'floats keep their fraction', enc)
end
check(J.decode('{"a":1} junk') == nil, 'decode rejects trailing content')
check(J.decode('{"a":}') == nil, 'decode rejects a missing value')
check(J.decode('"unterminated') == nil, 'decode rejects an unterminated string')
check(J.decode('[1,2') == nil, 'decode rejects an unterminated array')
check(J.decode('nonsense') == nil, 'decode rejects junk')
check(select(2, J.decode('{"a":}')) ~= nil, 'decode returns a message')
do
  local cyc = {}; cyc.self = cyc
  check(J.encode(cyc) == nil, 'encode refuses a cycle')
end

--=================================================================== rules
local RU = require 'rules'

do
  local r = RU.new('track', {})
  check(r.id ~= nil and r.id ~= '', 'new rule gets an id')
  check(r.kind == 'track',     'new rule remembers its kind')
  check(r.enabled == true,     'new rule is enabled')
  check(r.ci == true,          'new rule is case-insensitive by default')
  check(r.mode == 'substring', 'new rule defaults to substring')
  check(r.cascade_items == false, 'a track rule has a cascade switch, off by default')
  check(r.targets == nil,      'the v1 targets field is gone')
end
do
  local r = RU.new('region', {})
  check(r.kind == 'region', 'a region rule knows its kind')
  check(r.cascade_items == nil, 'only track rules carry the cascade switch')
end
check(RU.newid() ~= RU.newid(), 'ids are unique')

do -- garbage in, sane rule out
  local r = RU.normalize({ mode = 'nope', pattern = 42, color = -5, ci = 'yes',
                           only = 'bogus' }, 'track')
  check(r.mode == 'substring', 'bad mode falls back')
  check(r.pattern == '',       'non-string pattern falls back')
  check(r.color == 0x808080,   'negative colour falls back')
  check(r.only == nil,         'unknown filter is dropped')
end
check(RU.normalize({ color = 0x1FF8000 }, 'track').color == 0xFF8000,
      'colour is masked to 24 bits')
check(RU.normalize({ kind = 'nonsense' }, 'nonsense').kind == 'track',
      'an unknown kind falls back to track')

-- a filter that cannot apply to the kind is dropped, not left never matching
check(RU.normalize({ only = 'folder' }, 'track').only == 'folder',
      'a track keeps the folder filter')
check(RU.normalize({ only = 'folder' }, 'region').only == nil,
      'a region drops the folder filter')
check(RU.normalize({ only = 'unnamed' }, 'region').only == 'unnamed',
      'a region keeps the unnamed filter')

do
  local w = RU.warnings(RU.normalize({ pattern = '', only = nil }, 'track'))
  check(#w > 0, 'warns about a rule that matches everything')
  local w2 = RU.warnings(RU.normalize({ pattern = 'x', only = 'unnamed' }, 'track'))
  check(#w2 > 0, 'warns about a pattern combined with the unnamed filter')
end

-- the removed 'master' filter must DISABLE a rule, not widen it to match all
do
  local legacy = RU.normalize({ id = 'r_legacy', only = 'master', pattern = '',
                                enabled = true }, 'track')
  check(legacy.only == nil,      'the legacy master filter is dropped')
  check(legacy.enabled == false, 'and the rule is DISABLED, not left matching everything')
  check(legacy.note:find('master') ~= nil, 'and the reason is recorded in its note')
end

--================================================================== config
local CF = require 'config'

do
  local d = CF.defaults()
  check(d.version == CF.VERSION, 'defaults carry the current version')
  check(d.options.propagate_folders == 'fill_unmatched', 'default folder policy')
  for _, k in ipairs(RU.KINDS) do
    check(type(d.rules[k]) == 'table' and #d.rules[k] == 0,
          'defaults have an empty ' .. k .. ' list')
  end
  check(d.options.match_master == nil, 'the master option is gone')
end

do -- option coercion
  local c = CF.normalize{ options = { propagate_folders = 'bogus', tick_interval = 99,
                                      font_size = -3, clear_unmatched = 'yes' } }
  check(c.options.propagate_folders == 'fill_unmatched', 'bad enum falls back')
  check(c.options.tick_interval == 2.0, 'tick interval clamps to max')
  check(c.options.font_size == 8, 'font size clamps to min')
  check(c.options.clear_unmatched.track == false, 'non-boolean coerces to false per kind')
  check(type(c.options.clear_unmatched) == 'table', 'clear_unmatched is a per-kind table')
end

do -- ids must be unique ACROSS kinds; they key GUI widgets and the undo stack
  local c = CF.normalize{ rules = { track = { { id = 'dup' } }, item = { { id = 'dup' } } } }
  check(c.rules.track[1].id ~= c.rules.item[1].id,
        'a duplicate id across two kinds is reassigned')
end

do -- EVERY starter pattern must compile; shipping a broken one would be bad
  local starter = CF.starter()
  local total = 0
  for _, k in ipairs(RU.KINDS) do
    total = total + #starter.rules[k]
    local bad = MT.prepare(starter.rules[k])
    check(bad == 0, 'every starter ' .. k .. ' rule compiles', bad .. ' failed')
  end
  check(total > 0, 'starter set is not empty')
  check(#starter.rules.region > 0, 'the starter set includes region rules')
  check(#starter.rules.marker > 0, 'the starter set includes marker rules')
end

--------------------------------------------------- v1 -> v2 migration
-- v1 kept one list with track/item/region/marker checkboxes. A rule that
-- ticked several must become one rule per kind, keeping its relative order --
-- and must NOT end up sharing an id with its own copies.
do
  local v1 = {
    version = 1,
    options = { propagate_folders = 'force', match_master = true },
    rules = {
      { id = 'a', label = 'Both',   pattern = 'x', color = 0x111111,
        targets = { track = true, item = true } },
      { id = 'b', label = 'Region', pattern = 'y', color = 0x222222,
        targets = { region = true } },
      { id = 'c', label = 'First',  pattern = 'z', color = 0x333333,
        targets = { track = true } },
    },
  }
  -- round-trip through JSON first, exactly as loading a real file would
  local migrated = CF.normalize(CF.migrate(J.decode(J.encode(v1))))

  check(#migrated.rules.track == 2, 'both track-targeting rules land on the track tab',
        #migrated.rules.track .. ' found')
  check(migrated.rules.track[1].label == 'Both', 'order within a kind is preserved')
  check(migrated.rules.track[2].label == 'First', 'and the second one follows')
  check(#migrated.rules.item == 1,   'the item copy lands on the item tab')
  check(#migrated.rules.region == 1, 'the region rule lands on the region tab')
  check(#migrated.rules.marker == 0, 'nothing lands on the marker tab')
  check(migrated.rules.track[1].id ~= migrated.rules.item[1].id,
        'the split copies do not share an id')
  check(migrated.rules.item[1].pattern == 'x', 'the copy keeps the pattern')
  check(migrated.rules.item[1].color == 0x111111, 'and the colour')
  check(migrated.options.propagate_folders == 'force', 'options survive migration')
  check(type(migrated.options.clear_unmatched) == 'table',
        'a v1 clear_unmatched boolean becomes a per-kind table')
  check(migrated.version == CF.VERSION, 'the migrated config is stamped v2')
end

-- File round trip, skipped inside REAPER so tests never touch the real config.
if not IN_REAPER and os.getenv('NC_TEST_DIR') then
  local cfg = CF.starter()
  cfg.options.font_size = 17
  local ok, err = CF.save(cfg)
  check(ok, 'config saves', tostring(err))

  local loaded, info = CF.load()
  check(not info.created, 'second load is not a first run')
  check(loaded.options.font_size == 17, 'options survive a round trip')
  check(#loaded.rules.track == #cfg.rules.track, 'track rules survive a round trip')
  check(#loaded.rules.region == #cfg.rules.region, 'region rules survive a round trip')
  check(loaded.rules.track[1].pattern == cfg.rules.track[1].pattern,
        'patterns survive verbatim')
  check(loaded.rules.track[1].id == cfg.rules.track[1].id, 'rule ids are stable')
  check(loaded.rules.track[1].cascade_items == cfg.rules.track[1].cascade_items,
        'the cascade switch survives a round trip')

  -- the per-kind clear option must survive JSON, not collapse to a boolean
  cfg.options.clear_unmatched = { track = false, item = true,
                                  region = false, marker = true }
  assert(CF.save(cfg))
  local l2 = CF.load()
  check(type(l2.options.clear_unmatched) == 'table', 'clear_unmatched stays a table')
  check(l2.options.clear_unmatched.item == true,   'a ticked kind survives')
  check(l2.options.clear_unmatched.marker == true, 'and another one')
  check(l2.options.clear_unmatched.track == false, 'an unticked kind stays off')

  -- a corrupt file must be parked, not lost, and must not stop the tool
  local f = io.open(CF.path(), 'wb'); f:write('{not json'); f:close()
  local c2, info2 = CF.load()
  check(info2.corrupt, 'corrupt config is detected')
  check(io.open(CF.badpath()) ~= nil, 'corrupt config is kept aside')
  check(#c2.rules.track == 0, 'corrupt config falls back to defaults')

  -- a file from a newer build loads read-only rather than being downgraded
  local f2 = io.open(CF.path(), 'wb')
  f2:write(J.encode{ version = CF.VERSION + 5, options = {}, rules = {} })
  f2:close()
  local _, info3 = CF.load()
  check(info3.readonly, 'a newer config version loads read-only')

  os.remove(CF.path()); os.remove(CF.bakpath()); os.remove(CF.badpath())
end

-- Rules carry runtime scratch (_m, _err, _timeouts) once prepared. Serialising
-- those directly fails, which used to silently break every save after the
-- first preview.
do
  local cfg2 = CF.starter()
  MT.prepare(cfg2.rules.track)
  check(cfg2.rules.track[1]._m ~= nil, 'a prepared rule really does carry scratch')
  check(J.encode(cfg2) == nil, 'encoding a live rule fails, as expected')
  local enc = J.encode(CF.serializable(cfg2))
  check(enc ~= nil, 'serializable() strips the scratch so encoding works')
  for _, k in ipairs({ '"_m"', '"_err"', '"_errpos"', '"_timeouts"' }) do
    check(enc and not enc:find(k, 1, true), 'no runtime key ' .. k .. ' leaks into the file')
  end
  local back = J.decode(enc or '')
  check(back and #back.rules.track == #cfg2.rules.track, 'the cleaned copy keeps every rule')
  check(back and back.rules.track[1].pattern == cfg2.rules.track[1].pattern,
        'patterns survive cleaning')
end

--=================================================================== apply
-- plan() is pure, so the whole decision layer can be tested with synthetic
-- entries -- no project, no REAPER objects.
local AP = require 'apply'

local RED, GRN, BLU = 0xC44A3B, 0x3BC44A, 0x3B4AC4

local function tr(name, o)
  o = o or {}
  return { kind = 'track', name = name, guid = 'g:' .. name,
           folderdepth = o.fd or 0, depth = o.depth or 0,
           context = o.context,
           color = o.color and CO.to_native(o.color) or 0 }
end
local function item(name, o)
  o = o or {}
  return { kind = 'item', name = name, guid = 'i:' .. name,
           track_guid = o.on and ('g:' .. o.on) or nil,
           color = o.color and CO.to_native(o.color) or 0 }
end
local function region(name, o)
  o = o or {}
  return { kind = 'region', name = name, guid = 'r:' .. name,
           color = o.color and CO.to_native(o.color) or 0 }
end
local function marker(name, o)
  o = o or {}
  return { kind = 'marker', name = name, guid = 'm:' .. name,
           color = o.color and CO.to_native(o.color) or 0 }
end

--- build a rules map from { track = {...}, item = {...} } shorthand
local function ruleset(spec)
  local out = {}
  for _, k in ipairs(RU.KINDS) do
    out[k] = {}
    for _, o in ipairs(spec[k] or {}) do
      out[k][#out[k] + 1] = RU.new(k, o)
    end
  end
  return out
end

-- name -> planned colour ('CLEAR' for a clear op); entries with no op are absent
local function planmap(entries, rules, opts)
  local ops = AP.plan(entries, rules, opts or {})
  local out = {}
  for _, op in ipairs(ops) do
    out[op.entry.name] = op.clear and 'CLEAR' or op.rgb
  end
  return out, ops
end

-- first match wins, within the kind's own list
do
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'bass', color = RED },
    { mode = 'substring', pattern = 'sub',  color = BLU },
  } }
  check(planmap({ tr('Sub Bass') }, rs)['Sub Bass'] == RED, 'first matching rule wins')
end
do
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'sub',  color = BLU },
    { mode = 'substring', pattern = 'bass', color = RED },
  } }
  check(planmap({ tr('Sub Bass') }, rs)['Sub Bass'] == BLU, 'reordering changes the winner')
end

-- a rule only ever sees its own kind
do
  local rs = ruleset{ item = { { mode = 'substring', pattern = 'x', color = RED } } }
  local m = planmap({ tr('x1'), item('x2') }, rs)
  check(m['x1'] == nil, 'an item rule leaves tracks alone')
  check(m['x2'] == RED, 'an item rule colours items')
end
do
  local rs = ruleset{ region = { { mode = 'regex', pattern = '^Chorus', color = RED } } }
  local m = planmap({ region('Chorus 1'), marker('Chorus 1'), region('Verse 1') }, rs)
  check(m['Chorus 1'] == RED, 'a region rule matches regions')
  check(m['Verse 1'] == nil,  'and is selective')
  local mk = planmap({ marker('Chorus 1') }, rs)
  check(next(mk) == nil, 'a region rule does NOT touch a marker of the same name')
end

-- precedence between the tabs is independent
do
  local rs = ruleset{
    track  = { { mode = 'substring', pattern = 'a', color = RED } },
    region = { { mode = 'substring', pattern = 'a', color = BLU } },
  }
  local m = planmap({ tr('abc'), region('abc') }, rs)
  check(m['abc'] == RED or m['abc'] == BLU, 'both kinds resolve')
  local ops = select(2, planmap({ tr('abc'), region('abc') }, rs))
  local bykind = {}
  for _, op in ipairs(ops) do bykind[op.entry.kind] = op.rgb end
  check(bykind.track == RED,  'the track rule colours the track')
  check(bykind.region == BLU, 'the region rule colours the region, independently')
end

-- disabled rules are skipped
do
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'bass', color = RED, enabled = false },
    { mode = 'substring', pattern = 'bass', color = BLU },
  } }
  check(planmap({ tr('Bass') }, rs)['Bass'] == BLU, 'disabled rule is skipped')
end

-- filters narrow, they do not replace the pattern
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = '', only = 'folder',
                                  color = RED } } }
  local m = planmap({ tr('Drums', { fd = 1 }), tr('Kick'), tr('Snare', { fd = -1 }) },
                    rs, { propagate_folders = 'off' })
  check(m['Drums'] == RED, 'folder filter matches the parent')
  check(m['Kick'] == nil,  'folder filter skips children')
end

-- invert
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'bass', color = RED,
                                  invert = true } } }
  local m = planmap({ tr('Bass'), tr('Kick') }, rs)
  check(m['Bass'] == nil, 'inverted rule skips what it matches')
  check(m['Kick'] == RED, 'inverted rule takes what it does not match')
end

-- no-op pruning
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'bass', color = RED } } }
  local ops, stats = AP.plan({ tr('Bass', { color = RED }) }, rs, {})
  check(#ops == 0, 'an already-correct colour produces no op')
  check(stats.unchanged == 1, 'stats count it as unchanged')
  check(stats.matched == 1,   'stats still count it as matched')
end

-- clear_unmatched, now per kind
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'bass', color = RED } } }
  local entries = { tr('Bass', { color = RED }), tr('Random', { color = GRN }) }
  check(planmap(entries, rs, {})['Random'] == nil,
        'unmatched colours are left alone by default')
  check(planmap(entries, rs, { clear_unmatched = { track = true } })['Random'] == 'CLEAR',
        'clearing is honoured for the track kind')
  check(planmap(entries, rs, { clear_unmatched = { item = true } })['Random'] == nil,
        'and NOT applied to a kind that was not ticked')
  check(planmap(entries, rs, { clear_unmatched = true })['Random'] == 'CLEAR',
        'a legacy boolean still applies to every kind')
end

-- THE point of clearing items: an item with no custom colour is drawn by REAPER
-- in its TRACK's colour, live, so it follows whatever track it is moved to.
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Strings', color = BLU } } }
  local entries = { tr('Strings'), item('06-Strum', { on = 'Strings', color = RED }) }

  check(planmap(entries, rs, { propagate_folders = 'off' })['06-Strum'] == nil,
        'by default a pasted item keeps its old colour')

  local m = planmap(entries, rs, { propagate_folders = 'off',
                                   clear_unmatched = { item = true } })
  check(m['06-Strum'] == 'CLEAR',
        'clearing unmatched items releases a stale pasted colour')
  check(m['Strings'] == BLU, 'while the track itself is still coloured')
end

do -- an item claimed by an item rule or by a cascade is never cleared
  local rs = ruleset{
    track = { { mode = 'substring', pattern = 'Strings', color = BLU,
                cascade_items = true } },
    item  = { { mode = 'glob', pattern = '*comp*', color = GRN } },
  }
  local entries = { tr('Strings'),
                    item('a_comp_1', { on = 'Strings', color = RED }),
                    item('plain',    { on = 'Strings', color = RED }) }
  local m = planmap(entries, rs, { propagate_folders = 'off',
                                   clear_unmatched = { item = true } })
  check(m['a_comp_1'] == GRN, 'an item rule still wins over clearing')
  check(m['plain'] == BLU,    'and a cascade still wins over clearing')
end

-- gradients
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'T', color = RED,
                                  color2 = BLU } } }
  local m = planmap({ tr('T1'), tr('T2'), tr('T3') }, rs, { propagate_folders = 'off' })
  check(m['T1'] == RED, 'gradient starts at the first colour')
  check(m['T3'] == BLU, 'gradient ends at the second colour')
  check(m['T2'] ~= RED and m['T2'] ~= BLU, 'gradient middle is distinct')
end

-- folder propagation
local function folderset()
  return { tr('Drums', { fd = 1 }), tr('Kick'), tr('Snare', { fd = -1 }), tr('Vox') }
end
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Drums', color = RED } } }
  local m = planmap(folderset(), rs, { propagate_folders = 'fill_unmatched' })
  check(m['Drums'] == RED, 'folder keeps its own colour')
  check(m['Kick']  == RED, 'unmatched child inherits the folder colour')
  check(m['Vox']   == nil, 'a track after the folder closes does not inherit')
end
do
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'Kick',  color = GRN },
    { mode = 'substring', pattern = 'Drums', color = RED },
  } }
  check(planmap(folderset(), rs, { propagate_folders = 'fill_unmatched' })['Kick'] == GRN,
        'a child with its own rule keeps its colour')
  check(planmap(folderset(), rs, { propagate_folders = 'force' })['Kick'] == RED,
        'force overrides a matched child')
  check(planmap(folderset(), rs, { propagate_folders = 'off' })['Snare'] == nil,
        'off does not inherit at all')
end
do -- one track closing several folder levels at once
  local entries = { tr('Outer', { fd = 1 }), tr('Inner', { fd = 1 }),
                    tr('Leaf', { fd = -2 }), tr('After') }
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Outer', color = RED } } }
  local m = planmap(entries, rs, { propagate_folders = 'fill_unmatched' })
  check(m['Inner'] == RED, 'nested folder inherits')
  check(m['After'] == nil, 'a -2 close pops both levels')
end

--------------------------------------------- track -> item cascade
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Bass', color = RED,
                                  cascade_items = true } } }
  local entries = { tr('Bass'), item('take_01', { on = 'Bass' }),
                    item('whatever', { on = 'Bass' }) }
  local m = planmap(entries, rs, { propagate_folders = 'off' })
  check(m['Bass'] == RED,      'the track is coloured')
  check(m['take_01'] == RED,   'and so are its items, whatever they are called')
  check(m['whatever'] == RED,  'every item on that track')
end
do -- cascade off: items untouched
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Bass', color = RED,
                                  cascade_items = false } } }
  local m = planmap({ tr('Bass'), item('take_01', { on = 'Bass' }) }, rs,
                    { propagate_folders = 'off' })
  check(m['Bass'] == RED,    'the track is still coloured')
  check(m['take_01'] == nil, 'but its items are not')
end
do -- an item rule OVERRIDES the cascade
  local rs = ruleset{
    track = { { mode = 'substring', pattern = 'Bass', color = RED, cascade_items = true } },
    item  = { { mode = 'glob', pattern = '*comp*', color = GRN } },
  }
  local entries = { tr('Bass'), item('bass_comp_1', { on = 'Bass' }),
                    item('bass_raw', { on = 'Bass' }) }
  local m = planmap(entries, rs, { propagate_folders = 'off' })
  check(m['bass_comp_1'] == GRN, 'an item rule beats the track cascade')
  check(m['bass_raw'] == RED,    'items with no item rule still cascade')
end
do -- items on OTHER tracks are unaffected
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Bass', color = RED,
                                  cascade_items = true } } }
  local m = planmap({ tr('Bass'), tr('Gtr'), item('a', { on = 'Bass' }),
                      item('b', { on = 'Gtr' }) }, rs, { propagate_folders = 'off' })
  check(m['a'] == RED, 'items on the matched track cascade')
  check(m['b'] == nil, 'items on another track do not')
end
do -- the cascade flag flows down a folder with the colour
  local entries = { tr('Drums', { fd = 1 }), tr('Kick'), tr('Snare', { fd = -1 }),
                    item('k1', { on = 'Kick' }), item('s1', { on = 'Snare' }) }
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Drums', color = RED,
                                  cascade_items = true } } }
  local m = planmap(entries, rs, { propagate_folders = 'fill_unmatched' })
  check(m['Kick'] == RED, 'the child track inherits the folder colour')
  check(m['k1'] == RED,   'and items on that child cascade too')
  check(m['s1'] == RED,   'for every child')
end
do -- a cascading track under a NON-cascading folder
  local entries = { tr('Drums', { fd = 1 }), tr('Kick', { fd = -1 }),
                    item('k1', { on = 'Kick' }) }
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'Kick',  color = GRN, cascade_items = true },
    { mode = 'substring', pattern = 'Drums', color = RED, cascade_items = false },
  } }
  local m = planmap(entries, rs, { propagate_folders = 'fill_unmatched' })
  check(m['Kick'] == GRN, 'the child keeps its own rule colour')
  check(m['k1'] == GRN,   'and cascades its own colour to its items')
end

---------------------------------------------------- context entries
-- Context entries take part in propagation and cascade but are never written.
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Drums', color = RED,
                                  cascade_items = true } } }
  local entries = { tr('Drums', { fd = 1, context = true }),
                    tr('Kick', { fd = -1, context = true }),
                    item('k1', { on = 'Kick' }) }
  local ops, stats = AP.plan(entries, rs, { propagate_folders = 'fill_unmatched' })
  check(#ops == 1, 'only the non-context entry produces an op', #ops .. ' ops')
  check(ops[1].entry.name == 'k1', 'and it is the item')
  check(ops[1].rgb == RED, 'which got its colour through the context tracks')
  check(stats.scanned == 1, 'context entries are not counted as scanned')
end

-- a broken pattern must not break the sweep
do
  local rs = ruleset{ track = {
    { mode = 'regex', pattern = '(unclosed', color = RED },
    { mode = 'substring', pattern = 'Bass', color = BLU },
  } }
  check(planmap({ tr('Bass') }, rs)['Bass'] == BLU,
        'a rule that will not compile is skipped, not fatal')
end

-- tally
do
  local rs = ruleset{ track = {
    { mode = 'substring', pattern = 'a', color = RED },
    { mode = 'substring', pattern = 'a', color = BLU },
  } }
  local r1, r2 = rs.track[1], rs.track[2]
  local won, shadowed = AP.tally({ tr('aaa'), tr('abc'), tr('zzz') }, rs)
  check(won[r1.id] == 2,      'tally counts what the first rule wins')
  check(won[r2.id] == 0,      'the shadowed rule wins nothing')
  check(shadowed[r2.id] == 2, 'tally reports how many it was shadowed on')
end

-- clearing
do
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'bass', color = RED } } }
  local entries = { tr('Bass', { color = RED }), tr('Other', { color = GRN }), tr('Plain') }
  check(#AP.plan_clear(entries, rs, 'matched') == 1,
        'clear "matched" only touches what the rules claim')
  check(#AP.plan_clear(entries, rs, 'all') == 2,
        'clear "all" touches every coloured object')
end
do -- an item coloured by a TRACK cascade is claimed by the rules too, so
   -- "clear what the rules match" must release it
  local rs = ruleset{ track = { { mode = 'substring', pattern = 'Bass', color = RED,
                                  cascade_items = true } } }
  local entries = { tr('Bass', { color = RED }),
                    item('anything', { on = 'Bass', color = RED }) }
  local ops = AP.plan_clear(entries, rs, 'matched', { propagate_folders = 'off' })
  local kinds = {}
  for _, op in ipairs(ops) do kinds[op.entry.kind] = true end
  check(kinds.item == true, 'a cascaded item is cleared by "what the rules match"')
  check(#ops == 2, 'along with its track', #ops .. ' ops')
end

------------------------------------------------------------------- report
local lines = {}
lines[#lines + 1] = ''
lines[#lines + 1] = '=== NameColorizer regex tests ==='
if fail > 0 then
  for _, f in ipairs(failures) do
    lines[#lines + 1] = '  FAIL  ' .. f
  end
end
lines[#lines + 1] = string.format('%d passed, %d failed', pass, fail)
lines[#lines + 1] = ''
out(table.concat(lines, '\n'))

if not IN_REAPER then os.exit(fail == 0 and 0 or 1) end
