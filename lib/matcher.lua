--[[
  matcher.lua -- one matching front end per rule mode.

  All three modes end up in the same place: glob is translated to regex source
  and compiled by the same engine, so there is exactly one matching
  implementation to reason about. Substring stays a plain string.find because
  that is both faster and impossible to get wrong.

  Compiled matchers are cached, because the auto-apply loop re-resolves rules
  constantly and compiling on every sweep would dominate its cost.

  Results are cached too. The loop re-tests the SAME names against the SAME
  rules on every sweep, and a project holds far fewer distinct names than
  objects ("01-Gtr L", "02-Gtr L", ... collapse to one entry per rule). The memo
  lives on the rule as `_memo`, keyed by name alone, which is only sound because
  it is dropped the moment the rule's compiled matcher changes -- see prepare().
]]

local R = require 'regex'

local M = {}

local sfind, ssub = string.find, string.sub

---------------------------------------------------------------- glob -> regex
-- *      -> .*
-- ?      -> .
-- [abc]  -> [abc]      (a leading ! or ^ negates)
-- Anything else is escaped. Globs are implicitly anchored: "bass" as a glob
-- matches only the exact name, which is the real difference from substring mode.
local function glob_to_regex(g)
  local out, i, n = { '^' }, 1, #g
  while i <= n do
    local c = ssub(g, i, i)

    if c == '*' then
      out[#out + 1] = '.*'
      i = i + 1

    elseif c == '?' then
      out[#out + 1] = '.'
      i = i + 1

    elseif c == '[' then
      -- Copy the class through, but find its real end first; an unterminated
      -- '[' is a literal bracket rather than an error.
      local j = i + 1
      if ssub(g, j, j) == '!' or ssub(g, j, j) == '^' then j = j + 1 end
      if ssub(g, j, j) == ']' then j = j + 1 end
      while j <= n and ssub(g, j, j) ~= ']' do
        if ssub(g, j, j) == '\\' then j = j + 1 end
        j = j + 1
      end
      if j > n then
        out[#out + 1] = '\\['
        i = i + 1
      else
        local body = ssub(g, i + 1, j - 1)
        if ssub(body, 1, 1) == '!' then body = '^' .. ssub(body, 2) end
        out[#out + 1] = '[' .. body .. ']'
        i = j + 1
      end

    else
      out[#out + 1] = R.quote(c)
      i = i + 1
    end
  end
  out[#out + 1] = '$'
  return table.concat(out)
end

M.glob_to_regex = glob_to_regex   -- exported for the test suite

----------------------------------------------------------------- matcher objs
local Sub = {}
Sub.__index = Sub
function Sub:test(s)
  if self.plain then return sfind(s, self.pat, 1, true) ~= nil end
  return sfind(s, self.pat) ~= nil
end

local Rx = {}
Rx.__index = Rx
function Rx:test(s)
  local a, why = self.rx:find(s)
  if a then return true end
  return false, why          -- 'budget' propagates so the GUI can flag the rule
end

---------------------------------------------------------------------- cache
local cache = {}

--- Drop every compiled matcher. Call when the rule set changes.
function M.clear_cache()
  cache = {}
end

--- Compile one (mode, pattern, ci) triple.
-- @return matcher                 on success (has :test(name))
-- @return nil, errmsg, errpos     on a bad pattern
function M.compile(mode, pattern, ci)
  pattern = pattern or ''
  ci = ci and true or false
  local key = mode .. '\0' .. (ci and '1' or '0') .. '\0' .. pattern

  local hit = cache[key]
  if hit ~= nil then
    if hit.ok then return hit.ok end
    return nil, hit.err, hit.pos
  end

  local m, err, pos

  if mode == 'substring' then
    if ci and pattern ~= '' then
      m = setmetatable({ pat = R.ci_plain_pattern(pattern), plain = false }, Sub)
    else
      m = setmetatable({ pat = pattern, plain = true }, Sub)
    end

  elseif mode == 'glob' then
    local rx
    rx, err, pos = R.compile(glob_to_regex(pattern), { ci = ci })
    -- A bad glob can only fail inside a [ ] class, so report against the glob.
    if rx then m = setmetatable({ rx = rx }, Rx) end

  elseif mode == 'regex' then
    local rx
    rx, err, pos = R.compile(pattern, { ci = ci })
    if rx then m = setmetatable({ rx = rx }, Rx) end

  else
    err, pos = 'unknown match mode ' .. tostring(mode), 1
  end

  if m then
    cache[key] = { ok = m }
    return m
  end
  cache[key] = { err = err, pos = pos }
  return nil, err, pos
end

--- Compile every rule in a list once, before a sweep. Stores the matcher on the
--- rule as `_m`, and any error as `_err` / `_errpos` for the GUI to display.
--- A rule whose pattern will not compile is skipped by the apply pipeline
--- rather than being allowed to break the sweep.
---
--- This also owns the result memo's lifetime. compile() returns the SAME
--- matcher object for an unchanged (mode, pattern, ci), so an ordinary sweep
--- keeps its memo; an edited pattern -- or clear_cache(), which every rule
--- change goes through -- yields a different object and the memo is dropped
--- with it. That is the whole guarantee behind keying the memo on the name
--- alone, so it must stay in one place.
function M.prepare(rules)
  local bad = 0
  for _, r in ipairs(rules) do
    local m, err, pos
    if r.pattern ~= nil and r.pattern ~= '' then
      m, err, pos = M.compile(r.mode, r.pattern, r.ci)
      if not m then bad = bad + 1 end
    end
    if m ~= r._m then r._memo, r._memon = nil, nil end
    r._m, r._err, r._errpos = m, err, pos
  end
  return bad
end

-- Distinct names remembered per rule. A project cannot hold more of them than
-- it holds objects, so this is a backstop against a pathological session
-- (thousands of renames), not an expected limit.
local MEMO_MAX = 4096

-- Memo values are small integers rather than booleans so that "gave up on the
-- step budget" survives the cache: it reads as no-match but the GUI badges it.
local NO, YES, BUDGET = 0, 1, 2

--- Test one rule against one name. An empty pattern matches any name, which is
--- what makes predicate-only rules ("every folder track") expressible.
--- @return boolean, 'budget'|nil
function M.test(rule, name)
  if rule.pattern == nil or rule.pattern == '' then return true end
  local m = rule._m
  if not m then return false end        -- pattern did not compile: never matches

  local memo = rule._memo
  if memo then
    local v = memo[name]
    if v == YES then return true end
    if v == NO  then return false end
    if v == BUDGET then return false, 'budget' end
  else
    memo = {}
    rule._memo, rule._memon = memo, 0
  end

  local hit, why = m:test(name)
  if rule._memon < MEMO_MAX then
    memo[name] = hit and YES or (why == 'budget' and BUDGET or NO)
    rule._memon = rule._memon + 1
  end
  return hit, why
end

return M
