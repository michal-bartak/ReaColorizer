--[[
  gui/preview.lua -- "which objects does this actually hit?"

  The single most useful thing a regex tool can show you. The list is computed
  with the real first-match-wins resolution, so it is not an approximation of
  what Apply would do -- it is the same code path.

  Alongside it sits a tester: a scratch pad with its own mode, pattern and
  name, for working an expression out before you commit it to a rule.
]]

local rulesmod = require 'rules'
local matcher  = require 'matcher'
local targets  = require 'targets'
local app      = require 'gui.app'
local theme    = require 'gui.theme'

local M = {}

local ImGui, ctx
function M.init(imgui, context) ImGui, ctx = imgui, context end

local function rgba(rgb, a) return ((rgb & 0xFFFFFF) << 8) | (a or 0xFF) end

local COL_DIM  = 0x9A9A9A
local COL_OK   = 0x5FB36A
local COL_ERR  = 0xC2413B
local COL_WARN = 0xD9A441

local KIND_TAG = { track = 'T', item = 'I', region = 'R', marker = 'M' }

local last_mode, last_pattern, last_subject

------------------------------------------------------------------ the list
--- The list follows the selected tab: on the Items tab you see items, and so
--- on. Items coloured by a track rule show up here, on the Items tab, labelled
--- "from its track" -- they are items, whatever painted them.
function M.draw_list(FS, w, h)
  local st = app.st
  if not ImGui.BeginChild(ctx, 'preview', w, h, ImGui.ChildFlags_Borders) then return end

  local kind   = st.active_kind or 'track'
  local plural = (rulesmod.KIND_LABEL[kind] or ''):lower()
  local rows   = (st.preview or {})[kind] or {}
  local total  = (st.preview_total or {})[kind] or 0

  theme.section('Objects preview')

  if total == 0 then
    ImGui.TextColored(ctx, rgba(COL_DIM),
      'This project has no ' .. plural .. ' to colour.')
    ImGui.EndChild(ctx)
    return
  end

  if #rows == 0 then
    ImGui.TextColored(ctx, rgba(COL_DIM), string.format(
      'None of your %s rules match any of the %d %s here.', plural, total, plural))
    ImGui.EndChild(ctx)
    return
  end

  local by_rule, by_track, by_folder = 0, 0, 0
  for _, p in ipairs(rows) do
    if p.from_track then by_track = by_track + 1
    elseif p.inherited then by_folder = by_folder + 1
    else by_rule = by_rule + 1 end
  end

  ImGui.TextColored(ctx, rgba(COL_DIM), string.format(
    '%d of %d %s will be coloured%s -- click one to select it in the project',
    #rows, total, plural, #rows >= 500 and ' (first 500 shown)' or ''))

  -- Spell out where the colours came from. Without this, a tab whose own rules
  -- all show 0 hits still lists objects, which looks like a bug and is not.
  if by_track > 0 or by_folder > 0 then
    local parts = {}
    if by_rule > 0 then
      parts[#parts + 1] = string.format('%d by %s rules', by_rule, plural:sub(1, -2))
    end
    if by_track > 0 then
      parts[#parts + 1] = string.format('%d from their track', by_track)
    end
    if by_folder > 0 then
      parts[#parts + 1] = string.format('%d from a parent folder', by_folder)
    end
    ImGui.TextColored(ctx, rgba(COL_DIM), '   (' .. table.concat(parts, ', ') .. ')')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        'Objects can get a colour without any rule on this tab matching them:\n' ..
        '  - an item takes its track\'s colour when that track\'s rule has\n' ..
        '    "also colour items" switched on\n' ..
        '  - a track with no rule of its own inherits from its parent folder\n\n' ..
        'That is why the Hits column can read 0 while objects are still listed.')
    end
  end
  ImGui.Spacing(ctx)

  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY
              | ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, 'previewtbl_' .. kind, 3, flags) then
    local FIX = ImGui.TableColumnFlags_WidthFixed
    ImGui.TableSetupColumn(ctx, '##c',  FIX, FS * 1.6)
    ImGui.TableSetupColumn(ctx, 'Name', ImGui.TableColumnFlags_WidthStretch, 2.0)
    ImGui.TableSetupColumn(ctx, 'Rule', ImGui.TableColumnFlags_WidthStretch, 1.0)

    for i, p in ipairs(rows) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.ColorButton(ctx, '##sw', rgba(p.color),
                        ImGui.ColorEditFlags_NoTooltip | ImGui.ColorEditFlags_NoDragDrop,
                        FS, FS)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, string.format('#%06X', p.color & 0xFFFFFF))
      end

      ImGui.TableSetColumnIndex(ctx, 1)
      local shown = p.name ~= '' and p.name or '(unnamed)'
      if ImGui.Selectable(ctx, shown, false, ImGui.SelectableFlags_SpanAllColumns) then
        targets.reveal(p.entry)
      end

      ImGui.TableSetColumnIndex(ctx, 2)
      if p.from_track then
        ImGui.TextColored(ctx, rgba(COL_DIM), p.track_name
          and ('from track: ' .. (p.track_name ~= '' and p.track_name or '(unnamed)'))
          or 'from its track')
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, 'No item rule matched it, so it takes the colour\n' ..
                                'of the track it sits on -- that track\'s rule has\n' ..
                                '"also colour items" switched on.')
        end
      elseif p.inherited then
        ImGui.TextColored(ctx, rgba(COL_DIM), 'from folder')
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, 'No rule of its own -- it inherits its parent\n' ..
                                'folder\'s colour (Options > Folders).')
        end
      else
        local lbl = p.rule.label ~= '' and p.rule.label or p.rule.pattern
        if p.rule.color2 then lbl = lbl .. '  ~' end
        ImGui.TextColored(ctx, rgba(COL_DIM), lbl)
        if ImGui.IsItemHovered(ctx) and p.rule.color2 then
          ImGui.SetTooltip(ctx, 'This rule spreads a gradient across its matches,\n' ..
                                'so each one gets a different shade.\n\n' ..
                                'Spread across: ' ..
                                (rulesmod.GRADIENT_LABEL[p.rule.gradient_scope] or '?'))
        end
        if ImGui.IsItemClicked(ctx) then st.sel_id = p.rule.id end
      end

      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end

  ImGui.EndChild(ctx)
end

--------------------------------------------------------------------- tester
--- A scratch pad for working an expression out: its own mode, its own
--- pattern, its own name to try them on.
---
--- It deliberately knows nothing about the selected rule or the project. It
--- used to test the selected rule against a typed name, which meant you could
--- not try anything out without first committing it to a rule -- and editing
--- the rule to experiment was the very thing you wanted to avoid.
local MODES = {
  { value = 'substring', label = 'contains' },
  { value = 'glob',      label = 'glob' },
  { value = 'regex',     label = 'regex' },
}

function M.draw_tester(FS, w, h)
  local st = app.st
  if not ImGui.BeginChild(ctx, 'tester', w, h, ImGui.ChildFlags_Borders) then return end
  local t = st.tester

  theme.section('Pattern tester')

  local picked = theme.segmented('tmode', MODES, t.mode)
  if picked then t.mode = picked end

  ImGui.Spacing(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  local rvp, pat = ImGui.InputTextWithHint(ctx, '##pattern', 'pattern', t.pattern)
  if rvp then t.pattern = pat end

  ImGui.SetNextItemWidth(ctx, -1)
  local rvs, subj = ImGui.InputTextWithHint(ctx, '##subject', 'a name to try it on', t.subject)
  if rvs then t.subject = subj end

  -- Only re-run when something actually changed; a slow pattern must not be
  -- evaluated on every frame.
  if t.pattern ~= last_pattern or t.mode ~= last_mode or t.subject ~= last_subject then
    last_pattern, last_mode, last_subject = t.pattern, t.mode, t.subject
    app.run_tester()
  end

  ImGui.Spacing(ctx)
  local res = t.result

  if not res then
    ImGui.TextColored(ctx, rgba(COL_DIM), '--')
  elseif res.err then
    ImGui.TextColored(ctx, rgba(COL_ERR), 'Invalid pattern')
    ImGui.TextWrapped(ctx, res.err .. (res.pos and ('  (at character ' .. res.pos .. ')') or ''))
  elseif res.budget then
    ImGui.TextColored(ctx, rgba(COL_WARN), 'Gave up: this pattern is too slow')
    ImGui.TextWrapped(ctx, 'It exceeded the safety budget, so it is treated as ' ..
      'no-match rather than being allowed to freeze REAPER. Simplify it -- ' ..
      'nested quantifiers like (a+)+ are the usual cause.')
  elseif res.note then
    ImGui.TextColored(ctx, rgba(COL_DIM), res.note)
  elseif res.ok then
    ImGui.TextColored(ctx, rgba(COL_OK), 'Match')
    if res.span then
      local s = t.subject
      local a, b = res.span[1], res.span[2]
      ImGui.Text(ctx, 'matched: ')
      ImGui.SameLine(ctx, 0, 0)
      if a > 1 then
        ImGui.TextColored(ctx, rgba(COL_DIM), s:sub(1, a - 1)); ImGui.SameLine(ctx, 0, 0)
      end
      ImGui.TextColored(ctx, rgba(COL_OK), s:sub(a, b))
      if b < #s then
        ImGui.SameLine(ctx, 0, 0); ImGui.TextColored(ctx, rgba(COL_DIM), s:sub(b + 1))
      end
    end
    if res.caps and #res.caps > 0 then
      ImGui.Spacing(ctx)
      ImGui.TextColored(ctx, rgba(COL_DIM), 'groups:')
      for i, c in ipairs(res.caps) do
        ImGui.Text(ctx, string.format('  %d: %s', i,
          c == false and '(did not participate)' or ('"' .. c .. '"')))
      end
    end
  else
    ImGui.TextColored(ctx, rgba(COL_DIM), 'No match')
  end

  ImGui.EndChild(ctx)
end

return M
