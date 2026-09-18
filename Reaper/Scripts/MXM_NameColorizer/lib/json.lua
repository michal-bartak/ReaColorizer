--[[
  json.lua -- just enough JSON for the config file.

  Chosen over a line-based format because patterns legitimately contain | , = :
  [ # and backslashes, so any delimiter scheme would need escaping anyway, and
  JSON's escaping is a solved problem. Rule sets also stay shareable.

  Two deliberate properties:
    * encode() emits a SINGLE LINE -- no newline ever appears in the output, so
      the same string is safe to round-trip through ExtState, which documents
      newlines as unsupported.
    * object keys are emitted in sorted order, so saving twice gives byte
      identical output and the file diffs cleanly.
]]

local M = {}

local concat, sort = table.concat, table.sort
local sbyte, sformat = string.byte, string.format

------------------------------------------------------------------- encode
local ESC = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s)
  return (s:gsub('[%c"\\]', function(c)
    return ESC[c] or sformat('\\u%04X', sbyte(c))
  end))
end

local encode_value

local function encode_table(v, out, seen)
  if seen[v] then error('cannot encode a cyclic table', 0) end
  seen[v] = true

  local n = #v
  local isarray = n > 0
  if isarray then
    -- verify it really is a dense array before treating it as one
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    isarray = (count == n)
  end

  if isarray then
    out[#out + 1] = '['
    for i = 1, n do
      if i > 1 then out[#out + 1] = ',' end
      encode_value(v[i], out, seen)
    end
    out[#out + 1] = ']'
  else
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then error('object keys must be strings', 0) end
      keys[#keys + 1] = k
    end
    sort(keys)
    out[#out + 1] = '{'
    for i, k in ipairs(keys) do
      if i > 1 then out[#out + 1] = ',' end
      out[#out + 1] = '"' .. escape_string(k) .. '":'
      encode_value(v[k], out, seen)
    end
    out[#out + 1] = '}'
  end

  seen[v] = nil
end

encode_value = function(v, out, seen)
  local t = type(v)
  if v == nil then
    out[#out + 1] = 'null'
  elseif t == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then
      error('cannot encode ' .. tostring(v), 0)
    end
    if math.type(v) == 'integer' then
      out[#out + 1] = sformat('%d', v)
    else
      out[#out + 1] = sformat('%.14g', v)
    end
  elseif t == 'string' then
    out[#out + 1] = '"' .. escape_string(v) .. '"'
  elseif t == 'table' then
    encode_table(v, out, seen)
  else
    error('cannot encode a ' .. t, 0)
  end
end

--- @return string on success, or nil + message
function M.encode(v)
  local out = {}
  local ok, err = pcall(encode_value, v, out, {})
  if not ok then return nil, tostring(err) end
  return concat(out)
end

------------------------------------------------------------------- decode
local function decode_error(s, pos, msg)
  local line = 1
  for _ in s:sub(1, pos):gmatch('\n') do line = line + 1 end
  error({ msg = sformat('%s at position %d', msg, pos) }, 0)
end

local decode_value

local function skipws(s, pos)
  return s:find('[^ \t\r\n]', pos) or #s + 1
end

local UNESC = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
  f = '\f', n = '\n', r = '\r', t = '\t',
}

local function decode_string(s, pos)
  pos = pos + 1                      -- skip opening quote
  local buf = {}
  while true do
    local c = s:sub(pos, pos)
    if c == '' then decode_error(s, pos, 'unterminated string') end
    if c == '"' then return concat(buf), pos + 1 end
    if c == '\\' then
      local e = s:sub(pos + 1, pos + 1)
      local simple = UNESC[e]
      if simple then
        buf[#buf + 1] = simple
        pos = pos + 2
      elseif e == 'u' then
        local hex = s:sub(pos + 2, pos + 5)
        if not hex:match('^%x%x%x%x$') then decode_error(s, pos, 'bad \\u escape') end
        local cp = tonumber(hex, 16)
        buf[#buf + 1] = utf8 and utf8.char(cp) or string.char(cp % 256)
        pos = pos + 6
      else
        decode_error(s, pos, 'bad escape \\' .. e)
      end
    else
      buf[#buf + 1] = c
      pos = pos + 1
    end
  end
end

decode_value = function(s, pos)
  pos = skipws(s, pos)
  local c = s:sub(pos, pos)

  if c == '{' then
    local obj = {}
    pos = skipws(s, pos + 1)
    if s:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
      pos = skipws(s, pos)
      if s:sub(pos, pos) ~= '"' then decode_error(s, pos, 'expected a key') end
      local k; k, pos = decode_string(s, pos)
      pos = skipws(s, pos)
      if s:sub(pos, pos) ~= ':' then decode_error(s, pos, 'expected :') end
      obj[k], pos = decode_value(s, pos + 1)
      pos = skipws(s, pos)
      local d = s:sub(pos, pos)
      if d == ',' then pos = pos + 1
      elseif d == '}' then return obj, pos + 1
      else decode_error(s, pos, 'expected , or }') end
    end

  elseif c == '[' then
    local arr = {}
    pos = skipws(s, pos + 1)
    if s:sub(pos, pos) == ']' then return arr, pos + 1 end
    while true do
      arr[#arr + 1], pos = decode_value(s, pos)
      pos = skipws(s, pos)
      local d = s:sub(pos, pos)
      if d == ',' then pos = pos + 1
      elseif d == ']' then return arr, pos + 1
      else decode_error(s, pos, 'expected , or ]') end
    end

  elseif c == '"' then
    return decode_string(s, pos)

  elseif s:sub(pos, pos + 3) == 'true'  then return true,  pos + 4
  elseif s:sub(pos, pos + 4) == 'false' then return false, pos + 5
  elseif s:sub(pos, pos + 3) == 'null'  then return nil,   pos + 4

  else
    local a, b = s:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    if not a then decode_error(s, pos, 'unexpected character ' .. (c == '' and '<eof>' or c)) end
    local num = tonumber(s:sub(a, b))
    if not num then decode_error(s, pos, 'bad number') end
    return num, b + 1
  end
end

--- @return value on success, or nil + message
function M.decode(s)
  if type(s) ~= 'string' then return nil, 'input is not a string' end
  local ok, res, pos = pcall(decode_value, s, 1)
  if not ok then
    local e = res
    return nil, type(e) == 'table' and e.msg or tostring(e)
  end
  local after = skipws(s, pos)
  if after <= #s then return nil, 'trailing content at position ' .. after end
  return res
end

return M
