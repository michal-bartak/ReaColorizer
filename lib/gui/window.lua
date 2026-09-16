--[[
  gui/window.lua -- top bar, banners, layout.

  Sizing rule for the whole window: every dimension is a multiple of
  ImGui.GetFontSize(ctx). ReaImGui already reports coordinates in logical,
  DPI-independent units and rasterises glyphs at the device resolution, so
  multiplying by GetWindowDpiScale (2.0 on a Retina Mac) would render the UI at
  double size. Sizing off the font is what makes this correct on any display.
]]

local config   = require 'config'
local rulesmod = require 'rules'
local app      = require 'gui.app'
local ruletbl  = require 'gui.rule_table'
local preview  = require 'gui.preview'
local theme    = require 'gui.theme'

local M = {}

local ImGui, ctx
function M.init(imgui, context)
  ImGui, ctx = imgui, context
  ruletbl.init(imgui, context)
  preview.init(imgui, context)
end

local function rgba(rgb, a) return ((rgb & 0xFFFFFF) << 8) | (a or 0xFF) end

local COL_DIM   = 0x9A9A9A
local COL_WARN  = 0xD9A441
local COL_ERR   = 0xC2413B
local COL_OK    = 0x5FB36A

local FOLDER_LABEL = {
  off            = 'off -- folders do not colour their children',
  fill_unmatched = 'fill gaps -- children with no rule of their own inherit',
  force          = 'force -- the folder colour overrides its children',
}

----------------------------------------------------------------------- bars
local function banners(FS)
  local st = app.st

  if st.readonly then
    ImGui.TextColored(ctx, rgba(COL_WARN),
      'This rule file was written by a newer version. Editing is allowed but nothing will be saved.')
  end

  local sws = app.sws_warning()
  if sws then
    ImGui.TextColored(ctx, rgba(COL_WARN), sws)
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, rgba(COL_DIM), '(SWS > Auto Color/Icon/Layout)')
  end

end

--- The status line, at the foot of the window.
--- It ALWAYS occupies exactly one line, whether or not there is anything to
--- say: a line that comes and goes reflows everything above it, so the whole
--- window used to jump down and back each time a message timed out. `y` is the
--- content position reserved for it; the line is pushed there only when the
--- content above fell short, so it cannot overlap an overflowing layout.
local function status_line(y)
  if ImGui.GetCursorPosY(ctx) < y then ImGui.SetCursorPosY(ctx, y) end
  local toast = app.current_toast()
  if toast then
    ImGui.TextColored(ctx, rgba(COL_OK), toast)
  else
    ImGui.Text(ctx, '')
  end
end

-- One name, used by both OpenPopup and BeginPopupModal.
local OPTIONS_POPUP = 'Options'

local function options_popup(FS)
  local st = app.st

  -- Centre on the app window (not the screen) and dim what is behind it.
  -- Cond_Appearing so a window the user has since dragged stays put.
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww, wh = ImGui.GetWindowSize(ctx)
  ImGui.SetNextWindowPos(ctx, wx + ww * 0.5, wy + wh * 0.5,
                         ImGui.Cond_Appearing, 0.5, 0.5)

  -- Fixed width, automatic height (0 on an axis means auto-fit).
  ImGui.SetNextWindowSize(ctx, FS * 34, 0, ImGui.Cond_Appearing)

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,
                     FS * theme.MODAL_PAD, FS * theme.MODAL_PAD)

  -- A plain popup, not a modal. Two reasons:
  --   * Its dim overlay could not be controlled. ImGui paints
  --     Col_ModalWindowDimBg during Render(), long after any PushStyleColor
  --     here has been popped, so it always used the style default -- which in
  --     the dark style is (0.8, 0.8, 0.8, 0.35), i.e. WHITE. That is why the
  --     window appeared to brighten. The overlay is drawn by hand instead
  --     (see M.draw), which also means any colour is possible.
  --   * Escape closes a popup on its own; the modal was swallowing it.
  -- The name must be the SAME STRING OpenPopup was given: the popup is found
  -- by hashing it.
  local visible = ImGui.BeginPopup(ctx, OPTIONS_POPUP)

  ImGui.PopStyleVar(ctx)      -- window style is read at Begin

  if not visible then return end
  local o = st.cfg.options

  theme.section('Folders')
  ImGui.SetNextItemWidth(ctx, FS * 26)
  if ImGui.BeginCombo(ctx, '##folders', FOLDER_LABEL[o.propagate_folders]) then
    for _, k in ipairs({ 'off', 'fill_unmatched', 'force' }) do
      if ImGui.Selectable(ctx, FOLDER_LABEL[k], o.propagate_folders == k) then
        app.snapshot(); o.propagate_folders = k; app.mark_dirty()
      end
    end
    ImGui.EndCombo(ctx)
  end

  theme.section('Scope', true)
  local rv, v
  ImGui.Text(ctx, 'Reset to the default colour when no rule matches:')
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx,
      'Makes the rules the single source of truth for that kind.\n\n' ..
      'Careful: it also strips colours you set by hand.')
  end
  for _, k in ipairs(rulesmod.KINDS) do
    ImGui.SameLine(ctx)
    local rvc, vc = theme.checkbox(rulesmod.KIND_LABEL[k] .. '##cu' .. k,
                                   o.clear_unmatched[k])
    if rvc then app.snapshot(); o.clear_unmatched[k] = vc; app.mark_dirty() end
    if ImGui.IsItemHovered(ctx) and k == 'item' then
      ImGui.SetTooltip(ctx,
        'Recommended for items.\n\n' ..
        'An item with no custom colour is drawn by REAPER in its TRACK\'s\n' ..
        'colour, live -- so copying it to another track makes it follow that\n' ..
        'track immediately, with no rule and nothing to go stale.\n\n' ..
        'This is usually better than "also colour items" on the track rules,\n' ..
        'which freezes a colour onto the item instead.')
    end
  end

  theme.section('Background auto-colouring', true)
  rv, v = theme.checkbox('Create undo points for automatic changes', o.auto_undo)
  if rv then app.snapshot(); o.auto_undo = v; app.mark_dirty() end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Off by default: an undo point every time you rename\n' ..
                          'a track would shred your undo history, and colours\n' ..
                          'can always be re-derived from the rules.')
  end

  ImGui.SetNextItemWidth(ctx, FS * 10)
  rv, v = ImGui.SliderDouble(ctx, 'Check every (s)', o.tick_interval, 0.05, 2.0, '%.2f')
  if rv then o.tick_interval = v; app.mark_dirty(true) end

  ImGui.SetNextItemWidth(ctx, FS * 10)
  rv, v = ImGui.SliderInt(ctx, 'Work budget (ms)', math.floor(o.cold_budget_ms), 1, 50)
  if rv then o.cold_budget_ms = v; app.mark_dirty(true) end

  theme.section('Window', true)
  ImGui.SetNextItemWidth(ctx, FS * 10)
  rv, v = ImGui.SliderInt(ctx, 'Text size', math.floor(o.font_size), 8, 32)
  if rv then o.font_size = v; app.mark_dirty(true) end

  theme.section('Rules file', true)
  ImGui.TextColored(ctx, rgba(COL_DIM), config.path())
  if ImGui.Button(ctx, 'Replace with the starter rules...') then
    local ans = reaper.ShowMessageBox(
      'Replace your current rules with the built-in starter set?\n\n' ..
      'Your existing rules will be gone. This can be undone with the ' ..
      'Undo button while the window is open.',
      'Name Colorizer', 4)
    if ans == 6 then
      app.snapshot()
      app.st.cfg.rules = config.starter().rules
      app.mark_dirty()
      app.toast('Loaded the starter rules.')
    end
  end

  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  local bw = FS * 8
  theme.center(bw)
  if ImGui.Button(ctx, 'Close', bw) then ImGui.CloseCurrentPopup(ctx) end

  ImGui.EndPopup(ctx)
end

local function clear_popup()
  if not ImGui.BeginPopup(ctx, 'clearmenu') then return end

  if ImGui.MenuItem(ctx, 'Clear colours the rules match') then
    app.clear_colors('matched')
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Resets only objects a rule currently claims.')
  end

  if ImGui.MenuItem(ctx, 'Clear EVERY custom colour in the project...') then
    local ans = reaper.ShowMessageBox(
      'Reset every custom colour in this project to the theme default?\n\n' ..
      'This includes colours this tool never set. Undo (Cmd+Z) will put ' ..
      'them back.',
      'Name Colorizer', 4)
    if ans == 6 then app.clear_colors('all') end
  end

  ImGui.EndPopup(ctx)
end

local function auto_button(FS, w)
  local running = app.auto_running()
  local paused  = running and app.auto_paused()

  local label, col
  if not running     then label, col = 'Auto: off',    COL_DIM
  elseif paused      then label, col = 'Auto: paused', COL_WARN
  else                    label, col = 'Auto: on',     COL_OK end

  ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(col))
  local clicked = ImGui.Button(ctx, label, w)
  ImGui.PopStyleColor(ctx)

  if ImGui.IsItemHovered(ctx) then
    if not running then
      ImGui.SetTooltip(ctx, app.auto_command_id()
        and 'Background auto-colouring is off.\nClick to start it.'
        or  'Background auto-colouring is off.\n\nRun the action\n' ..
            'MB_NameColorizer_AutoToggle.lua once; after that\n' ..
            'this button can start and stop it.')
    else
      ImGui.SetTooltip(ctx, 'Background auto-colouring is running.\n' ..
                            'Click to stop it.')
    end
  end

  if clicked then app.toggle_auto() end
end

--- The action bar. Drawn BELOW the rule table, so "+ rule" already knows which
--- tab is open in this frame rather than lagging one behind.
local function action_bar(FS)
  local st = app.st
  local startx = ImGui.GetCursorPosX(ctx)
  local availw = ImGui.GetContentRegionAvail(ctx)

  -- editing the list first, since that is what the table above is for
  local kindnoun = rulesmod.KIND_NOUN[app.st.active_kind] or 'rule'
  if ImGui.Button(ctx, '+ ' .. kindnoun .. ' rule', FS * 8) then app.add_rule() end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Add a rule to the ' ..
                          (rulesmod.KIND_LABEL[app.st.active_kind] or '') .. ' tab.')
  end

  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not app.can_undo())
  if ImGui.Button(ctx, 'Undo', FS * 4) then app.undo() end
  ImGui.EndDisabled(ctx)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Undo a change to the RULES (Cmd+Z in this window).\n' ..
                          'Colour changes in the project use REAPER\'s own undo.')
  end

  ImGui.SameLine(ctx)
  ImGui.TextColored(ctx, rgba(COL_DIM), '|')
  ImGui.SameLine(ctx)

  if ImGui.Button(ctx, 'Apply now', FS * 7) then app.apply_all() end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Colour the whole project. One undo point.\n' ..
                          'Also tells background auto-colouring to stop treating\n' ..
                          'hand-picked colours as untouchable.')
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Selection', FS * 6) then app.apply_selection() end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Colour only the selected tracks and items.')
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Clear...', FS * 5) then ImGui.OpenPopup(ctx, 'clearmenu') end
  clear_popup()

  if st.dirty then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, rgba(COL_DIM), 'saving...')
  end

  -- Auto and Options live on the right-hand end of the bar.
  local wauto, wopts, gap = FS * 9, FS * 6.5, FS * 0.5
  ImGui.SameLine(ctx, startx + availw - (wauto + gap + wopts))
  auto_button(FS, wauto)

  ImGui.SameLine(ctx, 0, gap)
  -- Only opens it. The dialog itself is drawn at the end of M.draw, outside
  -- the dimmed region, so it does not fade along with the window behind it.
  if ImGui.Button(ctx, 'Options', wopts) then ImGui.OpenPopup(ctx, OPTIONS_POPUP) end
end

------------------------------------------------------------------- the body
function M.draw(FS)
  local st = app.st

  -- Everything below fades while the Options dialog is open.
  local dimmed = ImGui.IsPopupOpen(ctx, OPTIONS_POPUP)
  if dimmed then theme.push_content_dim() end

  banners(FS)

  local availw, availh = ImGui.GetContentRegionAvail(ctx)

  -- Carve the status line off the bottom before anything else is measured, so
  -- the space is held for it whether or not a message is showing.
  local statush = ImGui.GetTextLineHeightWithSpacing(ctx)
  local statusy = ImGui.GetCursorPosY(ctx) + availh - statush
  availh = availh - statush

  local bottom = math.min(math.max(FS * 13, availh * 0.35), availh * 0.6)
  local barh   = ImGui.GetFrameHeight(ctx) + FS * 0.9   -- the action bar below
  local tableh = availh - bottom - barh - FS * 3.2      -- and the tab strip

  -- One ordered list per object kind. Precedence is per-kind, so reordering
  -- your track rules cannot change which region wins.
  theme.push_tab_padding(FS)
  if ImGui.BeginTabBar(ctx, 'kinds') then
    for _, kind in ipairs(rulesmod.KINDS) do
      local on, total = app.count(kind)
      local label = string.format('%s%s###%s', rulesmod.KIND_LABEL[kind],
                                  total > 0 and (' (' .. total .. ')') or '', kind)
      if ImGui.BeginTabItem(ctx, label) then
        theme.pop_tab_padding()          -- contents use ordinary padding
        st.active_kind = kind

        if total == 0 then
          ImGui.TextColored(ctx, rgba(COL_DIM), 'No ' ..
            (rulesmod.KIND_NOUN[kind] or '') .. ' rules yet -- add one above.')
        elseif on == 0 then
          ImGui.TextColored(ctx, rgba(COL_WARN), 'Every rule on this tab is switched off.')
        end

        ruletbl.draw(kind, FS, math.max(tableh, FS * 6))
        theme.push_tab_padding(FS)       -- restore for the strip itself
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end
  theme.pop_tab_padding()

  ImGui.Spacing(ctx)
  action_bar(FS)
  ImGui.Spacing(ctx)

  local leftw = math.floor(availw * 0.58)
  preview.draw_list(FS, leftw, bottom)
  ImGui.SameLine(ctx)
  preview.draw_tester(FS, availw - leftw - FS, bottom)

  status_line(statusy)

  if dimmed then theme.pop_content_dim() end

  -- Drawn last and at full opacity, after the dim has been lifted.
  options_popup(FS)
end

return M
