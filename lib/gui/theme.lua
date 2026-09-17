--[[
  gui/theme.lua -- style tweaks, and cell-centring helpers.

  What ReaImGui 0.10 can and cannot do here, verified against the shipped docs:

    * Rounding: frames (buttons, inputs, checkboxes, combos), child panels,
      popups, tabs, scrollbars and grabs all have style vars.  TABLES DO NOT --
      Dear ImGui has no table rounding, so the rule table's own border stays
      square no matter what.
    * Table border THICKNESS is not adjustable either. Dear ImGui draws table
      borders at a hard-coded 1 unit. What is adjustable is how loud they are,
      via Col_TableBorderLight / Col_TableBorderStrong -- so the knob here is
      prominence, not width.
    * The rules above the section headings ARE removable:
      StyleVar_SeparatorTextBorderSize.

  Everything is sized off the font, so it stays proportionate at any text size
  and on any display. Nothing here multiplies by the DPI scale -- ReaImGui
  already works in logical units.
]]

local M = {}

-- Tweakables ---------------------------------------------------------------
M.ROUNDING        = 0.20   -- x font size; corner radius for frames and panels
M.SECTION_SCALE   = 1.07   -- x font size, for section headings
M.SECTION_CASE    = 'upper'-- 'upper' (LIKE THIS) | 'title' (Like This) | 'none'
                           -- No small-caps option: ImGui exposes no font
                           -- baseline or ascent and lays items out by their
                           -- tops, so mixing two sizes on one line can only
                           -- ever approximate baseline alignment.
M.SECTION_ALPHA   = 0.75   -- headings sit back a little from body text
M.GRID_ALPHA      = 0.45   -- 0..1, how visible the table grid lines are
M.BORDER_ALPHA    = 0.55   -- same for panel borders

M.PAD_X           = 0.55   -- x font size; horizontal padding inside controls
M.PAD_Y           = 0.28   -- x font size; vertical padding inside controls
M.TAB_PAD_X       = 1.10   -- tabs get their own, roomier padding
M.TAB_PAD_Y       = 0.50

M.FRAME_BG_ALPHA  = 0.60   -- backgrounds of checkboxes, text fields, combos
M.UNIFY_BUTTONS   = false  -- also drag buttons down to that background?
                           -- off: buttons keep the theme's own colour, which
                           -- matches the tabs
M.CHECKBOX_SCALE  = 0.62   -- x the normal control height; the tick box only
M.SWATCH_GAP      = 4      -- logical px between the two colour swatches and [+]/[x]

M.GHOST_CHECK       = 0x000000  -- a faint tick drawn on UNticked checkboxes,
M.GHOST_CHECK_ALPHA = 0.30      -- so the box reads as a checkbox either way
M.CHECK_THICKNESS   = 0.15      -- x the box height

M.MODAL_PAD       = 1.20   -- x font size; padding inside a modal dialog
M.DIM_CONTENT     = 0.30   -- 0..1; opacity of the window's content while a
                           -- dialog is open. Fades everything toward the dark
                           -- background, so bright elements lose the most --
                           -- which is what a veil over the top cannot do.

M.TABLE_H_LINES   = false  -- horizontal grid lines BETWEEN rows?
                           -- off: row striping separates rows instead
M.TABLE_V_LINES   = false  -- vertical grid lines between columns?
                           -- NOTE: turning these off also disables column
                           -- resizing. Dear ImGui forces BordersInnerV back on
                           -- whenever TableFlags_Resizable is set, so the two
                           -- cannot both be had.
M.TABLE_OUTER     = true   -- the border around the whole table

M.HEADER_FOLLOWS_TAB = true  -- paint the table's header row in the open tab's
                             -- colour, so tab and table read as one surface
M.TAB_INSET       = 1      -- logical px the tab strip is shifted right, to sit
                           -- on the table's header FILL rather than on its
                           -- outer border one pixel further left

M.HANDLE_ALPHA          = 0.50   -- the reorder grip, at rest
M.HANDLE_ALPHA_HOVER    = 0.70
M.HANDLE_ALPHA_SELECTED = 0.90

local ImGui, ctx
local nvars, ncols = 0, 0

function M.init(imgui, context) ImGui, ctx = imgui, context end

local function rgba(rgb, a)
  return ((rgb & 0xFFFFFF) << 8) | math.floor((a or 1) * 255)
end

--- Fade a colour that ImGui is already using, rather than inventing one, so
--- this keeps working if the user changes REAPER's theme.
local function dim(idx, alpha)
  local col = ImGui.GetStyleColor(ctx, idx)
  local a   = (col & 0xFF) / 255
  ImGui.PushStyleColor(ctx, idx, (col & ~0xFF) | math.floor(a * alpha * 255))
  ncols = ncols + 1
end

--- Push the whole look. Call once per frame, before Begin.
function M.push(FS)
  nvars, ncols = 0, 0
  local r = math.max(2, FS * M.ROUNDING)

  local function var(idx, a, b)
    ImGui.PushStyleVar(ctx, idx, a, b)
    nvars = nvars + 1
  end

  var(ImGui.StyleVar_FrameRounding,     r)
  var(ImGui.StyleVar_ChildRounding,     r)
  var(ImGui.StyleVar_PopupRounding,     r)
  var(ImGui.StyleVar_WindowRounding,    r)
  var(ImGui.StyleVar_TabRounding,       r)
  var(ImGui.StyleVar_GrabRounding,      r)
  var(ImGui.StyleVar_ScrollbarRounding, r)

  var(ImGui.StyleVar_FramePadding, FS * M.PAD_X, FS * M.PAD_Y)

  -- Checkboxes, text fields and combos all draw on Col_FrameBg, while buttons
  -- draw on Col_Button -- which is why a checkbox looks unlike a button in most
  -- themes. Dim the frame backgrounds, then optionally give buttons the same
  -- ones so the whole row reads as one family.
  dim(ImGui.Col_FrameBg,        M.FRAME_BG_ALPHA)
  dim(ImGui.Col_FrameBgHovered, M.FRAME_BG_ALPHA)
  dim(ImGui.Col_FrameBgActive,  M.FRAME_BG_ALPHA)

  if M.UNIFY_BUTTONS then
    local function copy(dst, src, alpha)
      local col = ImGui.GetStyleColor(ctx, src)
      local a   = (col & 0xFF) / 255
      ImGui.PushStyleColor(ctx, dst, (col & ~0xFF) | math.floor(a * alpha * 255))
      ncols = ncols + 1
    end
    copy(ImGui.Col_Button,        ImGui.Col_FrameBg,        M.FRAME_BG_ALPHA)
    copy(ImGui.Col_ButtonHovered, ImGui.Col_FrameBgHovered, M.FRAME_BG_ALPHA)
    copy(ImGui.Col_ButtonActive,  ImGui.Col_FrameBgActive,  M.FRAME_BG_ALPHA)
  end

  dim(ImGui.Col_TableBorderLight,  M.GRID_ALPHA)
  dim(ImGui.Col_TableBorderStrong, M.GRID_ALPHA)
  dim(ImGui.Col_Border,            M.BORDER_ALPHA)
  dim(ImGui.Col_Separator,         M.BORDER_ALPHA)
end

function M.pop()
  if ncols > 0 then ImGui.PopStyleColor(ctx, ncols); ncols = 0 end
  if nvars > 0 then ImGui.PopStyleVar(ctx, nvars);   nvars = 0 end
end

--- Tabs get roomier padding than everything else, and there is no separate
--- style var for them -- they use FramePadding at BeginTabItem time. So it is
--- pushed around the tab strip and lifted again for each tab's contents.
--- Round to a whole logical pixel.
---
--- A tab's width is CalcTextSize(label).x + FramePadding.x * 2, and ImGui
--- truncates each tab's LEFT edge to an integer without truncating its width:
---
---   window->DC.CursorPos = bar.Min + ImVec2(IM_TRUNC(tab->Offset - ...), 0)
---
--- So a fractional padding leaves every right edge mid-pixel while the next
--- left edge snaps, and the visible gap drifts with the accumulated fraction.
--- Measured at font size 14 with TAB_PAD_X = 1.10 (padding 15.4): gaps of
--- 3.20, 4.20, 4.20 against an ItemInnerSpacing of 4 -- a whole logical pixel
--- of difference, which is two device pixels on a Retina display and plainly
--- visible.
---
--- The glyph widths were all whole numbers (69, 54, 73, 70), so the padding was
--- the only fractional term and rounding it makes every gap exactly 4.00.
local function px(v) return math.floor(v + 0.5) end

function M.push_tab_padding(FS)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding,
                     px(FS * M.TAB_PAD_X), px(FS * M.TAB_PAD_Y))
end

function M.pop_tab_padding()
  ImGui.PopStyleVar(ctx)
end

----------------------------------------------------------------- centring
--- Move the cursor so an item `w` wide sits in the middle of what is left of
--- the current cell. Never moves left, so a too-narrow column just left-aligns.
function M.center(w)
  local avail = ImGui.GetContentRegionAvail(ctx)
  if avail > w then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (avail - w) * 0.5)
  end
end

--- Centre a framed widget (checkbox, small square control).
function M.center_frame()
  M.center(ImGui.GetFrameHeight(ctx))
end

--- Draw a tick inside the given box. ImGui only draws one when the box is
--- checked, so both states are drawn here instead: the real colour when on, a
--- ghost when off.
local function draw_tick(x0, y0, size, col)
  local dl  = ImGui.GetWindowDrawList(ctx)
  local t   = math.max(1, size * M.CHECK_THICKNESS)
  local pad = size * 0.24
  local ax, ay = x0 + pad,        y0 + size * 0.54
  local bx, by = x0 + size * 0.42, y0 + size - pad
  local cx, cy = x0 + size - pad,  y0 + pad
  ImGui.DrawList_AddLine(dl, ax, ay, bx, by, col, t)
  ImGui.DrawList_AddLine(dl, bx, by, cx, cy, col, t)
end

--- A checkbox with a smaller tick box than a full-height control. The box size
--- comes from FramePadding, so that is what gets squeezed; the row keeps its
--- height, which is set by the text fields around it.
--- @param centred  true inside a narrow table cell; false (default) for a
---                 normal labelled checkbox in a list, which must stay left
---                 aligned or the label ends up in the middle of the popup.
--- @return changed, value
function M.checkbox(label, value, centred)
  local full = ImGui.GetFrameHeight(ctx)
  local want = full * M.CHECKBOX_SCALE
  -- box height = font size + 2*padding.y, so solve for the padding we need
  local pad  = math.max(0, (want - ImGui.GetFontSize(ctx)) * 0.5)
  local box  = ImGui.GetFontSize(ctx) + pad * 2

  -- Take the theme's tick colour before hiding the built-in mark, so the
  -- "on" state still matches whatever REAPER's theme uses.
  local markcol = ImGui.GetStyleColor(ctx, ImGui.Col_CheckMark)
  local ghost   = ((M.GHOST_CHECK & 0xFFFFFF) << 8)
                  | math.floor(M.GHOST_CHECK_ALPHA * 255)

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, pad, pad)
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x00000000)   -- we draw it
  if centred then
    M.center(box)
    -- nudge down so the smaller box sits on the row's centre line, not its top
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + (full - box) * 0.5)
  end
  local rv, v = ImGui.Checkbox(ctx, label, value)
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx)

  -- The item rect spans box AND label, and with a shrunken box it can be
  -- taller than the box itself, so derive the square from `box` rather than
  -- assuming the rect is one.
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local _,  y1 = ImGui.GetItemRectMax(ctx)
  if x0 then
    draw_tick(x0, y0 + ((y1 - y0) - box) * 0.5, box, v and markcol or ghost)
  end

  return rv, v
end

--- Title Case, as CSS text-transform: capitalize does it -- the first letter
--- of each word, including after a hyphen ("auto-colouring" -> "Auto-Colouring").
local function titlecase(s)
  return (s:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest end))
end

--- A section heading: a little larger, slightly recessed, and flush left.
--- Drawn as plain text rather than SeparatorText, which indents its label by
--- SeparatorTextPadding.x (20 by default) with no way to reach it per-call.
--- @param divider draw a 1px rule above it (used between dialog sections)
function M.section(label, divider)
  if divider then
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
  end

  local col = ImGui.GetStyleColor(ctx, ImGui.Col_Text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,
                       (col & ~0xFF) | math.floor(M.SECTION_ALPHA * 255))

  local text = label
  if     M.SECTION_CASE == 'upper' then text = label:upper()
  elseif M.SECTION_CASE == 'title' then text = titlecase(label) end

  ImGui.PushFont(ctx, nil, ImGui.GetFontSize(ctx) * M.SECTION_SCALE)
  ImGui.Text(ctx, text)
  ImGui.PopFont(ctx)

  ImGui.PopStyleColor(ctx)
  ImGui.Spacing(ctx)
end

--- Fade the window's content while a dialog is up.
---
--- Two earlier attempts failed for instructive reasons:
---   * Col_ModalWindowDimBg is painted by ImGui during Render(), after every
---     PushStyleColor has been popped, so it always used the style default --
---     near-white in the dark style, which BRIGHTENED the window.
---   * A rect on the window's own draw list covers only that window. Scrolling
---     tables and BeginChild panels are separate child windows drawn afterwards,
---     so the table and the preview stayed undimmed.
--- StyleVar_Alpha is global and consulted as each widget draws, so it reaches
--- inside children -- and because it fades toward the background rather than
--- layering a veil, bright elements dim the most.
function M.push_content_dim()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_Alpha, M.DIM_CONTENT)
end

function M.pop_content_dim()
  ImGui.PopStyleVar(ctx)
end

--- Border and sizing flags for a rule table, per the tweakables above.
---
--- Resizable is in here rather than at the call site because it is not
--- independent: Dear ImGui's TableFixFlags does
---     if (flags & Resizable) flags |= BordersInnerV;
--- so asking for resizable columns silently reinstates the vertical lines.
--- When those are switched off, resizing goes with them.
function M.table_border_flags()
  local f = 0
  if M.TABLE_OUTER   then f = f | ImGui.TableFlags_BordersOuter  end
  if M.TABLE_H_LINES then f = f | ImGui.TableFlags_BordersInnerH end
  if M.TABLE_V_LINES then
    f = f | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_Resizable
  end
  return f
end

--- Centre a run of text.
function M.center_text(s)
  M.center((ImGui.CalcTextSize(ctx, s)))
end

--------------------------------------------------------------- small bits
--- A square button, so a row of them lines up regardless of how wide the
--- glyph inside happens to be. SmallButton sizes itself to its text, which is
--- why [+] and [x] came out different widths.
--- @return true when clicked
function M.icon_button(label, centred)
  local sz = ImGui.GetFrameHeight(ctx)
  if centred then M.center(sz) end
  return ImGui.Button(ctx, label, sz, sz)
end

function M.icon_size()
  return ImGui.GetFrameHeight(ctx)
end

--- A colour swatch the same square size as icon_button(). ColorEdit3 with
--- NoInputs otherwise takes the full item width, which is why the swatches came
--- out wider than the [+] and [x] beside them.
--- @return changed, rgb
function M.color_swatch(label, rgb)
  ImGui.SetNextItemWidth(ctx, ImGui.GetFrameHeight(ctx))
  return ImGui.ColorEdit3(ctx, label, rgb,
                          ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoLabel)
end

--- A row of mutually exclusive buttons. ImGui has no segmented control, so
--- the chosen one is drawn in the active-button colour and the others are left
--- at rest. Every button gets the width of the widest label, otherwise a row
--- of them comes out ragged.
--- @param items array of { value = ..., label = ... }
--- @return the value that was clicked, or nil
function M.segmented(id, items, current)
  local picked
  local sel = ImGui.GetStyleColor(ctx, ImGui.Col_ButtonActive)

  local w = 0
  for _, it in ipairs(items) do
    local tw = ImGui.CalcTextSize(ctx, it.label)
    if tw > w then w = tw end
  end
  w = w + 2 * px(ImGui.GetFontSize(ctx) * M.PAD_X)

  for i, it in ipairs(items) do
    if i > 1 then ImGui.SameLine(ctx, 0, M.SWATCH_GAP) end
    local on = it.value == current
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, sel)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, sel)
    end
    if ImGui.Button(ctx, it.label .. '##' .. id .. i, w, 0) then picked = it.value end
    if on then ImGui.PopStyleColor(ctx, 2) end
  end

  return picked
end

--- Put the next widget on the same line, with the swatch-row gap.
function M.same_line_tight()
  ImGui.SameLine(ctx, 0, M.SWATCH_GAP)
end

--- The reorder grip: quiet at rest, a little brighter under the pointer, and
--- never painting a background -- including when its row is selected.
--- Hover is taken from the previous frame, which is the only way to know it
--- before the widget is drawn.
local hovered = {}

function M.reorder_handle(id, selected, label)
  local a = M.HANDLE_ALPHA
  if selected then a = M.HANDLE_ALPHA_SELECTED
  elseif hovered[id] then a = M.HANDLE_ALPHA_HOVER end

  local text = ImGui.GetStyleColor(ctx, ImGui.Col_Text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, (text & ~0xFF) | math.floor(a * 255))
  ImGui.PushStyleColor(ctx, ImGui.Col_Header,        0x00000000)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, 0x00000000)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  0x00000000)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)

  -- Give it the full row height, otherwise it is only text-high and sits
  -- against the top of a row whose other cells are frame-high.
  ImGui.Selectable(ctx, label or '=', selected,
                   ImGui.SelectableFlags_None, 0, ImGui.GetFrameHeight(ctx))

  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx, 4)

  hovered[id] = ImGui.IsItemHovered(ctx)
end

--- A header row where chosen columns are centred. TableHeadersRow always
--- left-aligns, so the row has to be emitted by hand.
--- @param centred set of column indices (0-based) to centre
--- The open tab's colour. Anything meant to read as attached to the tab strip
--- takes its colour from here rather than from a constant, so it follows
--- whatever theme ReaImGui is running.
function M.tab_selected_color()
  return ImGui.GetStyleColor(ctx, ImGui.Col_TabSelected)
end

--- The height a tab is actually PAINTED: font size plus its own padding, top
--- and bottom. ImGui's tab bar reserves more room than this -- measured 31
--- against a painted 28 -- for its overline and border, and the cursor lands
--- below the reserved edge, not the painted one.
function M.tab_paint_height(FS)
  return FS + 2 * px(FS * M.TAB_PAD_Y)
end

--- Butt the next item up against the PAINTED bottom of the tab strip.
---
--- Two things sit in the way. ImGui leaves an ItemSpacing gap after the bar,
--- and the bar rect is taller than the tabs drawn in it. Closing only the
--- first left about 2px of window background showing through, which is what
--- broke the join.
---
--- @param tab_h  the tab item's measured height, from GetItemRectMin/Max
function M.close_tab_gap(FS, tab_h)
  local _, sy = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local reserved = 0
  if tab_h then reserved = math.max(0, tab_h - M.tab_paint_height(FS)) end
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) - sy - reserved)
end

function M.headers_row(ncolumns, centred)
  local tinted = M.HEADER_FOLLOWS_TAB
  if tinted then
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg, M.tab_selected_color())
  end
  ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
  for c = 0, ncolumns - 1 do
    if ImGui.TableSetColumnIndex(ctx, c) then
      local name = ImGui.TableGetColumnName(ctx, c) or ''
      if centred[c] and name ~= '' then M.center_text(name) end
      ImGui.TableHeader(ctx, name)
    end
  end
  if tinted then ImGui.PopStyleColor(ctx) end
end

return M
