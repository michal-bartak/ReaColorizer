--[[
  MB_NameColorizer_GUI.lua -- the configuration window.

  Requires ReaImGui 0.10+. Everything else in this package works without it.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
package.path = ROOT .. '?.lua;' .. ROOT .. 'lib' .. sep .. '?.lua;' .. package.path

------------------------------------------------------------------ dependency
if not reaper.APIExists('ImGui_GetBuiltinPath') then
  reaper.ShowMessageBox(
    'Name Colorizer needs ReaImGui, which is not installed.\n\n' ..
    'Extensions > ReaPack > Browse packages > search "ReaImGui"\n' ..
    '> right-click > Install, then restart REAPER.\n\n' ..
    'The Apply and Clear actions work without it.',
    'Name Colorizer: missing dependency', 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ok, ImGui = pcall(function() return require 'imgui' '0.10' end)
if not ok then
  reaper.ShowMessageBox(
    'ReaImGui 0.10 or newer is required.\n\n' .. tostring(ImGui) ..
    '\n\nUpdate it through ReaPack and restart REAPER.',
    'Name Colorizer: ReaImGui too old', 0)
  return
end

----------------------------------------------------------- single instance
local config = require 'config'
local SECT   = config.EXT_SECTION

if reaper.GetExtState(SECT, 'gui_open') == '1' then
  -- A stale flag would lock the window out forever, so let the user through
  -- after confirming rather than refusing outright.
  local ans = reaper.ShowMessageBox(
    'A Name Colorizer window seems to be open already.\n\n' ..
    'Open another one anyway? (Two windows editing the same rules can ' ..
    'overwrite each other.)', 'Name Colorizer', 4)
  if ans ~= 6 then return end
end
reaper.SetExtState(SECT, 'gui_open', '1', false)

------------------------------------------------------------------- start up
local app    = require 'gui.app'
local window = require 'gui.window'
local theme  = require 'gui.theme'

app.load()

local ctx  = ImGui.CreateContext('Name Colorizer')
local FONT = ImGui.CreateFont('sans-serif')      -- 0.10: no size here
ImGui.Attach(ctx, FONT)

window.init(ImGui, ctx)
theme.init(ImGui, ctx)

reaper.atexit(function()
  app.flush(true)                                -- never lose a pending edit
  reaper.DeleteExtState(SECT, 'gui_open', false)
end)

------------------------------------------------------------------ the frame
local function frame()
  local size = app.st.cfg.options.font_size or 14
  ImGui.PushFont(ctx, FONT, size)
  local FS = ImGui.GetFontSize(ctx)
  theme.push(FS)               -- before Begin, so the window itself is rounded

  ImGui.SetNextWindowSize(ctx, FS * 78, FS * 44, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, 'Name Colorizer', true)

  if visible then
    -- Rule edits live in a file, not the project, so REAPER's undo cannot
    -- reach them. This window keeps its own stack.
    if ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | ImGui.Key_Z) then
      app.undo()
    end

    app.refresh_entries(false)
    app.recompute_preview()

    local okdraw, err = pcall(window.draw, FS)
    if not okdraw then
      ImGui.TextColored(ctx, 0xC2413BFF, 'Drawing error: ' .. tostring(err))
    end

    ImGui.End(ctx)            -- ONLY when Begin returned true
  end

  theme.pop()                 -- always, and before PopFont
  ImGui.PopFont(ctx)          -- always, Begin or not

  app.flush(false)            -- debounced save

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
