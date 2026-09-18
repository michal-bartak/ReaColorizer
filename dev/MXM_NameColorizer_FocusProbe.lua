--[[
  MXM_NameColorizer_FocusProbe.lua -- what did you touch last?

  Read-only. Changes nothing; it only reports.

  REAPER lets a track selection and an item selection exist at the same time,
  so "apply to selection" has to guess which one you meant. REAPER's own
  answer is the CURSOR CONTEXT -- the thing its "...depending on focus"
  actions key off. This probe shows what that context says, so we can find out
  whether it is trustworthy here before anything is built on it.

  Run it several times and read the console log:
    1. click a track panel      -> run
    2. click an item            -> run
    3. click inside the
       Name Colorizer window    -> run      <- the one that matters: does our
                                              own window clobber the context?
    4. click the arrange
       background               -> run
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

local entry = require 'entry'

local CONTEXT = { [-1] = 'unknown', [0] = 'track panels', [1] = 'items',
                  [2] = 'envelopes' }
local function ctxname(v)
  if v == nil then return 'n/a' end
  return CONTEXT[v] or ('? (' .. tostring(v) .. ')')
end

local out = { '', '--- Name Colorizer focus probe -------------------------' }
local function say(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

-- Existence first. Assuming an API is there has bitten this project twice.
local has1 = reaper.APIExists('GetCursorContext')
local has2 = reaper.APIExists('GetCursorContext2')
say('GetCursorContext  present : %s', tostring(has1))
say('GetCursorContext2 present : %s', tostring(has2))

local live, last
if has1 then live = reaper.GetCursorContext() end
-- want_last_valid: keeps the last real answer instead of going to -1 when the
-- focus has moved somewhere with no context at all.
if has2 then last = reaper.GetCursorContext2(true) end

say('cursor context (live)     : %s', ctxname(live))
say('cursor context (last valid): %s', ctxname(last))

local ntr = reaper.CountSelectedTracks(0)
local nit = reaper.CountSelectedMediaItems(0)
say('selected tracks           : %d', ntr)
say('selected items            : %d', nit)

-- What a focus-aware "apply to selection" would decide, if the context is
-- reliable. Stated as a prediction so it can be checked against what you
-- actually meant each time you run this.
local verdict
if nit == 0 and ntr == 0 then verdict = 'nothing selected'
elseif nit == 0             then verdict = 'tracks (no items selected)'
elseif ntr == 0             then verdict = 'items (no tracks selected)'
else
  local c = last or live
  if     c == 1 then verdict = 'items (both selected; focus says items)'
  elseif c == 0 then verdict = 'tracks (both selected; focus says track panels)'
  else               verdict = 'AMBIGUOUS -- both selected and focus is ' .. ctxname(c)
  end
end
say('a focus-aware apply would use: %s', verdict)

entry.console(table.concat(out, '\n'))
