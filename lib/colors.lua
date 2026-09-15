--[[
  colors.lua -- colour representation and conversion.

  Canonical form throughout this project is a plain 0xRRGGBB integer. REAPER's
  native form is OS dependent (RGB on macOS/Linux, BGR on Windows), so native
  values are produced only at the moment of writing to the API and are NEVER
  persisted -- otherwise a shared config renders blue-for-red across platforms.

  The maths here is pure; only to_native/from_native touch the REAPER API, and
  they do so lazily so this module can be unit-tested outside REAPER.
]]

local M = {}

local floor, min, max = math.floor, math.min, math.max

------------------------------------------------------------------ packing
function M.pack(r, g, b)
  return (r & 0xFF) << 16 | (g & 0xFF) << 8 | (b & 0xFF)
end

function M.split(rgb)
  rgb = rgb or 0
  return (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
end

--- Normalise an I_CUSTOMCOLOR reading for comparison.
--- The API hands back a double that can be negative on some builds, so both
--- sides of any equality test must go through this.
function M.norm(v)
  v = floor(v or 0)
  if v < 0 then v = v + 0x100000000 end
  return v & 0x1FFFFFF          -- 24 bits of colour plus the "enabled" bit
end

------------------------------------------------------- REAPER native colours
local ENABLE = 0x1000000

--- 0xRRGGBB -> the value to store in I_CUSTOMCOLOR (enable bit set).
function M.to_native(rgb)
  local r, g, b = M.split(rgb)
  return reaper.ColorToNative(r, g, b) | ENABLE
end

--- An I_CUSTOMCOLOR reading -> 0xRRGGBB, or nil when no custom colour is set.
function M.from_native(v)
  v = M.norm(v)
  if v == 0 then return nil end          -- 0 means "no colour", not black
  local r, g, b = reaper.ColorFromNative(v & 0xFFFFFF)
  return M.pack(r, g, b)
end

M.ENABLE = ENABLE

---------------------------------------------------------------------- HSL
-- Gradients interpolate in HSL so a spread between two hues sweeps around the
-- colour wheel instead of sagging through grey the way RGB interpolation does.

function M.rgb_to_hsl(rgb)
  local r, g, b = M.split(rgb)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = max(r, g, b), min(r, g, b)
  local l = (mx + mn) / 2
  if mx == mn then return 0, 0, l end    -- achromatic: hue is meaningless

  local d = mx - mn
  local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
  local h
  if mx == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif mx == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6, s, l
end

local function hue2rgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

function M.hsl_to_rgb(h, s, l)
  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    r = hue2rgb(p, q, h + 1 / 3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1 / 3)
  end
  return M.pack(floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

--- Interpolate between two colours, t in [0,1].
--- Hue takes the shorter way round the wheel; an achromatic endpoint borrows
--- the other's hue so fading to grey does not swing through an unrelated colour.
function M.lerp(c1, c2, t)
  if t <= 0 then return c1 end
  if t >= 1 then return c2 end

  local h1, s1, l1 = M.rgb_to_hsl(c1)
  local h2, s2, l2 = M.rgb_to_hsl(c2)

  if s1 == 0 then h1 = h2 end
  if s2 == 0 then h2 = h1 end

  local dh = h2 - h1
  if dh > 0.5 then dh = dh - 1 elseif dh < -0.5 then dh = dh + 1 end
  local h = (h1 + dh * t) % 1

  return M.hsl_to_rgb(h, s1 + (s2 - s1) * t, l1 + (l2 - l1) * t)
end

--- Colour number `i` of `n` on a gradient. n == 1 yields the first colour.
function M.gradient(c1, c2, i, n)
  if n <= 1 or c2 == nil then return c1 end
  return M.lerp(c1, c2, (i - 1) / (n - 1))
end

--------------------------------------------------------------------- misc
--- "#RRGGBB" for display and for the config file's human-readable comments.
function M.tohex(rgb)
  return string.format('#%06X', rgb & 0xFFFFFF)
end

function M.fromhex(s)
  local h = tostring(s):match('^#?(%x%x%x%x%x%x)$')
  if not h then return nil end
  return tonumber(h, 16)
end

return M
