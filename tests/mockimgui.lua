--[[ A no-op ImGui that lets the real drawing code run headlessly.

     It cannot tell us the window LOOKS right, but it does prove every drawing
     path executes without error, that no call is misspelled or missing, and --
     the reason it exists -- that an edit actually reaches app.mark_dirty(). ]]

local M = {}

-- Anything matching one of these prefixes is a constant, and must be a number:
-- the real code ORs them together.
local FLAG_PREFIX = {
  'TableFlags_', 'TableColumnFlags_', 'TableRowFlags_', 'ColorEditFlags_',
  'SelectableFlags_', 'DragDropFlags_', 'ChildFlags_', 'WindowFlags_',
  'InputTextFlags_', 'HoveredFlags_', 'PopupFlags_', 'ComboFlags_',
  'ConfigFlags_', 'FontFlags_', 'Cond_', 'Col_', 'Key_', 'Mod_', 'MouseButton_',
  'StyleVar_', 'DrawFlags_', 'TabBarFlags_', 'TabItemFlags_', 'TableBgTarget_',
}

local function is_flag(name)
  for _, p in ipairs(FLAG_PREFIX) do
    if name:sub(1, #p) == p then return true end
  end
  return false
end

function M.new(opts)
  opts = opts or {}
  local calls, seen, labels = {}, {}, {}
  local flagbits, nflags = {}, 0
  local scripted = opts.scripted or {}      -- name -> function(...) returning values

  -- Default return shapes. Anything not listed returns false.
  local defaults = {
    CreateContext = function() return { 'ctx' } end,
    CreateFont    = function() return { 'font' } end,
    Begin         = function() return true, true end,
    BeginTable    = function() return true end,
    BeginTabBar   = function() return true end,
    -- Every tab is "open" so one frame exercises all four rule tables. Pass
    -- opts.only_tab to restrict it to one.
    BeginTabItem  = function(_, label)
      if opts.only_tab then
        return label:find(opts.only_tab, 1, true) ~= nil
      end
      return true
    end,
    BeginChild    = function() return true end,
    BeginCombo    = function() return false end,   -- dropdowns stay closed
    BeginPopup    = function() return false end,   -- popups stay closed
    BeginPopupModal = function() return false end,
    BeginDragDropSource = function() return false end,
    BeginDragDropTarget = function() return false end,
    BeginTooltip  = function() return false end,
    GetFontSize   = function() return 14 end,
    GetFrameHeight = function() return 20 end,
    GetCursorPosX = function() return 0 end,
    GetCursorPosY = function() return 0 end,
    TableGetColumnName = function(_, c) return 'col' .. tostring(c) end,
    TableSetColumnIndex = function() return true end,
    GetCursorPos  = function() return 0, 0 end,
    GetStyleColor = function() return 0x808080FF end,
    GetWindowDrawList = function() return { 'drawlist' } end,
    IsPopupOpen = function() return false end,
    GetItemRectMin = function() return 10, 20 end,
    GetItemRectMax = function() return 30, 40 end,
    GetItemRectSize = function() return 20, 20 end,
    GetStyleVar   = function() return 4, 4 end,
    CalcTextSize  = function(_, text) return #tostring(text) * 7, 14 end,
    GetContentRegionAvail = function() return 900, 640 end,
    GetWindowPos  = function() return 100, 80 end,
    GetWindowSize = function() return 900, 640 end,
    GetWindowDpiScale = function() return 2.0 end,
    -- widgets that echo their value back unchanged
    Checkbox     = function(_, _, v) return false, v end,
    InputText    = function(_, _, v) return false, v end,
    ColorEdit3   = function(_, _, v) return false, v end,
    SliderDouble = function(_, _, v) return false, v end,
    SliderInt    = function(_, _, v) return false, v end,
    Selectable   = function() return false end,
    AcceptDragDropPayload = function() return false, '' end,
  }

  local t = {}
  setmetatable(t, {
    __index = function(_, name)
      if is_flag(name) then
        seen[name] = true
        -- Distinct bits, so code that ORs flags together produces genuinely
        -- different values and a test can tell one combination from another.
        local v = flagbits[name]
        if not v then
          v = 1 << (nflags % 31)
          nflags = nflags + 1
          flagbits[name] = v
        end
        return v
      end
      return function(...)
        calls[#calls + 1] = name
        seen[name] = true
        for i = 1, select('#', ...) do
          local a = select(i, ...)
          if type(a) == 'string' then labels[a] = true end
        end
        local s = scripted[name]
        if s then return s(...) end
        local d = defaults[name]
        if d then return d(...) end
        return false
      end
    end,
  })

  return t, { calls = calls, seen = seen, labels = labels }
end

return M
