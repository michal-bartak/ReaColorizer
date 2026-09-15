package.path = os.getenv('NC') .. '/lib/?.lua;' .. package.path
local R = require 'regex'

-- Tiny JSON array reader, enough for the flat [[p,s,a,b],...] the generator emits.
local f = assert(io.open(os.getenv('SP') .. '/fuzz.json'))
local raw = f:read('a'); f:close()

local pos = 1
local function skipws() pos = raw:find('[^ \t\n\r]', pos) or #raw + 1 end
local function readstring()
  assert(raw:sub(pos, pos) == '"'); pos = pos + 1
  local buf = {}
  while true do
    local c = raw:sub(pos, pos)
    if c == '"' then pos = pos + 1 break end
    if c == '\\' then
      local e = raw:sub(pos + 1, pos + 1)
      pos = pos + 2
      if e == 'n' then buf[#buf+1] = '\n'
      elseif e == 't' then buf[#buf+1] = '\t'
      elseif e == 'r' then buf[#buf+1] = '\r'
      elseif e == 'u' then
        buf[#buf+1] = string.char(tonumber(raw:sub(pos, pos+3), 16) % 256); pos = pos + 4
      else buf[#buf+1] = e end
    else
      buf[#buf+1] = c; pos = pos + 1
    end
  end
  return table.concat(buf)
end
local function readnumber()
  local s, e = raw:find('^-?%d+', pos)
  local n = tonumber(raw:sub(s, e)); pos = e + 1
  return n
end

local cases = {}
skipws(); assert(raw:sub(pos, pos) == '['); pos = pos + 1
while true do
  skipws()
  local c = raw:sub(pos, pos)
  if c == ']' then break end
  if c == ',' then pos = pos + 1; skipws() end
  assert(raw:sub(pos, pos) == '['); pos = pos + 1
  skipws(); local p = readstring()
  skipws(); assert(raw:sub(pos,pos) == ','); pos = pos + 1
  skipws(); local s = readstring()
  skipws(); assert(raw:sub(pos,pos) == ','); pos = pos + 1
  skipws(); local a = readnumber()
  skipws(); assert(raw:sub(pos,pos) == ','); pos = pos + 1
  skipws(); local b = readnumber()
  skipws(); assert(raw:sub(pos,pos) == ']'); pos = pos + 1
  cases[#cases+1] = { p, s, a, b }
end

local ok, mismatch, cerr, budget = 0, 0, 0, 0
local shown = 0
for _, c in ipairs(cases) do
  local pat, subj, ea, eb = c[1], c[2], c[3], c[4]
  local rx, err = R.compile(pat)
  if not rx then
    cerr = cerr + 1
    if shown < 12 then
      print(string.format('COMPILE-FAIL  /%s/   %s', pat, err)); shown = shown + 1
    end
  else
    local a, b = rx:find(subj)
    if a == nil and b == 'budget' then
      budget = budget + 1
    else
      local ga, gb = a or 0, (a and b) or 0
      if ga == ea and gb == eb then
        ok = ok + 1
      else
        mismatch = mismatch + 1
        if shown < 12 then
          print(string.format('MISMATCH  /%s/  on %q   python=[%d,%d]  lua=[%d,%d]',
                              pat, subj, ea, eb, ga, gb))
          shown = shown + 1
        end
      end
    end
  end
end

print(string.format('\n%d agree, %d MISMATCH, %d compile-fail, %d budget  (of %d)',
                    ok, mismatch, cerr, budget, #cases))
os.exit((mismatch == 0 and cerr == 0) and 0 or 1)
