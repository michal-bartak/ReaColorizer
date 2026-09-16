--[[
  gui/rule_table.lua -- the ordered rule list for ONE object kind.

  Precedence is position: the first rule that matches wins, so the table is
  reorderable by dragging the handle or from the row menu (the buttons are the
  reliable path; dragging is the pleasant one).

  Each kind gets its own table, so the columns differ: only tracks have folder
  filters and the "also colour items" switch.

  Every mutation is deferred to after EndTable -- changing the list while
  iterating it is how you get flickering rows and mismatched widget ids.
]]

local rulesmod   = require 'rules'
local predicates = require 'predicates'
local matcher    = require 'matcher'
local app        = require 'gui.app'
local theme      = require 'gui.theme'

local M = {}

local ImGui, ctx
function M.init(imgui, context) ImGui, ctx = imgui, context end

local function rgba(rgb, a) return ((rgb & 0xFFFFFF) << 8) | (a or 0xFF) end

local COL_ERR  = 0xC2413B
local COL_DIM  = 0x9A9A9A
local COL_WARN = 0xD9A441

------------------------------------------------------------------ small bits
local function mode_combo(r)
  ImGui.SetNextItemWidth(ctx, -1)
  local changed = false
  if ImGui.BeginCombo(ctx, '##mode', rulesmod.MODE_LABEL[r.mode]) then
    for _, m in ipairs(rulesmod.MODES) do
      if ImGui.Selectable(ctx, rulesmod.MODE_LABEL[m], m == r.mode) and m ~= r.mode then
        app.snapshot(); r.mode = m; changed = true
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx,
      'contains  -- plain text, nothing is interpreted\n' ..
      'glob      -- * ? [abc], matches the WHOLE name\n' ..
      'regex     -- full regular expression')
  end
  return changed
end

local function only_combo(r, kind)
  local avail = predicates.for_kind(kind)
  ImGui.SetNextItemWidth(ctx, -1)
  local changed = false
  local preview = r.only and predicates.LABEL[r.only] or '--'
  if ImGui.BeginCombo(ctx, '##only', preview) then
    if ImGui.Selectable(ctx, '-- no filter --', r.only == nil) and r.only ~= nil then
      app.snapshot(); r.only = nil; changed = true
    end
    for _, k in ipairs(avail) do
      if ImGui.Selectable(ctx, predicates.LABEL[k], r.only == k) and r.only ~= k then
        app.snapshot(); r.only = k; changed = true
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'An extra condition, on top of the pattern.\n' ..
                          'Leave the pattern empty to match on this alone.')
  end
  return changed
end

--- Width of the gradient-spread dropdown. Shared with the Colour column, which
--- is sized to hold exactly the swatches, the [x] button and this box.
local function gscope_width(FS) return FS * 5.2 + 12 end

--- What the gradient spreads across. Only shown once a second colour exists --
--- the setting means nothing without one.
local function gradient_scope_combo(r, kind, FS)
  local changed = false
  ImGui.SetNextItemWidth(ctx, gscope_width(FS))
  if ImGui.BeginCombo(ctx, '##gscope', rulesmod.GRADIENT_SHORT[r.gradient_scope]) then
    for _, g in ipairs(rulesmod.GRADIENT_SCOPES) do
      if rulesmod.gradient_scope_applies(g, kind) then
        if ImGui.Selectable(ctx, rulesmod.GRADIENT_LABEL[g], g == r.gradient_scope)
           and g ~= r.gradient_scope then
          app.snapshot(); r.gradient_scope = g; changed = true
        end
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, rulesmod.GRADIENT_HELP[g])
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Spread the gradient across: ' ..
                          rulesmod.GRADIENT_LABEL[r.gradient_scope] .. '\n\n' ..
                          rulesmod.GRADIENT_HELP[r.gradient_scope])
  end
  return changed
end

local function color_cell(r, kind, FS)
  local changed = false

  local rv, c = theme.color_swatch('##col1', r.color)
  if rv then app.snapshot(); r.color = c; changed = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Colour for this rule') end

  theme.same_line_tight()
  if r.color2 then
    local rv2, c2 = theme.color_swatch('##col2', r.color2)
    if rv2 then app.snapshot(); r.color2 = c2; changed = true end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Second colour: this rule\'s matches are spread\n' ..
                            'along a gradient between the two, in project order.\n' ..
                            'The box beside it says what it spreads across.')
    end
    theme.same_line_tight()
    if theme.icon_button('x##nograd') then
      app.snapshot(); r.color2 = nil; changed = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Remove the gradient') end

    theme.same_line_tight()
    if gradient_scope_combo(r, kind, FS) then changed = true end
  else
    if theme.icon_button('+##grad') then
      app.snapshot(); r.color2 = r.color; changed = true
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Add a second colour to spread this rule\'s\n' ..
                            'matches along a gradient')
    end
  end
  return changed
end

---------------------------------------------------------------------- draw
--- @param kind 'track'|'item'|'region'|'marker'
--- @return true if anything changed
function M.draw(kind, FS, height)
  local st    = app.st
  local rules = app.list(kind)
  local changed = false
  local pending = nil

  local is_track  = (kind == 'track')
  local has_only  = #predicates.for_kind(kind) > 0

  -- column layout varies by kind
  local cols, idx = {}, {}
  local function col(name) cols[#cols + 1] = name; idx[name] = #cols - 1 end
  col('drag'); col('on'); col('name'); col('mode'); col('pattern'); col('ci')
  if has_only then col('only') end
  col('color')
  if is_track then col('cascade') end
  col('hits'); col('menu')

  -- Resizable comes from the theme: it cannot be combined with "no vertical
  -- lines", because Dear ImGui re-enables BordersInnerV whenever it is set.
  local flags = theme.table_border_flags()
              | ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY
              | ImGui.TableFlags_SizingStretchProp

  if not ImGui.BeginTable(ctx, 'rules_' .. kind, #cols, flags, 0, height) then
    return false
  end

  local FIX, STRETCH = ImGui.TableColumnFlags_WidthFixed, ImGui.TableColumnFlags_WidthStretch

  -- Two columns hold nothing but square buttons, so size them from the buttons
  -- instead of from a guess in font sizes. A table cell insets its contents by
  -- CellPadding.x on each side, which the column width has to carry.
  local ICON = theme.icon_size()
  local cpx  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_CellPadding)
  local PAD  = 2 * cpx
  -- swatch, swatch, [x], dropdown -- and the three gaps between them
  local COLOUR_W = ICON * 3 + theme.SWATCH_GAP * 3 + gscope_width(FS) + PAD + 2
  local MENU_W   = ICON + PAD + 4
  ImGui.TableSetupColumn(ctx, '##drag', FIX, FS * 1.4)
  ImGui.TableSetupColumn(ctx, '##on',   FIX, FS * 1.8)
  ImGui.TableSetupColumn(ctx, 'Name',   STRETCH, 1.0)
  ImGui.TableSetupColumn(ctx, 'Match',  FIX, FS * 6 + 6)
  ImGui.TableSetupColumn(ctx, 'Pattern', STRETCH, 2.0)
  ImGui.TableSetupColumn(ctx, 'Aa',     FIX, FS * 2.2)
  if has_only then ImGui.TableSetupColumn(ctx, 'Filter', FIX, FS * 9 + 4) end
  ImGui.TableSetupColumn(ctx, 'Colour', FIX, COLOUR_W)
  if is_track then ImGui.TableSetupColumn(ctx, 'Items', FIX, FS * 3.2) end
  ImGui.TableSetupColumn(ctx, 'Hits',   FIX, FS * 4)
  ImGui.TableSetupColumn(ctx, '##menu', FIX, MENU_W)
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)

  -- Aa / Items / Hits are narrow columns whose contents are centred, so their
  -- labels should be too. TableHeadersRow always left-aligns, hence the manual
  -- header row.
  local centred_headers = { [idx.ci] = true, [idx.hits] = true }
  if is_track then centred_headers[idx.cascade] = true end
  theme.headers_row(#cols, centred_headers)

  for i, r in ipairs(rules) do
    ImGui.PushID(ctx, r.id)
    ImGui.TableNextRow(ctx)

    ------------------------------------------------ drag handle / reorder
    ImGui.TableSetColumnIndex(ctx, idx.drag)
    theme.reorder_handle(r.id, st.sel_id == r.id, '=')
    if ImGui.IsItemClicked(ctx) then st.sel_id = r.id end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Rule ' .. i .. ' of ' .. #rules ..
                            '\nDrag to reorder -- the first match wins.')
    end
    -- No SourceNoPreviewTooltip here: with that flag anything drawn inside the
    -- source block lands INLINE in the window (the stray label that appeared
    -- under the dragged row) instead of in a tooltip that follows the cursor.
    if ImGui.BeginDragDropSource(ctx) then
      ImGui.SetDragDropPayload(ctx, 'NC_RULE_' .. kind, tostring(i))
      ImGui.Text(ctx, 'move: ' ..
                 (r.label ~= '' and r.label or (r.pattern ~= '' and r.pattern or 'rule')))
      ImGui.EndDragDropSource(ctx)
    end
    if ImGui.BeginDragDropTarget(ctx) then
      local ok, payload = ImGui.AcceptDragDropPayload(ctx, 'NC_RULE_' .. kind)
      if ok then
        local from = tonumber(payload)
        if from then pending = { op = 'move', from = from, to = i } end
      end
      ImGui.EndDragDropTarget(ctx)
    end

    ------------------------------------------------------------ enabled
    ImGui.TableSetColumnIndex(ctx, idx.on)
    local rv, on = theme.checkbox('##on', r.enabled, true)
    if rv then app.snapshot(); r.enabled = on; changed = true end

    -------------------------------------------------------------- label
    ImGui.TableSetColumnIndex(ctx, idx.name)
    ImGui.SetNextItemWidth(ctx, -1)
    local rvl, label = ImGui.InputText(ctx, '##label', r.label)
    if rvl then app.snapshot(); r.label = label; changed = true end
    if ImGui.IsItemActivated(ctx) then st.sel_id = r.id end

    --------------------------------------------------------------- mode
    ImGui.TableSetColumnIndex(ctx, idx.mode)
    if mode_combo(r) then changed = true end

    ------------------------------------------------------------ pattern
    ImGui.TableSetColumnIndex(ctx, idx.pattern)
    local _, perr, ppos = nil, nil, nil
    if r.pattern ~= '' then
      _, perr, ppos = matcher.compile(r.mode, r.pattern, r.ci)
    end
    if perr then ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, rgba(0x5A2320)) end
    ImGui.SetNextItemWidth(ctx, -1)
    local rvp, pat = ImGui.InputText(ctx, '##pat', r.pattern)
    if perr then ImGui.PopStyleColor(ctx) end
    if rvp then app.snapshot(); r.pattern = pat; changed = true end
    if ImGui.IsItemActivated(ctx) then st.sel_id = r.id end
    if perr and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Invalid pattern: ' .. perr ..
                            (ppos and ('\nat character ' .. ppos) or '') ..
                            '\n\nThis rule is skipped until it is fixed.')
    end

    ---------------------------------------------------------------- case
    ImGui.TableSetColumnIndex(ctx, idx.ci)
    local rvc, ci = theme.checkbox('##ci', r.ci, true)
    if rvc then app.snapshot(); r.ci = ci; changed = true end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Ignore case (ASCII only)')
    end

    ---------------------------------------------------------------- only
    if has_only then
      ImGui.TableSetColumnIndex(ctx, idx.only)
      if only_combo(r, kind) then changed = true end
    end

    -------------------------------------------------------------- colour
    ImGui.TableSetColumnIndex(ctx, idx.color)
    if color_cell(r, kind, FS) then changed = true end

    ------------------------------------------------- cascade onto items
    if is_track then
      ImGui.TableSetColumnIndex(ctx, idx.cascade)
      local rvx, casc = theme.checkbox('##casc', r.cascade_items, true)
      if rvx then app.snapshot(); r.cascade_items = casc; changed = true end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx,
          'Also colour the ITEMS sitting on the tracks this rule matches,\n' ..
          'whatever those items are called.\n\n' ..
          'A rule on the Items tab still wins over this.')
      end
    end

    ---------------------------------------------------------------- hits
    ImGui.TableSetColumnIndex(ctx, idx.hits)
    local won = st.won[r.id] or 0
    local sh  = st.shadowed[r.id] or 0
    do -- centre the whole "12  +3" run, not each half separately
      local main = (r._timeouts and r._timeouts > 0) and ('!' .. won)
                   or (perr and 'err' or tostring(won))
      theme.center_text(sh > 0 and (main .. '  +' .. sh) or main)
    end
    if r._timeouts and r._timeouts > 0 then
      ImGui.TextColored(ctx, rgba(COL_WARN), '!' .. won)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'This pattern is too slow and timed out ' ..
                              r._timeouts .. ' time(s).\nSimplify it.')
      end
    elseif perr then
      ImGui.TextColored(ctx, rgba(COL_ERR), 'err')
    else
      ImGui.Text(ctx, tostring(won))
    end
    if sh > 0 then
      ImGui.SameLine(ctx, 0, 4)
      ImGui.TextColored(ctx, rgba(COL_DIM), '+' .. sh)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, sh .. ' more object(s) match this rule, but an\n' ..
                              'earlier rule claimed them first. Move this rule up\n' ..
                              'if it should win.')
      end
    end

    ---------------------------------------------------------------- menu
    ImGui.TableSetColumnIndex(ctx, idx.menu)
    if theme.icon_button('...', true) then ImGui.OpenPopup(ctx, 'rowmenu') end
    if ImGui.BeginPopup(ctx, 'rowmenu') then
      if ImGui.MenuItem(ctx, 'Move up',   nil, false, i > 1) then
        pending = { op = 'move', from = i, to = i - 1 }
      end
      if ImGui.MenuItem(ctx, 'Move down', nil, false, i < #rules) then
        pending = { op = 'move', from = i, to = i + 1 }
      end
      if ImGui.MenuItem(ctx, 'Move to top', nil, false, i > 1) then
        pending = { op = 'move', from = i, to = 1 }
      end
      if ImGui.MenuItem(ctx, 'Move to bottom', nil, false, i < #rules) then
        pending = { op = 'move', from = i, to = #rules }
      end
      ImGui.Separator(ctx)
      if ImGui.MenuItem(ctx, 'Duplicate') then pending = { op = 'dup', i = i } end
      if ImGui.MenuItem(ctx, 'Delete')    then pending = { op = 'del', i = i } end
      ImGui.EndPopup(ctx)
    end

    ImGui.PopID(ctx)
  end

  ImGui.EndTable(ctx)

  -- Mutate only now that the table is closed.
  if pending then
    if pending.op == 'move' then app.move_rule(kind, pending.from, pending.to)
    elseif pending.op == 'dup' then app.duplicate_rule(kind, pending.i)
    elseif pending.op == 'del' then app.remove_rule(kind, pending.i) end
    changed = true
  end

  -- Marking dirty happens HERE, not in the caller. Returning a flag and
  -- trusting whoever calls draw() to act on it is exactly how edits silently
  -- stopped being saved and stopped refreshing the preview.
  if changed then app.mark_dirty() end

  return changed
end

return M
