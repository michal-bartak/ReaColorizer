--[[
  regex.lua -- a small, pure-Lua regular expression engine for ReaScript.

  Why this exists: REAPER's Lua 5.4 has no PCRE, and lrexlib is not usable here
  (the only ReaPack route ships Lua 5.3 and hard-crashes on Apple Silicon).
  Lua patterns cannot express alternation or {n,m}, so the engine is written out.

  Design: recursive-descent parser -> AST -> flat instruction program ->
  iterative backtracking VM with an explicit step budget.

  The step budget is the load-bearing safety feature: this runs on REAPER's UI
  thread, so a pathological pattern must never be able to hang the DAW. Matching
  gives up and reports 'budget' rather than spinning.

  Supported syntax
    literals, .                       any char except newline (one UTF-8 sequence)
    ( )  (?: )                        capturing / non-capturing groups
    |                                 alternation
    * + ? {n} {n,} {n,m}              greedy; suffix ? for lazy
    [abc] [^abc] [a-z]                classes, with escapes inside
    \d \D \w \W \s \S                 classes
    \b \B                             word boundaries
    ^ $                               start/end of string (not multiline)
    \n \t \r \f \v \0 \xHH            escapes
    (?i) at the very start            case-insensitive (also via opts.ci)

  Not supported (rejected at compile time with a clear message):
    backreferences, lookaround, named groups, inline flags other than a leading (?i)

  Limitations, deliberate:
    - Case folding is ASCII-only, so (?i) will not equate 'C' and 'c'.
    - Classes are byte-based; \w additionally accepts bytes >= 0x80 so that
      \w+ matches names like "Kytara_hlavni" with non-ASCII letters.
]]

local M = {}

local sbyte, ssub, sfind = string.byte, string.sub, string.find

---------------------------------------------------------------------- opcodes
local OP_CHAR, OP_SET, OP_ANY, OP_SPLIT, OP_JMP, OP_SAVE,
      OP_BOL, OP_EOL, OP_WORDB, OP_NWORDB, OP_MARK, OP_PROGRESS, OP_MATCH
    = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13

local MAX_PROG    = 10000   -- instructions; kills (a{200}){200} at compile time
local MAX_REPEAT  = 255     -- highest {n,m} bound we will expand
local STEP_BUDGET = 20000   -- VM steps per find(), shared across start positions

M.STEP_BUDGET = STEP_BUDGET

---------------------------------------------------------------- character sets
local function newset() return {} end

local function setrange(t, a, b)
  for i = a, b do t[i] = true end
  return t
end

local function setnegate(t)
  local r = {}
  for i = 0, 255 do if not t[i] then r[i] = true end end
  return r
end

local function setcopy(t)
  local r = {}
  for k in pairs(t) do r[k] = true end
  return r
end

-- Fold a set so it matches both cases. ASCII only, by design.
local function setfold(t)
  for b = 65, 90  do if t[b] then t[b + 32] = true end end
  for b = 97, 122 do if t[b] then t[b - 32] = true end end
  return t
end

local WORD = newset()
setrange(WORD, 48, 57); setrange(WORD, 65, 90); setrange(WORD, 97, 122)
WORD[95] = true
setrange(WORD, 128, 255)          -- treat non-ASCII bytes as word characters

local DIGIT  = setrange(newset(), 48, 57)
local SPACE  = newset()
for _, b in ipairs({ 32, 9, 10, 11, 12, 13 }) do SPACE[b] = true end

local NDIGIT, NWORD, NSPACE = setnegate(DIGIT), setnegate(WORD), setnegate(SPACE)

local CLASS_ESC = {
  d = DIGIT, D = NDIGIT,
  w = WORD,  W = NWORD,
  s = SPACE, S = NSPACE,
}

local SIMPLE_ESC = {
  n = 10, t = 9, r = 13, f = 12, v = 11, a = 7, e = 27, ['0'] = 0,
}

----------------------------------------------------------------------- parser
-- Errors are thrown as { msg = ..., pos = ... } and caught in M.compile.

local P = {}

local function perr(p, msg, pos)
  error({ msg = msg, pos = pos or p.pos }, 0)
end

local function peek(p)
  if p.pos > p.len then return nil end
  return ssub(p.src, p.pos, p.pos)
end

local function take(p)
  local c = peek(p)
  p.pos = p.pos + 1
  return c
end

local function accept(p, c)
  if peek(p) == c then p.pos = p.pos + 1; return true end
  return false
end

local parse_alt   -- forward

-- \x escape inside or outside a class. Returns either a byte or a set table.
local function parse_escape(p, in_class)
  local startpos = p.pos - 1        -- position of the backslash
  local c = take(p)
  if c == nil then perr(p, 'trailing backslash', startpos) end

  local cls = CLASS_ESC[c]
  if cls then return nil, cls end

  if c == 'x' then
    local h = ssub(p.src, p.pos, p.pos + 1)
    if not h:match('^%x%x$') then perr(p, '\\x needs two hex digits', startpos) end
    p.pos = p.pos + 2
    return tonumber(h, 16)
  end

  local simple = SIMPLE_ESC[c]
  if simple then return simple end

  if not in_class then
    if c == 'b' then return nil, nil, 'wordb' end
    if c == 'B' then return nil, nil, 'nwordb' end
    if c:match('%d') then
      perr(p, 'backreferences are not supported', startpos)
    end
  else
    if c == 'b' then return 8 end   -- \b is backspace inside a class
  end

  if c:match('%w') then
    perr(p, 'unknown escape \\' .. c, startpos)
  end
  return sbyte(c)                   -- \. \* \\ etc: the literal character
end

local function parse_class(p)
  local openpos = p.pos - 1
  local neg = accept(p, '^')
  local set = newset()
  local first = true

  while true do
    local c = peek(p)
    if c == nil then perr(p, 'unterminated [ ]', openpos) end
    if c == ']' and not first then p.pos = p.pos + 1; break end
    first = false

    local lo
    if c == '\\' then
      p.pos = p.pos + 1
      local b, cls = parse_escape(p, true)
      if cls then
        for k in pairs(cls) do set[k] = true end
        goto continue
      end
      lo = b
    else
      p.pos = p.pos + 1
      lo = sbyte(c)
    end

    -- range?
    if peek(p) == '-' and ssub(p.src, p.pos + 1, p.pos + 1) ~= ']'
       and p.pos + 1 <= p.len then
      p.pos = p.pos + 1
      local hi
      local n = peek(p)
      if n == '\\' then
        p.pos = p.pos + 1
        local b, cls = parse_escape(p, true)
        if cls then perr(p, 'class escape cannot end a range') end
        hi = b
      else
        p.pos = p.pos + 1
        hi = sbyte(n)
      end
      if hi < lo then perr(p, 'reversed range in [ ]') end
      setrange(set, lo, hi)
    else
      set[lo] = true
    end
    ::continue::
  end

  return { t = 'set', set = set, neg = neg }
end

local function parse_atom(p)
  local c = peek(p)

  if c == '(' then
    p.pos = p.pos + 1
    local capturing = true
    if peek(p) == '?' then
      local nxt = ssub(p.src, p.pos + 1, p.pos + 1)
      if nxt == ':' then
        p.pos = p.pos + 2
        capturing = false
      elseif nxt == '=' or nxt == '!' or nxt == '<' then
        perr(p, 'lookaround is not supported', p.pos - 1)
      elseif nxt == 'i' then
        perr(p, '(?i) is only allowed at the very start of the pattern', p.pos - 1)
      else
        perr(p, 'unsupported group syntax (?' .. nxt, p.pos - 1)
      end
    end
    local idx
    if capturing then
      p.ngroup = p.ngroup + 1
      idx = p.ngroup
    end
    local body = parse_alt(p)
    if not accept(p, ')') then perr(p, 'missing )') end
    return { t = 'group', node = body, index = idx }

  elseif c == '[' then
    p.pos = p.pos + 1
    return parse_class(p)

  elseif c == '.' then
    p.pos = p.pos + 1
    return { t = 'any' }

  elseif c == '^' then
    p.pos = p.pos + 1
    return { t = 'bol' }

  elseif c == '$' then
    p.pos = p.pos + 1
    return { t = 'eol' }

  elseif c == '\\' then
    p.pos = p.pos + 1
    local b, cls, anchor = parse_escape(p, false)
    if anchor then return { t = anchor } end
    if cls then return { t = 'set', set = cls } end
    return { t = 'char', b = b }

  elseif c == '*' or c == '+' or c == '?' then
    perr(p, 'nothing to repeat before ' .. c)

  elseif c == ')' then
    perr(p, 'unmatched )')

  else
    p.pos = p.pos + 1
    return { t = 'char', b = sbyte(c) }
  end
end

local function parse_quantifier(p, atom)
  local c = peek(p)
  local min, max

  if c == '*' then p.pos = p.pos + 1; min, max = 0, -1
  elseif c == '+' then p.pos = p.pos + 1; min, max = 1, -1
  elseif c == '?' then p.pos = p.pos + 1; min, max = 0, 1
  elseif c == '{' then
    -- only treat as a quantifier if it really looks like one
    local body, rest = p.src:match('^{(%d*,?%d*)}()', p.pos)
    if not body or body == '' or body == ',' then return atom end
    local lo, comma, hi = body:match('^(%d*)(,?)(%d*)$')
    if lo == '' then return atom end
    min = tonumber(lo)
    if comma == '' then max = min
    elseif hi == '' then max = -1
    else max = tonumber(hi) end
    p.pos = rest
  else
    return atom
  end

  if max ~= -1 and max < min then perr(p, '{n,m} has m < n') end
  if (max or 0) > MAX_REPEAT or min > MAX_REPEAT then
    perr(p, 'repetition bound above ' .. MAX_REPEAT .. ' is not allowed')
  end

  local t = atom.t
  if t == 'bol' or t == 'eol' or t == 'wordb' or t == 'nwordb' then
    perr(p, 'cannot repeat an anchor')
  end

  local lazy = accept(p, '?')
  if peek(p) == '*' or peek(p) == '+' then
    perr(p, 'nested quantifier')
  end
  return { t = 'rep', node = atom, min = min, max = max, lazy = lazy }
end

local function parse_concat(p)
  local items = {}
  while true do
    local c = peek(p)
    if c == nil or c == '|' or c == ')' then break end
    local atom = parse_atom(p)
    items[#items + 1] = parse_quantifier(p, atom)
  end
  return { t = 'cat', items = items }
end

parse_alt = function(p)
  local branches = { parse_concat(p) }
  while accept(p, '|') do
    branches[#branches + 1] = parse_concat(p)
  end
  if #branches == 1 then return branches[1] end
  return { t = 'alt', branches = branches }
end

--------------------------------------------------------------------- compiler
local C = {}

local function emit(c, op, a, b)
  local n = #c.prog + 1
  if n > MAX_PROG then
    error({ msg = 'pattern is too complex (over ' .. MAX_PROG .. ' instructions)', pos = 1 }, 0)
  end
  c.prog[n] = { op, a, b }
  return n
end

local compile_node   -- forward

local function compile_plus(c, sub, lazy)
  local mark = c.markbase + c.nmark; c.nmark = c.nmark + 1
  local L1 = emit(c, OP_MARK, mark)
  compile_node(c, sub)
  local sp = emit(c, OP_SPLIT, 0, 0)
  local L2 = emit(c, OP_PROGRESS, mark)
  emit(c, OP_JMP, L1)
  local L3 = #c.prog + 1
  if lazy then c.prog[sp][2], c.prog[sp][3] = L3, L2
  else         c.prog[sp][2], c.prog[sp][3] = L2, L3 end
end

local function compile_star(c, sub, lazy)
  local sp = emit(c, OP_SPLIT, 0, 0)
  local body = #c.prog + 1
  compile_plus(c, sub, lazy)
  local after = #c.prog + 1
  if lazy then c.prog[sp][2], c.prog[sp][3] = after, body
  else         c.prog[sp][2], c.prog[sp][3] = body, after end
end

local function compile_rep(c, node)
  local min, max, lazy, sub = node.min, node.max, node.lazy, node.node

  if max == -1 then
    if min == 0 then
      compile_star(c, sub, lazy)
    else
      for _ = 1, min - 1 do compile_node(c, sub) end
      compile_plus(c, sub, lazy)
    end
    return
  end

  for _ = 1, min do compile_node(c, sub) end

  -- The optional tail: e{2,4} becomes e e (e (e)?)?  -- each SPLIT's body
  -- contains the next, so the optionals nest naturally.
  local opt = max - min
  local splits = {}
  for i = 1, opt do
    splits[i] = emit(c, OP_SPLIT, 0, 0)
    compile_node(c, sub)
  end
  local after = #c.prog + 1
  for i = 1, opt do
    local sp = splits[i]
    if lazy then c.prog[sp][2], c.prog[sp][3] = after, sp + 1
    else         c.prog[sp][2], c.prog[sp][3] = sp + 1, after end
  end
end

compile_node = function(c, node)
  local t = node.t

  if t == 'char' then
    if c.ci then
      local b = node.b
      if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
        local set = newset(); set[b] = true; setfold(set)
        emit(c, OP_SET, set)
        return
      end
    end
    emit(c, OP_CHAR, node.b)

  elseif t == 'set' then
    local set = node.set
    -- Fold BEFORE negating. [^a-z] under (?i) must exclude both cases; folding
    -- an already-negated set would re-admit exactly what the class excluded.
    if c.ci then set = setfold(setcopy(set)) end
    if node.neg then set = setnegate(set) end
    emit(c, OP_SET, set)

  elseif t == 'any'    then emit(c, OP_ANY)
  elseif t == 'bol'    then emit(c, OP_BOL)
  elseif t == 'eol'    then emit(c, OP_EOL)
  elseif t == 'wordb'  then emit(c, OP_WORDB)
  elseif t == 'nwordb' then emit(c, OP_NWORDB)

  elseif t == 'cat' then
    for _, it in ipairs(node.items) do compile_node(c, it) end

  elseif t == 'alt' then
    local br = node.branches
    local jmps = {}
    for i = 1, #br - 1 do
      local sp = emit(c, OP_SPLIT, 0, 0)
      c.prog[sp][2] = #c.prog + 1
      compile_node(c, br[i])
      jmps[#jmps + 1] = emit(c, OP_JMP, 0)
      c.prog[sp][3] = #c.prog + 1
    end
    compile_node(c, br[#br])
    local after = #c.prog + 1
    for _, j in ipairs(jmps) do c.prog[j][2] = after end

  elseif t == 'group' then
    if node.index then
      emit(c, OP_SAVE, node.index * 2)
      compile_node(c, node.node)
      emit(c, OP_SAVE, node.index * 2 + 1)
    else
      compile_node(c, node.node)
    end

  elseif t == 'rep' then
    compile_rep(c, node)

  else
    error({ msg = 'internal: unknown node ' .. tostring(t), pos = 1 }, 0)
  end
end

------------------------------------------------------------------- prefilter
-- Turn a literal into a Lua pattern that matches it case-insensitively, so the
-- prefilter still works under (?i) -- which is the common case for track names.
-- Still one C-level string.find, and it allocates nothing per call.
local function ci_prefilter_pattern(lit)
  local out = {}
  for i = 1, #lit do
    local ch = ssub(lit, i, i)
    if ch:match('%a') then
      out[#out + 1] = '[' .. ch:upper() .. ch:lower() .. ']'
    elseif ch:match('[%^%$%(%)%%%.%[%]%*%+%-%?]') then
      out[#out + 1] = '%' .. ch
    else
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end

-- Find a literal substring that every match must contain. Used to skip the VM
-- entirely on the overwhelming majority of non-matching names.
-- Deliberately conservative: only the top-level sequence, and only unquantified
-- literal characters.
local function find_prefilter(ast)
  if ast.t ~= 'cat' then return nil end
  local best, cur = '', {}
  local function flush()
    if #cur > 0 then
      local s = string.char(table.unpack(cur))
      if #s > #best then best = s end
      cur = {}
    end
  end
  for _, it in ipairs(ast.items) do
    if it.t == 'char' then
      cur[#cur + 1] = it.b
    else
      flush()
    end
  end
  flush()
  return #best >= 2 and best or nil
end

local function is_anchored(ast)
  if ast.t ~= 'cat' then return false end
  local first = ast.items[1]
  return first ~= nil and first.t == 'bol'
end

------------------------------------------------------------------ compiled VM
local Compiled = {}
Compiled.__index = Compiled

local function run(c, s, init)
  local prog   = c.prog
  local slen   = #s
  local nregs  = c.nregs
  local regs   = c.regs
  local bt     = c.bt
  local jr, jv = c.jr, c.jv

  local budget = STEP_BUDGET
  local last   = c.anchored and init or slen + 1

  for start = init, last do
    local nbt, njn = 0, 0
    for i = 2, nregs do regs[i] = false end
    local pc, sp = 1, start

    while true do
      budget = budget - 1
      if budget < 0 then return nil, 'budget' end

      local ins = prog[pc]
      local op  = ins[1]
      local ok  = true

      if op == OP_CHAR then
        if sp <= slen and sbyte(s, sp) == ins[2] then pc = pc + 1; sp = sp + 1
        else ok = false end

      elseif op == OP_SET then
        if sp <= slen and ins[2][sbyte(s, sp)] then pc = pc + 1; sp = sp + 1
        else ok = false end

      elseif op == OP_SPLIT then
        nbt = nbt + 1; bt[nbt] = ins[3]
        nbt = nbt + 1; bt[nbt] = sp
        nbt = nbt + 1; bt[nbt] = njn
        pc = ins[2]

      elseif op == OP_JMP then
        pc = ins[2]

      elseif op == OP_ANY then
        local b = sp <= slen and sbyte(s, sp) or nil
        if b and b ~= 10 then
          local adv = 1
          if     b >= 0xF0 then adv = 4
          elseif b >= 0xE0 then adv = 3
          elseif b >= 0xC0 then adv = 2 end
          if sp + adv - 1 > slen then adv = 1 end
          pc = pc + 1; sp = sp + adv
        else ok = false end

      elseif op == OP_SAVE or op == OP_MARK then
        local r = ins[2]
        njn = njn + 1; jr[njn] = r; jv[njn] = regs[r]
        regs[r] = sp
        pc = pc + 1

      elseif op == OP_PROGRESS then
        if regs[ins[2]] ~= sp then pc = pc + 1 else ok = false end

      elseif op == OP_BOL then
        if sp == 1 then pc = pc + 1 else ok = false end

      elseif op == OP_EOL then
        if sp == slen + 1 then pc = pc + 1 else ok = false end

      elseif op == OP_WORDB or op == OP_NWORDB then
        local before = sp > 1     and WORD[sbyte(s, sp - 1)] or false
        local after  = sp <= slen and WORD[sbyte(s, sp)]     or false
        local atb = (before ~= after)
        if (op == OP_WORDB) == atb then pc = pc + 1 else ok = false end

      elseif op == OP_MATCH then
        regs[1] = sp
        return start, sp - 1

      else
        ok = false
      end

      if not ok then
        if nbt == 0 then break end
        local jt  = bt[nbt]; nbt = nbt - 1
        local nsp = bt[nbt]; nbt = nbt - 1
        local npc = bt[nbt]; nbt = nbt - 1
        while njn > jt do regs[jr[njn]] = jv[njn]; njn = njn - 1 end
        pc, sp = npc, nsp
      end
    end
  end

  return nil
end

--- Find the leftmost match.
-- @return startIdx, endIdx, captures   on success (captures is an array; a
--         group that did not participate is `false`)
-- @return nil                          on no match
-- @return nil, 'budget'                if the step budget was exhausted
function Compiled:find(s, init)
  init = init or 1
  if self.prefilter and not sfind(s, self.prefilter, init, self.prefilter_plain) then
    return nil
  end

  local a, b = run(self, s, init)
  if a == nil then return nil, b end

  local caps = {}
  local regs = self.regs
  for i = 1, self.ngroup do
    local st, en = regs[i * 2], regs[i * 2 + 1]
    if st and en then caps[i] = ssub(s, st, en - 1) else caps[i] = false end
  end
  return a, b, caps
end

--- Boolean convenience wrapper.
-- @return true|false, and 'budget' as a second result when the budget ran out.
function Compiled:test(s)
  local a, why = self:find(s)
  if a then return true end
  return false, why
end

--- Number of VM steps the last find() consumed. Used by the GUI's tester panel
--- to warn about patterns that will be slow on a large project.
function Compiled:laststeps()
  return self.laststeps_ or 0
end

------------------------------------------------------------------- public API

--- Compile a pattern.
-- @param pat  string
-- @param opts table|nil  { ci = boolean }
-- @return compiled           on success
-- @return nil, msg, pos      on a syntax error (pos is 1-based into `pat`)
function M.compile(pat, opts)
  if type(pat) ~= 'string' then return nil, 'pattern must be a string', 1 end
  opts = opts or {}

  local ci = opts.ci and true or false
  local src = pat
  if ssub(src, 1, 4) == '(?i)' then
    ci = true
    src = ssub(src, 5)
  end

  local p = { src = src, pos = 1, len = #src, ngroup = 0 }

  local ok, ast = pcall(parse_alt, p)
  if not ok then
    local e = ast
    if type(e) == 'table' then return nil, e.msg, (e.pos or 1) end
    return nil, tostring(e), 1
  end
  if p.pos <= p.len then
    return nil, 'unexpected ' .. ssub(src, p.pos, p.pos), p.pos
  end

  local c = setmetatable({
    source   = pat,
    ci       = ci,
    ngroup   = p.ngroup,
    prog     = {},
    nmark    = 0,
    markbase = p.ngroup * 2 + 2,
  }, Compiled)

  local okc, err = pcall(compile_node, c, ast)
  if not okc then
    if type(err) == 'table' then return nil, err.msg, (err.pos or 1) end
    return nil, tostring(err), 1
  end
  emit(c, OP_MATCH)

  c.nregs     = c.markbase + c.nmark
  c.anchored  = is_anchored(ast)
  local lit = find_prefilter(ast)
  if lit and ci then
    c.prefilter, c.prefilter_plain = ci_prefilter_pattern(lit), false
  else
    c.prefilter, c.prefilter_plain = lit, true
  end

  -- Scratch buffers, reused across calls to keep the auto-apply loop allocation-free.
  c.regs = {}
  for i = 1, c.nregs do c.regs[i] = false end
  c.bt, c.jr, c.jv = {}, {}, {}

  return c
end

--- Build a Lua pattern matching `lit` case-insensitively, for callers that want
--- a plain substring search without allocating a lowercased copy per call.
function M.ci_plain_pattern(lit)
  return ci_prefilter_pattern(lit)
end

--- Escape a literal so it can be embedded in a pattern.
function M.quote(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?%{%}%|\\]', '\\%0'))
end

return M
