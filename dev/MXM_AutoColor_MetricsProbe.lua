--[[
  MXM_AutoColor_MetricsProbe.lua -- where does ImGui actually put things?

  Read-only. Touches no project, no rules file, no ExtState.

  Screenshots alone could not answer this: a crop saved at an unknown zoom
  gives ratios but not pixels, and "the glyph is 2px low" means nothing without
  knowing what one logical pixel is worth on that capture. So this window draws
  its own ruler -- a crosshair through the exact geometric centre of every
  widget's item rect, on the same pixels as the widget. Whatever the capture is
  scaled to, the glyph is either on the crosshair or it is not.

  What to do with it:

    1. Run it. Screenshot the window.
    2. Read off which widgets have their ink centred on the crosshair.
    3. Drag the Text size slider to 24 and screenshot again.
    4. Drag "tab item padding.y" on the second tab strip and watch its labels.

  Step 3 is the one that decides the open question. If the offset DOUBLES with
  the font size, it is proportional -- arithmetic, in our code or ImGui's, and
  fixable here. If it stays about the same number of pixels, it is glyph
  rasterisation and no amount of layout maths will move it.

  The console log carries what ImGui thinks the numbers are, to compare against
  what the screenshot shows.
]]

local sep = package.config:sub(1, 1)
local _, thisFile = reaper.get_action_context()
local ROOT = thisFile:match('^(.*[\\/])')
-- dev/ sits beside the package, not inside it
local PKG = ROOT .. '..' .. sep .. 'Reaper' .. sep .. 'Scripts' .. sep .. 'MXM_AutoColor' .. sep
package.path = PKG .. '?.lua;' .. PKG .. 'lib' .. sep .. '?.lua;' .. package.path

if not reaper.APIExists('ImGui_GetBuiltinPath') then
  reaper.ShowMessageBox('This probe needs ReaImGui.', 'AutoColor probe', 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ok, ImGui = pcall(function() return require 'imgui' '0.10' end)
if not ok then
  reaper.ShowMessageBox('ReaImGui 0.10+ required.\n\n' .. tostring(ImGui),
                        'AutoColor probe', 0)
  return
end

local theme = require 'gui.theme'

local ctx  = ImGui.CreateContext('AutoColor metrics')
local FONT = ImGui.CreateFont('sans-serif')
ImGui.Attach(ctx, FONT)
theme.init(ImGui, ctx)

local size    = 12          -- matches the default rule-window text size
local logged  = false       -- console gets one dump per size change
local frames  = 0           -- a tab bar has no layout on frame 1, and reading
                            -- its item rect there returns zeros, so the dump
                            -- waits until the window has settled
local DUMP_ON = 3
local dumping = false
local lines   = {}

local CROSS   = 0xFF00FFFF  -- magenta, on nothing else in the window
local BOUNDS  = 0x00FF00FF  -- green box on the item rect

local function w(fmt, ...)
  lines[#lines + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
end

--- Draw a crosshair and a box on the LAST item, and record its numbers.
--- The lines go on after the widget, so they land on top of it.
local function mark(name)
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local x1, y1 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5

  -- Filled quads, not AddLine. A 1-thick AddLine goes through ImGui's polyline
  -- path, which wraps the stroke in an antialiasing fringe and lands about half
  -- a logical unit off the rect path AddRect strokes on -- ~1 device px at 175%,
  -- constant at every font size, and enough to read as a misplaced crosshair on
  -- the very marker you are measuring against.
  ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, BOUNDS)
  ImGui.DrawList_AddRectFilled(dl, x0, cy - 0.5, x1, cy + 0.5, CROSS)
  ImGui.DrawList_AddRectFilled(dl, cx - 0.5, y0, cx + 0.5, y1, CROSS)

  if dumping then
    w('  %-14s rect %6.2f x %-6.2f   centre (%.2f, %.2f)',
      name, x1 - x0, y1 - y0, cx, cy)
  end
end

local cb1, cb2 = true, false
local tabpady  = 2.0        -- item padding for the mismatched strip below

local function frame()
  frames = frames + 1
  dumping = (not logged) and (frames >= DUMP_ON)
  ImGui.PushFont(ctx, FONT, size)
  local FS = ImGui.GetFontSize(ctx)
  theme.push(FS)

  ImGui.SetNextWindowSize(ctx, FS * 34, FS * 34, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, 'AutoColor metrics probe', true)

  if visible then
    if dumping then
      reaper.ClearConsole()
      lines = {}
      w('=== AutoColor metrics probe ===')
      w('REAPER %s', reaper.GetAppVersion())
      local dpi = ImGui.GetWindowDpiScale and ImGui.GetWindowDpiScale(ctx) or -1
      local fpx, fpy = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      local ispx, ispy = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
      w('window dpi scale : %.4f', dpi)
      w('font size        : %.4f   (what GetFontSize reports)', FS)
      local _, th = ImGui.CalcTextSize(ctx, 'X')
      w('text height      : %.4f   (what ImGui lays out with)', th)
      w('  ratio          : %.4f', th / FS)
      w('frame height     : %.4f   (text height + 2 * padding.y)',
        ImGui.GetFrameHeight(ctx))
      w('frame padding    : %.4f, %.4f', fpx, fpy)
      w('item spacing     : %.4f, %.4f', ispx, ispy)
      w('')
      w('-- which theme.lua is actually loaded ------------------------------')
      w('GLYPH_NUDGE_Y    : %s', tostring(theme.GLYPH_NUDGE_Y))
      w('tab pad.y  bar   : %.4f', math.floor(FS * theme.TAB_PAD_Y + 0.5))
      w('           item  : %.4f%s', theme.tab_item_pad_y and theme.tab_item_pad_y(FS) or -1,
        theme.tab_item_pad_y and '' or '   <- OLD BUILD: no tab_item_pad_y at all')
      w('text_height()    : %s',
        theme.text_height and string.format('%.4f', theme.text_height())
        or 'MISSING  <- OLD BUILD')
      w('If GLYPH_NUDGE_Y above is not the number in theme.lua, REAPER is')
      w('running a different copy of the file than the one you are editing.')
      w('')
      w('item rects, in logical units:')
    end

    local rv
    rv, size = ImGui.SliderInt(ctx, 'Text size', size, 8, 32)
    if rv then logged, frames = false, 0 end
    ImGui.Spacing(ctx)

    -- 1. the theme's checkbox, both states: the tick is drawn by us
    rv, cb1 = theme.checkbox('##cb_on', cb1);  mark('checkbox on')
    ImGui.SameLine(ctx)
    rv, cb2 = theme.checkbox('##cb_off', cb2); mark('checkbox off')
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'theme.checkbox -- tick drawn by draw_tick()')

    ImGui.Spacing(ctx)

    -- 2. the square icon buttons: glyph drawn by theme, lifted by GLYPH_NUDGE_Y
    theme.icon_button('+');  mark('icon_button +')
    ImGui.SameLine(ctx)
    theme.icon_button('x');  mark('icon_button x')
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'theme.icon_button -- glyph drawn by theme')

    ImGui.Spacing(ctx)

    -- 3. a stock button, for comparison: same text path, no square constraint
    ImGui.Button(ctx, 'Stock button'); mark('stock button')

    ImGui.Spacing(ctx)

    -- 4. a plain ImGui checkbox, to separate our tick from ImGui's own
    local dummy = true
    ImGui.Checkbox(ctx, '##stock_cb', dummy); mark('stock checkbox')
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'stock ImGui checkbox -- its own checkmark')

    ImGui.Spacing(ctx)

    -- 5. the tab strip, with the window's own roomier padding
    theme.push_tab_padding(FS)
    if ImGui.BeginTabBar(ctx, 'probe_tabs') then
      for _, name in ipairs({ 'Items (1)', 'Regions', 'Hxp' }) do
        local opened = ImGui.BeginTabItem(ctx, name)
        mark('tab ' .. name)
        if opened then
          theme.pop_tab_padding()
          ImGui.Text(ctx, 'tab contents')
          theme.push_tab_padding(FS)
          ImGui.EndTabItem(ctx)
        end
      end
      ImGui.EndTabBar(ctx)
    end
    theme.pop_tab_padding()

    ImGui.Spacing(ctx)

    -- 6. THE TEST: the bar and the tab items sized from DIFFERENT paddings.
    --
    -- ImGui reads FramePadding.y twice -- once in BeginTabBar to size the bar,
    -- once in BeginTabItem to size the tab and place its label. If it then
    -- forces each tab to the BAR's height, the two decouple: the tab stays as
    -- tall as the roomy bar while the label sits at the small item padding from
    -- its top, and the label rises. If the labels sit exactly where they do in
    -- the strip above, no such seam exists and only hand-drawn text can move
    -- them.
    --
    -- Drag the slider. Labels that move = the seam is real, and the value that
    -- centres them is the one to bake into push_tab_padding.
    ImGui.Text(ctx, 'mismatched padding -- bar roomy, items tight:')
    rv, tabpady = ImGui.SliderDouble(ctx, 'tab item padding.y', tabpady, 0.0, 12.0)

    local padx = math.floor(FS * theme.TAB_PAD_X + 0.5)
    theme.push_tab_padding(FS)                      -- the BAR takes this one
    local bar2 = ImGui.BeginTabBar(ctx, 'probe_tabs2')
    theme.pop_tab_padding()
    if bar2 then
      for _, name in ipairs({ 'Items (1)', 'Regions', 'Hxp' }) do
        -- ...and the ITEM takes this one, live at BeginTabItem
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, padx, tabpady)
        local opened = ImGui.BeginTabItem(ctx, name .. '##m')
        ImGui.PopStyleVar(ctx)
        mark('tabB ' .. name)
        if opened then
          ImGui.Text(ctx, 'tab contents')
          ImGui.EndTabItem(ctx)
        end
      end
      ImGui.EndTabBar(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, 'Hxp (1) -- plain text'); mark('plain text')

    if dumping then
      logged, dumping = true, false
      w('')
      w('Magenta crosshair = the geometric centre of the item rect.')
      w('Green box        = the item rect itself.')
      w('Ink centred on the crosshair means the widget is right.')
      w('')
      w('Now drag Text size to 24 and look again: an offset that DOUBLES is')
      w('arithmetic and fixable; one that stays put is glyph rasterisation.')
      w('')
      reaper.ShowConsoleMsg(table.concat(lines, '\n') .. '\n')
    end

    ImGui.End(ctx)
  end

  theme.pop()
  ImGui.PopFont(ctx)

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
