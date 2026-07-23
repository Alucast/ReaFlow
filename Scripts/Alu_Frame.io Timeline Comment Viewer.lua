--[[
@description Frame.io Timeline Comment Viewer
@version 2.2.1
@author Assistant
@about
  Reads Frame.io exported .txt comment files and displays a visual timeline
  with markers synced to a locked video item in REAPER's arrange view.
  Requires the ReaImGui extension (v0.9+).
--]]

-- =====================================================================
-- 1. REAIMGUI LOADER
-- =====================================================================
local imgui = (function()
  local path = reaper.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua'
  if reaper.file_exists(path) then
    local chunk, err = loadfile(path)
    if chunk then
      local result = chunk('0.9')
      if type(result) == 'table' and result.CreateContext then
        return result
      elseif type(result) == 'function' then
        local result2 = result('0.9')
        if type(result2) == 'table' and result2.CreateContext then
          return result2
        end
      end
    end
  end
  local ok, res = pcall(require, 'imgui')
  if ok then
    if type(res) == 'function' then
      local result = res('0.9')
      if type(result) == 'table' and result.CreateContext then return result end
    elseif type(res) == 'table' and res.CreateContext then
      return res
    end
  end
  return nil
end)()

if not imgui then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension (v0.9+).\n\n" ..
    "Install it via ReaPack:\nExtensions > ReaPack > Browse packages > search 'ReaImGui'",
    "Missing Dependency", 0)
  return
end

local ctx = imgui.CreateContext('FrameioTimelineViewer')
if not ctx then
  reaper.ShowMessageBox("Failed to create ImGui context.", "Error", 0)
  return
end

-- Enable both native REAPER Docker docking and ImGui-to-ImGui docking.
local config_flags = imgui.GetConfigVar(ctx, imgui.ConfigVar_Flags)
imgui.SetConfigVar(
  ctx, imgui.ConfigVar_Flags,
  config_flags | imgui.ConfigFlags_DockingEnable
)

-- =====================================================================
-- 2. COLOR SYSTEM
-- =====================================================================
-- All colors are stored internally as ImGui U32 colors in AARRGGBB format.
local COLOR_PRESETS = {
  {key="bg",         label="Timeline BG",     default=0xFF30FFAB},
  {key="border",     label="Border",          default=0xFF6BBDBD},
  {key="text",       label="Text",            default=0xFFFF8E8E},
  {key="tick",       label="Tick Marks",      default=0xFFCCFFFF},
  {key="marker",     label="Markers",         default=0xFFFFFFC9},
  {key="marker_hov", label="Marker Hover",    default=0xFFFFBAFF},
  {key="playhead",   label="Playhead",        default=0xFF4485FF},
  {key="active",     label="Active Text",     default=0xFFFFFFE8},
  {key="warn",       label="Warnings",        default=0xFFFF4444},
  {key="completed",  label="Completed",       default=0xFFFF0000},
}

local COLORS = {}
local show_color_editor = false
local show_color_picker_popup = false

-- Picker state
local picker_sel_key = nil
local picker_h, picker_s, picker_v, picker_a = 0, 0, 1, 1
local picker_hex_str = ""
local picker_original_color = nil

local PICKER_HUE_W = 24
local SWATCH_SIZE = 42
local SWATCH_GAP = 5
local SWATCH_MIN_CELL_W = 66

-- Color editor window position for picker anchoring
local color_editor_rect = {x = 0, y = 0, w = 0, h = 0, applied = false}

-- Preset system state
local MAX_PRESETS = 5
local preset_sel_idx = 0
local preset_input_name = ""
local show_preset_save_popup = false

local SETTINGS_SECTION = "FrameioTimelineSettings"

local function saveSetting(key, value)
  reaper.SetExtState(SETTINGS_SECTION, key, tostring(value), true)
end

local function loadNumberSetting(key, fallback)
  local value = tonumber(reaper.GetExtState(SETTINGS_SECTION, key))
  return value or fallback
end

local function loadBoolSetting(key, fallback)
  local value = reaper.GetExtState(SETTINGS_SECTION, key)
  if value == "1" then return true end
  if value == "0" then return false end
  return fallback
end

local function saveWindowRect(prefix, x, y, w, h)
  saveSetting(prefix .. "_x", math.floor(x + 0.5))
  saveSetting(prefix .. "_y", math.floor(y + 0.5))
  saveSetting(prefix .. "_w", math.floor(w + 0.5))
  saveSetting(prefix .. "_h", math.floor(h + 0.5))
end

-- ---------------------------------------------------------------------
-- Color conversion / normalization helpers
-- ---------------------------------------------------------------------

local function normalizeColor(u32)
  if type(u32) ~= "number" then return nil end

  -- Keep the complete ImGui U32 color, including alpha.
  return u32 & 0xFFFFFFFF
end

local function U32ToHSV(u32)
  u32 = normalizeColor(u32) or 0xFFFFFFFF

  local r, g, b, a = imgui.ColorConvertU32ToDouble4(u32)
  local h, s, v = imgui.ColorConvertRGBtoHSV(r, g, b)

  return h, s, v, a
end

-- Exact HSV conversion path used by the working Metronome Volume Slider.
-- HSV -> RGB is performed directly by ReaImGui, then RGB -> packed U32.
local function getHSVColor(h, s, v, a)
  a = a or 1.0
  local r, g, b = reaper.ImGui_ColorConvertHSVtoRGB(h, s, v)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
end

local function HSVtoU32(h, s, v, a)
  return getHSVColor(h, s, v, a)
end

local function U32ToHex(u32)
  u32 = normalizeColor(u32) or 0xFFFFFFFF
  return string.format("%06X", u32 & 0x00FFFFFF)
end

local function HexToU32(hex)
  if type(hex) ~= "string" then return nil end

  hex = hex:gsub("#", ""):gsub("[^%x]", ""):upper()

  -- The text field is intentionally RGB-only. Opacity is edited separately.
  if #hex ~= 6 then return nil end

  local rgb = tonumber(hex, 16)
  if not rgb then return nil end

  -- Six-digit input changes RGB while preserving the current alpha.
  local alpha = picker_a or 1.0
  return reaper.ImGui_ColorConvertDouble4ToU32(
    ((rgb >> 16) & 0xFF) / 255,
    ((rgb >> 8) & 0xFF) / 255,
    (rgb & 0xFF) / 255,
    alpha
  )
end

-- Update the currently edited color from the current HSV state.
-- IMPORTANT: unlike the previous implementation, this does not convert the
-- generated U32 back to HSV on every mouse movement. That preserves the
-- exact H/S/V values being dragged and matches the working picker behavior.
local function updatePickerColor()
  if not picker_sel_key then return end

  local color = HSVtoU32(picker_h, picker_s, picker_v, picker_a)
  if color then
    COLORS[picker_sel_key] = color
  end
end

local function refreshPickerFromCurrentColor()
  if not picker_sel_key then return end

  local color = normalizeColor(COLORS[picker_sel_key])
  if color then
    COLORS[picker_sel_key] = color
    picker_h, picker_s, picker_v, picker_a = U32ToHSV(color)
    picker_hex_str = U32ToHex(color)
  end
end

-- ---------------------------------------------------------------------
-- Persistent color storage
-- ---------------------------------------------------------------------

local function loadColors()
  for _, c in ipairs(COLOR_PRESETS) do
    local val = reaper.GetExtState("FrameioTimeline", "color_" .. c.key)
    local num = tonumber(val)
    COLORS[c.key] = normalizeColor(num) or normalizeColor(c.default)
  end
end

local function saveColors()
  for _, c in ipairs(COLOR_PRESETS) do
    local color = normalizeColor(COLORS[c.key]) or normalizeColor(c.default)
    COLORS[c.key] = color
    reaper.SetExtState("FrameioTimeline", "color_" .. c.key, tostring(color), true)
  end
end

local function resetColors()
  for _, c in ipairs(COLOR_PRESETS) do
    COLORS[c.key] = normalizeColor(c.default)
  end

  -- If the picker is open, immediately reflect the reset color in it.
  refreshPickerFromCurrentColor()
  saveColors()
end

-- ---------------------------------------------------------------------
-- Color presets
-- ---------------------------------------------------------------------

local function saveColorPreset(idx, name)
  local parts = {}

  for _, c in ipairs(COLOR_PRESETS) do
    local color = normalizeColor(COLORS[c.key]) or normalizeColor(c.default)
    table.insert(parts, c.key .. "=" .. tostring(color))
  end

  name = tostring(name or ""):gsub("[\r\n]", " ")
  reaper.SetExtState("FrameioTimeline", "preset_" .. idx .. "_name", name, true)
  reaper.SetExtState("FrameioTimeline", "preset_" .. idx .. "_data", table.concat(parts, ";"), true)
end

local function loadColorPreset(idx)
  local name = reaper.GetExtState("FrameioTimeline", "preset_" .. idx .. "_name")
  local data = reaper.GetExtState("FrameioTimeline", "preset_" .. idx .. "_data")
  if name == "" or data == "" then return false end

  for part in data:gmatch("[^;]+") do
    local k, v = part:match("^(%w+)=(%-?%d+)$")
    if k and v then
      local num = normalizeColor(tonumber(v))
      if num then COLORS[k] = num end
    end
  end

  -- Keep the currently open picker synchronized if a preset is loaded.
  refreshPickerFromCurrentColor()
  saveColors()
  return true
end

local function deleteColorPreset(idx)
  reaper.DeleteExtState("FrameioTimeline", "preset_" .. idx .. "_name", true)
  reaper.DeleteExtState("FrameioTimeline", "preset_" .. idx .. "_data", true)
end

local function getPresetName(idx)
  local name = reaper.GetExtState("FrameioTimeline", "preset_" .. idx .. "_name")
  return (name ~= "" and name) or nil
end

-- ---------------------------------------------------------------------
-- Picker lifecycle
-- ---------------------------------------------------------------------

local function openColorPicker(key)
  local color = normalizeColor(COLORS[key])
  if not color then return end

  picker_sel_key = key
  picker_original_color = color

  picker_h, picker_s, picker_v, picker_a = U32ToHSV(color)
  picker_hex_str = U32ToHex(color)

  show_color_picker_popup = true
end

local function cancelColorPicker()
  if picker_sel_key and picker_original_color then
    COLORS[picker_sel_key] = picker_original_color
  end

  show_color_picker_popup = false
  picker_sel_key = nil
  picker_original_color = nil
end

local function acceptColorPicker()
  if picker_sel_key then
    COLORS[picker_sel_key] = normalizeColor(COLORS[picker_sel_key])
    saveColors()
  end

  show_color_picker_popup = false
  picker_sel_key = nil
  picker_original_color = nil
end

-- ---------------------------------------------------------------------
-- Picker drawing helpers
-- ---------------------------------------------------------------------

-- Exact hue conversion used by the working Metronome script.
local function drawHueGradient(dl, x, y, w, h)
  for i = 0, h - 1 do
    imgui.DrawList_AddRectFilled(
      dl,
      x,
      y + i,
      x + w,
      y + i + 1,
      getHSVColor(i / (h - 1), 1, 1)
    )
  end
end

local function drawSVSquare(dl, x, y, size, hue)
  -- HSV saturation/value can be rendered as two composited gradients:
  -- white -> current hue, then transparent -> black. This preserves the
  -- Metronome's ReaImGui HSV conversion while replacing 40,000 tiny rects
  -- with two draw calls.
  local white = getHSVColor(hue, 0, 1, 1)
  local hue_color = getHSVColor(hue, 1, 1, 1)
  local clear_black = reaper.ImGui_ColorConvertDouble4ToU32(0, 0, 0, 0)
  local black = reaper.ImGui_ColorConvertDouble4ToU32(0, 0, 0, 1)

  imgui.DrawList_AddRectFilledMultiColor(
    dl, x, y, x + size, y + size,
    white, hue_color, hue_color, white
  )
  imgui.DrawList_AddRectFilledMultiColor(
    dl, x, y, x + size, y + size,
    clear_black, clear_black, black, black
  )
end

local function drawCheckerboard(dl, x, y, w, h, cell)
  local light = reaper.ImGui_ColorConvertDouble4ToU32(0.72, 0.72, 0.72, 1)
  local dark = reaper.ImGui_ColorConvertDouble4ToU32(0.42, 0.42, 0.42, 1)
  local row = 0
  local yy = y
  while yy < y + h do
    local col = 0
    local xx = x
    while xx < x + w do
      local color = ((row + col) % 2 == 0) and light or dark
      imgui.DrawList_AddRectFilled(
        dl, xx, yy, math.min(xx + cell, x + w), math.min(yy + cell, y + h), color
      )
      xx = xx + cell
      col = col + 1
    end
    yy = yy + cell
    row = row + 1
  end
end

-- =====================================================================
-- COLOR EDITOR WINDOW - GRID OF LABELED SWATCHES
-- =====================================================================
local function draw_color_editor_window()
  if not show_color_editor then return end

  if not color_editor_rect.applied and color_editor_rect.w > 0 then
    imgui.SetNextWindowPos(ctx, color_editor_rect.x, color_editor_rect.y, imgui.Cond_Always)
    imgui.SetNextWindowSize(ctx, color_editor_rect.w, color_editor_rect.h, imgui.Cond_Always)
    color_editor_rect.applied = true
  else
    imgui.SetNextWindowSize(ctx, 340, 520, imgui.Cond_FirstUseEver)
  end
  local vis, open = imgui.Begin(ctx, "Color Editor", true)

  if vis then
    color_editor_rect.x, color_editor_rect.y = imgui.GetWindowPos(ctx)
    color_editor_rect.w, color_editor_rect.h = imgui.GetWindowWidth(ctx), imgui.GetWindowHeight(ctx)
    if imgui.IsMouseReleased(ctx, 0) then
      saveWindowRect(
        "color_editor", color_editor_rect.x, color_editor_rect.y,
        color_editor_rect.w, color_editor_rect.h
      )
    end

    if imgui.IsWindowFocused(ctx, imgui.FocusedFlags_RootAndChildWindows)
      and imgui.IsKeyPressed(ctx, imgui.Key_Escape) then
      show_color_editor = false
    end

    local dl = imgui.GetWindowDrawList(ctx)
    local avail_w = imgui.GetContentRegionAvail(ctx)

    -- Use a responsive number of columns instead of forcing four columns into
    -- whatever width the window happens to have. This prevents labels and
    -- swatches from collapsing into each other when the window is resized.
    local cols = math.floor((avail_w + SWATCH_GAP) /
      (SWATCH_MIN_CELL_W + SWATCH_GAP))
    cols = math.max(1, math.min(4, cols))

    -- A real table gives every swatch a fixed column and every row a fixed
    -- height. Unlike SameLine(), label length can no longer push later cells
    -- sideways or make the next row start at an inconsistent position.
    local table_flags = imgui.TableFlags_SizingFixedSame +
      imgui.TableFlags_NoHostExtendX
    imgui.PushStyleVar(ctx, imgui.StyleVar_CellPadding, SWATCH_GAP * 0.5, 0)
    if imgui.BeginTable(ctx, "##color_swatch_grid", cols, table_flags) then
      local label_h = imgui.GetFontSize(ctx) * 2 + 4
      local row_h = SWATCH_SIZE + 3 + label_h + SWATCH_GAP

      for col = 1, cols do
        imgui.TableSetupColumn(
          ctx, "##swatch_col_" .. col,
          imgui.TableColumnFlags_WidthFixed, SWATCH_MIN_CELL_W
        )
      end

      for idx, preset in ipairs(COLOR_PRESETS) do
        local col_idx = (idx - 1) % cols
        if col_idx == 0 then
          imgui.TableNextRow(ctx, 0, row_h)
        end
        imgui.TableSetColumnIndex(ctx, col_idx)

        local col = normalizeColor(COLORS[preset.key]) or normalizeColor(preset.default)

        imgui.PushStyleColor(ctx, imgui.Col_Button, col)
        imgui.PushStyleColor(ctx, imgui.Col_ButtonHovered, col)
        imgui.PushStyleColor(ctx, imgui.Col_ButtonActive, col)

        if imgui.Button(ctx, "##sw_" .. preset.key, SWATCH_SIZE, SWATCH_SIZE) then
          openColorPicker(preset.key)
        end

        imgui.PopStyleColor(ctx, 3)

        if picker_sel_key == preset.key then
          local minx, miny = imgui.GetItemRectMin(ctx)
          local maxx, maxy = imgui.GetItemRectMax(ctx)
          imgui.DrawList_AddRect(
            dl, minx - 1, miny - 1, maxx + 1, maxy + 1,
            0xFFFFFFFF, 0, nil, 2
          )
        end

        -- Keep the name directly beneath its square. The fixed two-line label
        -- area preserves row alignment even when a name wraps.
        imgui.Dummy(ctx, 0, 3)
        local cell_w = imgui.GetContentRegionAvail(ctx)
        imgui.PushTextWrapPos(ctx, imgui.GetCursorPosX(ctx) + cell_w)
        imgui.TextWrapped(ctx, preset.label)
        imgui.PopTextWrapPos(ctx)
      end

      imgui.EndTable(ctx)
    end
    imgui.PopStyleVar(ctx)

    imgui.Dummy(ctx, 0, 12)

    if imgui.Button(ctx, "Reset All to Defaults") then
      resetColors()
    end

    imgui.Separator(ctx)
    imgui.Text(ctx, "Presets")

    local preset_names = {}
    local preset_has_data = {}

    for i = 1, MAX_PRESETS do
      local name = getPresetName(i)
      preset_has_data[i] = name ~= nil
      table.insert(preset_names, (name and (i .. ": " .. name)) or (i .. ": (empty)"))
    end

    local chg, new_idx = imgui.Combo(ctx, "##preset", preset_sel_idx, table.concat(preset_names, "\0") .. "\0")
    if chg then preset_sel_idx = new_idx end

    if imgui.Button(ctx, "Load", 60, 0) then
      local idx = preset_sel_idx + 1
      if idx >= 1 and idx <= MAX_PRESETS and preset_has_data[idx] then
        loadColorPreset(idx)
      end
    end

    imgui.SameLine(ctx)
    if imgui.Button(ctx, "Save", 60, 0) then
      show_preset_save_popup = true
      preset_input_name = getPresetName(preset_sel_idx + 1) or ("Preset " .. (preset_sel_idx + 1))
    end

    imgui.SameLine(ctx)
    if imgui.Button(ctx, "Delete", 60, 0) then
      local idx = preset_sel_idx + 1
      if idx >= 1 and idx <= MAX_PRESETS then
        deleteColorPreset(idx)
      end
    end

    imgui.End(ctx)
  end

  if not open then
    show_color_editor = false
  end
end

-- =====================================================================
-- COLOR PICKER POPUP WINDOW
-- =====================================================================
local function draw_color_picker_popup()
  if not show_color_picker_popup or not picker_sel_key then return end

  imgui.SetNextWindowPos(ctx, color_editor_rect.x + color_editor_rect.w + 8, color_editor_rect.y, imgui.Cond_Appearing)
  imgui.SetNextWindowSize(ctx, 330, 350, imgui.Cond_FirstUseEver)
  imgui.SetNextWindowSizeConstraints(ctx, 270, 315, 520, 650)

  local popup_flags = imgui.WindowFlags_NoCollapse

  local preset_label = ""
  for _, p in ipairs(COLOR_PRESETS) do
    if p.key == picker_sel_key then
      preset_label = p.label
      break
    end
  end

  local vis, open = imgui.Begin(
    ctx, "Edit: " .. preset_label .. "###FrameioColorPicker", true, popup_flags
  )

  if vis then
    if imgui.IsWindowFocused(ctx, imgui.FocusedFlags_RootAndChildWindows) then
      if imgui.IsKeyPressed(ctx, imgui.Key_Enter) or imgui.IsKeyPressed(ctx, imgui.Key_KeypadEnter) then
        acceptColorPicker()
        imgui.End(ctx)
        return
      end

      if imgui.IsKeyPressed(ctx, imgui.Key_Escape) then
        cancelColorPicker()
        imgui.End(ctx)
        return
      end
    end

    local dl = imgui.GetWindowDrawList(ctx)
    local avail_w, avail_h = imgui.GetContentRegionAvail(ctx)
    local picker_sv_size = math.floor(math.min(
      avail_w - PICKER_HUE_W - 12,
      avail_h - 105
    ))
    picker_sv_size = math.max(120, math.min(360, picker_sv_size))
    local scr_x, scr_y = imgui.GetCursorScreenPos(ctx)
    local sv_x, sv_y = scr_x, scr_y
    local hue_x = scr_x + picker_sv_size + 12

    drawSVSquare(dl, sv_x, sv_y, picker_sv_size, picker_h)
    drawHueGradient(dl, hue_x, sv_y, PICKER_HUE_W, picker_sv_size)

    -- SV interaction.
    -- Keep H/S/V as the source of truth while dragging, exactly like the
    -- working Metronome Volume Slider picker.
    imgui.SetCursorScreenPos(ctx, sv_x, sv_y)
    imgui.InvisibleButton(ctx, "##sv_picker", picker_sv_size, picker_sv_size)

    if imgui.IsItemActive(ctx) then
      local mx, my = imgui.GetMousePos(ctx)

      picker_s = math.max(
        0,
        math.min(1, (mx - sv_x) / picker_sv_size)
      )

      picker_v = 1 - math.max(
        0,
        math.min(1, (my - sv_y) / picker_sv_size)
      )

      updatePickerColor()
    end

    -- Hue interaction.
    imgui.SetCursorScreenPos(ctx, hue_x, sv_y)
    imgui.InvisibleButton(ctx, "##hue_picker", PICKER_HUE_W, picker_sv_size)

    if imgui.IsItemActive(ctx) then
      local _, my = imgui.GetMousePos(ctx)

      picker_h = math.max(
        0,
        math.min(1, (my - sv_y) / picker_sv_size)
      )

      updatePickerColor()
    end

    -- Cursor indicators.
    imgui.DrawList_AddCircle(
      dl,
      sv_x + picker_s * picker_sv_size,
      sv_y + (1 - picker_v) * picker_sv_size,
      5,
      0xFFFFFFFF,
      8,
      2
    )

    imgui.DrawList_AddLine(
      dl,
      hue_x - 2,
      sv_y + picker_h * picker_sv_size,
      hue_x + PICKER_HUE_W + 2,
      sv_y + picker_h * picker_sv_size,
      0xFFFFFFFF,
      2
    )

    imgui.Dummy(ctx, 0, 8)

    -- Current color preview over a checkerboard + RGB-only hex input.
    imgui.BeginGroup(ctx)

    local preview_col = normalizeColor(COLORS[picker_sel_key]) or 0xFFFFFFFF
    local preview_x, preview_y = imgui.GetCursorScreenPos(ctx)
    drawCheckerboard(dl, preview_x, preview_y, 28, 28, 5)
    imgui.DrawList_AddRectFilled(dl, preview_x, preview_y, preview_x + 28, preview_y + 28, preview_col, 2)
    imgui.DrawList_AddRect(dl, preview_x, preview_y, preview_x + 28, preview_y + 28, 0xFFFFFFFF, 2)
    imgui.InvisibleButton(ctx, "##preview", 28, 28)
    imgui.SameLine(ctx)
    imgui.Text(ctx, "#")
    imgui.SameLine(ctx)
    imgui.PushItemWidth(ctx, 100)

    local chg, new_hex = imgui.InputText(
      ctx,
      "##hex",
      picker_hex_str,
      imgui.InputTextFlags_CharsHexadecimal + imgui.InputTextFlags_CharsUppercase
    )
    imgui.PopItemWidth(ctx)

    if chg then
      picker_hex_str = new_hex:gsub("[^%x]", ""):upper():sub(1, 6)

      if #picker_hex_str == 6 then
        local u32 = HexToU32(picker_hex_str)
        if u32 then
          COLORS[picker_sel_key] = u32
          picker_h, picker_s, picker_v, picker_a = U32ToHSV(u32)
        end
      end
    end

    imgui.EndGroup(ctx)
    imgui.Dummy(ctx, 0, 6)

    -- Alpha / opacity control. Keep HSV and alpha independent: changing
    -- opacity should never alter the RGB selection in the picker.
    imgui.Text(ctx, "Opacity")
    imgui.SameLine(ctx)
    local opacity_w = imgui.GetContentRegionAvail(ctx)
    imgui.PushItemWidth(ctx, math.max(120, opacity_w))
    local alpha_changed, opacity_pct = imgui.SliderDouble(
      ctx, "##alpha", picker_a * 100, 0, 100, "%.0f%%"
    )
    imgui.PopItemWidth(ctx)
    if alpha_changed then
      picker_a = math.max(0, math.min(1, opacity_pct / 100))
      updatePickerColor()
    end

    imgui.Dummy(ctx, 0, 4)

    if imgui.Button(ctx, "OK", 80, 0) then
      acceptColorPicker()
      imgui.End(ctx)
      return
    end

    imgui.SameLine(ctx)

    if imgui.Button(ctx, "Cancel", 80, 0) then
      cancelColorPicker()
      imgui.End(ctx)
      return
    end

    imgui.End(ctx)
  end

  if not open then
    -- Closing with the window X is equivalent to Cancel.
    cancelColorPicker()
  end
end

-- =====================================================================
-- 3. CONFIG & STATE
-- =====================================================================
local CFG = {
  fps               = 24,
  timeline_h        = 54,
  hover_dist        = 6,
  px_per_label      = 80,
}

local STATE = {
  comments          = {},
  current_file      = "",
  tc_offset         = 0,
  use_manual_offset = false,
  manual_offset_str = "00:00:00:00",
  locked_item       = nil,
  last_width        = 720,
  zoom              = 1.0,
  view_start        = 0,
  drag_start_mx     = nil,
  drag_start_view   = nil,
  drag_mode         = nil,
  pending_click     = false,
  has_opened        = false,
  scroll_to_comment = nil,
  last_item_ptr     = nil,
  show_comment_window = false,
  comment_win_first_open = true,
  main_open         = true,
  completed_set     = {},
  follow_current_comment = false,
  active_comment    = nil,
  active_comment_id = nil,
  comment_search    = "",
  comment_filter    = 0,
  comment_win_rect  = {x = 0, y = 0, w = 0, h = 0, applied = false},
  current_dock_id   = 0,
  pending_dock_id   = nil,
}

local function loadWorkflowSettings()
  STATE.follow_current_comment = loadBoolSetting("follow_current_comment", false)
  STATE.use_manual_offset = loadBoolSetting("use_manual_offset", false)
  STATE.manual_offset_str = reaper.GetExtState(SETTINGS_SECTION, "manual_offset_str")
  if STATE.manual_offset_str == "" then STATE.manual_offset_str = "00:00:00:00" end
  STATE.zoom = math.max(1, loadNumberSetting("timeline_zoom", 1))
  STATE.show_comment_window = loadBoolSetting("show_comment_window", false)

  local cr = STATE.comment_win_rect
  cr.x = loadNumberSetting("comment_window_x", 0)
  cr.y = loadNumberSetting("comment_window_y", 0)
  cr.w = loadNumberSetting("comment_window_w", 0)
  cr.h = loadNumberSetting("comment_window_h", 0)

  color_editor_rect.x = loadNumberSetting("color_editor_x", 0)
  color_editor_rect.y = loadNumberSetting("color_editor_y", 0)
  color_editor_rect.w = loadNumberSetting("color_editor_w", 0)
  color_editor_rect.h = loadNumberSetting("color_editor_h", 0)

  local saved_dock_id = loadNumberSetting("main_dock_id", 0)
  STATE.current_dock_id = saved_dock_id
  if saved_dock_id ~= 0 then
    STATE.pending_dock_id = saved_dock_id
  end
end

local DOCK_POSITIONS = {
  {label = "Top", value = 2},
  {label = "Bottom", value = 0},
}

local function findNativeDockForPosition(position)
  if not reaper.DockGetPosition then return nil end
  for docker_index = 0, 15 do
    if reaper.DockGetPosition(docker_index) == position then
      return -docker_index - 1
    end
  end
  return nil
end

local function requestMainDock(dock_id)
  STATE.pending_dock_id = dock_id
  STATE.current_dock_id = dock_id
  saveSetting("main_dock_id", dock_id)
end

-- Completed comment tracking
local function saveCompletedComments()
  if #STATE.current_file == 0 then return end
  local parts = {}
  for key, _ in pairs(STATE.completed_set) do
    table.insert(parts, key)
  end
  local file_key = STATE.current_file:match("([^\\/]+)$") or "default"
  reaper.SetExtState("FrameioTimeline", "completed_" .. file_key, table.concat(parts, ";"), true)
end

local function loadCompletedComments()
  STATE.completed_set = {}
  if #STATE.current_file == 0 then return end
  local file_key = STATE.current_file:match("([^\\/]+)$") or "default"
  local data = reaper.GetExtState("FrameioTimeline", "completed_" .. file_key)
  if data == "" then return end
  for key in data:gmatch("[^;]+") do
    if #key > 0 then STATE.completed_set[key] = true end
  end
end

local function isCommentCompleted(c)
  if STATE.completed_set[c.id] then return true end
  -- Read legacy completion entries created by versions before stable IDs.
  return STATE.completed_set[c.tc .. "||" .. c.text] == true
end

local function toggleCommentCompleted(c)
  local legacy_key = c.tc .. "||" .. c.text
  local key = c.id
  if STATE.completed_set[key] then
    STATE.completed_set[key] = nil
  elseif STATE.completed_set[legacy_key] then
    STATE.completed_set[legacy_key] = nil
  else
    STATE.completed_set[key] = true
  end
  saveCompletedComments()
end

local function getCompletionProgress()
  local completed = 0
  for _, c in ipairs(STATE.comments) do
    if isCommentCompleted(c) then completed = completed + 1 end
  end
  return completed, #STATE.comments
end

-- =====================================================================
-- 4. HELPERS
-- =====================================================================
local function tc_to_sec(str)
  if not str then return nil end
  local h, m, s, f = str:match("^(%d+):(%d+):(%d+)[:;](%d+)$")
  if h then
    return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) + tonumber(f)/CFG.fps
  end
  return nil
end

local function sec_to_tc(sec)
  sec = math.max(0, sec)
  local h = math.floor(sec/3600)
  local m = math.floor((sec%3600)/60)
  local s = math.floor(sec%60)
  local f = math.floor((sec%1)*CFG.fps + 0.5)
  return string.format("%02d:%02d:%02d:%02d", h, m, s, f)
end

local function encodeCommentIdPart(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function makeCommentId(tc, text, occurrence)
  -- The occurrence suffix distinguishes genuinely duplicated rows while the
  -- encoded content keeps the identity stable if unrelated comments move.
  return encodeCommentIdPart(tc) .. "|" ..
    encodeCommentIdPart(text) .. "|" .. tostring(occurrence)
end

local function get_item_info_from_ptr(ptr)
  if not ptr or not reaper.ValidatePtr(ptr, "MediaItem*") then return nil end
  local tk = reaper.GetActiveTake(ptr)
  local pos = reaper.GetMediaItemInfo_Value(ptr, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(ptr, "D_LENGTH")
  return {
    ptr  = ptr,
    pos  = pos,
    len  = len,
    end_ = pos + len,
    name = (tk and reaper.GetTakeName(tk)) or "Unknown Item",
  }
end

-- =====================================================================
-- 5. PARSER
-- =====================================================================
local function parse_file(path)
  local f, err = io.open(path, "r")
  if not f then return false, err end
  local txt = f:read("*all")
  f:close()

  STATE.comments = {}
  local min_t = math.huge
  local lines_checked = 0
  local duplicate_counts = {}

  for line in txt:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 then
      lines_checked = lines_checked + 1
      local tc1, cmt

      tc1, cmt = line:match("^%[(%d+:%d+:%d+[:;]%d+)%s*[-–—]%s*%d+:%d+:%d+[:;]%d+%]%s*[-–—]%s*(.+)$")
      if not tc1 then
        tc1, cmt = line:match("^(%d+:%d+:%d+[:;]%d+)%s*[-–—]%s*(.+)$")
      end

      if tc1 and cmt and #cmt > 0 then
        local t = tc_to_sec(tc1)
        if t then
          if t < min_t then min_t = t end
          local duplicate_key = tc1 .. "\0" .. cmt
          local occurrence = (duplicate_counts[duplicate_key] or 0) + 1
          duplicate_counts[duplicate_key] = occurrence
          table.insert(STATE.comments, {
            id = makeCommentId(tc1, cmt, occurrence),
            tc = tc1,
            t = t,
            text = cmt,
          })
        end
      end
    end
  end

  if #STATE.comments == 0 then
    return false, "No timecodes found. Lines checked: " .. lines_checked ..
           "\nMake sure this is a Frame.io comment export .txt file."
  end

  table.sort(STATE.comments, function(a,b)
    if a.t == b.t then return a.id < b.id end
    return a.t < b.t
  end)
  STATE.tc_offset = min_t
  if not STATE.use_manual_offset or STATE.manual_offset_str == "" then
    STATE.manual_offset_str = sec_to_tc(min_t)
  end
  STATE.active_comment = nil
  STATE.active_comment_id = nil
  -- Set the file before loading completion state so the correct ExtState key
  -- is used on first load (the old order could read the previously open file).
  STATE.current_file = path
  loadCompletedComments()
  return true
end

-- =====================================================================
-- 6. ADAPTIVE GRID
-- =====================================================================
local NICE_STEPS = {1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800}

local function get_nice_step(range, max_labels)
  if range <= 0 or max_labels < 2 then return 1 end
  local rough = range / (max_labels - 1)
  for _, s in ipairs(NICE_STEPS) do
    if s >= rough then return s end
  end
  return NICE_STEPS[#NICE_STEPS]
end

-- =====================================================================
-- 7. NAVIGATION
-- =====================================================================
local function get_current_time()
  if reaper.GetPlayState() > 0 then
    return reaper.GetPlayPosition()
  else
    return reaper.GetCursorPosition()
  end
end

local function find_current_comment(info)
  if not info or #STATE.comments == 0 then return nil end

  local current = get_current_time()
  if current < info.pos or current > info.end_ then return nil end

  local offset = STATE.use_manual_offset and
    tc_to_sec(STATE.manual_offset_str) or STATE.tc_offset
  if not offset then offset = 0 end

  local source_time = offset + (current - info.pos)
  local active = nil
  for _, c in ipairs(STATE.comments) do
    if c.t <= source_time + 0.0001 then
      active = c
    else
      break
    end
  end
  return active
end

local function updateActiveComment(info)
  local active = find_current_comment(info)
  local active_id = active and active.id or nil

  if active_id ~= STATE.active_comment_id then
    STATE.active_comment = active
    STATE.active_comment_id = active_id
    if STATE.follow_current_comment and active then
      STATE.scroll_to_comment = active
    end
  else
    STATE.active_comment = active
  end
end

local function scroll_timeline_to_time(rel_time, info)
  if not info then return end
  local zoom = math.max(1.0, STATE.zoom or 1.0)
  local visible_len = info.len / zoom
  -- Center the target time in the timeline view
  STATE.view_start = math.max(0, math.min(info.len - visible_len, rel_time - visible_len * 0.5))
end

local function go_to_prev_comment(info)
  if #STATE.comments == 0 then return end
  local offset = STATE.use_manual_offset and tc_to_sec(STATE.manual_offset_str) or STATE.tc_offset
  if not offset then offset = 0 end
  local cur = get_current_time()
  local best = nil
  for _, c in ipairs(STATE.comments) do
    local abs = info.pos + (c.t - offset)
    if abs < cur - 0.001 then best = c end
  end
  if best then
    local target_abs = info.pos + (best.t - offset)
    reaper.SetEditCurPos(target_abs, true, true)
    STATE.scroll_to_comment = best
    scroll_timeline_to_time(target_abs - info.pos, info)
  end
end

local function go_to_next_comment(info)
  if #STATE.comments == 0 then return end
  local offset = STATE.use_manual_offset and tc_to_sec(STATE.manual_offset_str) or STATE.tc_offset
  if not offset then offset = 0 end
  local cur = get_current_time()
  for _, c in ipairs(STATE.comments) do
    local abs = info.pos + (c.t - offset)
    if abs > cur + 0.001 then
      reaper.SetEditCurPos(abs, true, true)
      STATE.scroll_to_comment = c
      -- Auto-scroll timeline to keep target centered
      scroll_timeline_to_time(abs - info.pos, info)
      return
    end
  end
end

-- =====================================================================
-- 8. TOOLTIP WRAPPER
-- =====================================================================
local function set_tooltip_wrapped(text)
  if not text or #text == 0 then return end
  if imgui.BeginTooltip(ctx) then
    imgui.PushTextWrapPos(ctx, imgui.GetFontSize(ctx) * 35)
    imgui.Text(ctx, text)
    imgui.PopTextWrapPos(ctx)
    imgui.EndTooltip(ctx)
  end
end

-- =====================================================================
-- 9. KEYBOARD HANDLER
-- =====================================================================
local function handle_keyboard(info)
  if not info then return end
  
  -- ESC closes comment window first, then main window
  if imgui.IsKeyPressed(ctx, imgui.Key_Escape) then
    if STATE.show_comment_window then
      STATE.show_comment_window = false
      saveSetting("show_comment_window", 0)
    else
      STATE.main_open = false
    end
    return
  end
  
  -- Arrow keys for navigation (Left/Up = prev, Right/Down = next)
  if imgui.IsKeyPressed(ctx, imgui.Key_LeftArrow) or imgui.IsKeyPressed(ctx, imgui.Key_UpArrow) then
    go_to_prev_comment(info)
  elseif imgui.IsKeyPressed(ctx, imgui.Key_RightArrow) or imgui.IsKeyPressed(ctx, imgui.Key_DownArrow) then
    go_to_next_comment(info)
  end
end

-- =====================================================================
-- 10. TIMELINE DRAWING
-- =====================================================================
local function draw_timeline(info)
  local dl = imgui.GetWindowDrawList(ctx)
  local cx, cy = imgui.GetCursorScreenPos(ctx)
  local aw, _  = imgui.GetContentRegionAvail(ctx)
  local w, h   = aw, CFG.timeline_h
  local x2, y2 = cx + w, cy + h

  imgui.DrawList_AddRectFilled(dl, cx, cy, x2, y2, COLORS.bg, 4)
  imgui.DrawList_AddRect(dl, cx, cy, x2, y2, COLORS.border, 4, 0, 1)

  local offset = STATE.use_manual_offset and tc_to_sec(STATE.manual_offset_str) or STATE.tc_offset
  if not offset then offset = 0 end

  local mx, my = imgui.GetMousePos(ctx)
  local hovered_comment = nil

  -- Zoom / View
  local zoom = math.max(1.0, STATE.zoom or 1.0)
  local max_zoom = info.len / math.min(info.len, 0.5)
  if zoom > max_zoom then zoom = max_zoom end
  STATE.zoom = zoom

  local visible_len = info.len / zoom
  local view_start = STATE.view_start or 0
  if view_start < 0 then view_start = 0 end
  if view_start + visible_len > info.len then view_start = info.len - visible_len end
  STATE.view_start = view_start
  local view_end = view_start + visible_len

  local function time_to_x(t)
    return cx + ((t - view_start) / visible_len) * w
  end

  -- Ticks
  local max_labels = math.max(2, math.floor(w / CFG.px_per_label))
  local step = get_nice_step(visible_len, max_labels)
  local start_tick = math.floor(view_start / step) * step
  local t = start_tick
  while t <= view_end + 0.001 do
    if t >= view_start - 0.001 and t <= view_end + 0.001 then
      local x = time_to_x(t)
      local major = (math.abs(t % (step * 2)) < 0.001) or step < 2
      local th = major and 10 or 5
      imgui.DrawList_AddLine(dl, x, y2 - th, x, y2, COLORS.tick, 1)
      if major then
        local lbl = sec_to_tc(t)
        local tw = imgui.CalcTextSize(ctx, lbl)
        local lx = x - tw * 0.5
        if lx > cx + 2 and lx + tw < x2 - 2 then
          imgui.DrawList_AddText(dl, lx, y2 + 4, COLORS.text, lbl)
        end
      end
    end
    t = t + step
  end

  -- Edge labels
  if view_start < 0.5 then
    imgui.DrawList_AddText(dl, cx + 2, y2 + 4, COLORS.text, sec_to_tc(0))
  end
  if view_end > info.len - 0.5 then
    local tw = imgui.CalcTextSize(ctx, sec_to_tc(info.len))
    imgui.DrawList_AddText(dl, x2 - tw - 2, y2 + 4, COLORS.text, sec_to_tc(info.len))
  end

  -- Markers
  for _, c in ipairs(STATE.comments) do
    local rel = c.t - offset
    if rel >= view_start - 0.001 and rel <= view_end + 0.001 then
      local x = time_to_x(rel)
      local is_hov = math.abs(mx - x) < CFG.hover_dist and my >= cy and my <= y2
      local is_current = c.id == STATE.active_comment_id
      local is_completed = isCommentCompleted(c)
      local col
      if is_completed then
        col = COLORS.completed
      elseif is_current then
        col = COLORS.active
      else
        col = is_hov and COLORS.marker_hov or COLORS.marker
      end
      local emphasized = is_hov or is_current
      local thick = emphasized and 2 or 1
      local y_top = emphasized and cy - 2 or cy + 2
      local y_bot = emphasized and y2 + 2 or y2 - 2
      imgui.DrawList_AddLine(dl, x, y_top, x, y_bot, col, thick)
      if is_hov then
        hovered_comment = c
        set_tooltip_wrapped((is_completed and "[COMPLETED] " or "") .. c.tc .. " | " .. c.text)
        if imgui.IsMouseClicked(ctx, 0) then
          if imgui.IsKeyDown(ctx, imgui.Key_LeftAlt) then
            toggleCommentCompleted(c)
          else
            reaper.SetEditCurPos(info.pos + rel, true, true)
            STATE.scroll_to_comment = c
          end
        end
      end
    end
  end

  -- Playhead: triangle pointing down from above, no circle
  local cur_time = get_current_time()
  local rel_time = cur_time - info.pos
  if rel_time >= view_start and rel_time <= view_end then
    local x = time_to_x(rel_time)
    imgui.DrawList_AddLine(dl, x, cy + 2, x, y2, COLORS.playhead, 2)
    local tip_y = cy + 2
    local base_y = cy - 9
    imgui.DrawList_AddTriangle(dl, x, tip_y + 1, x - 7, base_y, x + 7, base_y, 0xFF000000, 1)
    imgui.DrawList_AddTriangleFilled(dl, x, tip_y, x - 6, base_y, x + 6, base_y, COLORS.playhead)
  elseif not STATE.drag_mode then
    -- Auto-scroll to keep playhead centered during playback
    scroll_timeline_to_time(rel_time, info)
  end

  -- Interaction
  imgui.SetCursorScreenPos(ctx, cx, cy)
  imgui.InvisibleButton(ctx, "##tl", w, h)

  local is_hovered = imgui.IsItemHovered(ctx)
  local is_active = imgui.IsItemActive(ctx)

  -- Zoom with mouse wheel
  if is_hovered then
    local scroll = imgui.GetMouseWheel(ctx)
    if scroll ~= 0 then
      local mouse_rel = (mx - cx) / w
      local mouse_time = view_start + mouse_rel * visible_len
      local new_zoom = math.max(1.0, zoom * (1 + scroll * 0.15))
      if new_zoom > max_zoom then new_zoom = max_zoom end
      local new_visible_len = info.len / new_zoom
      local new_view_start = mouse_time - mouse_rel * new_visible_len
      STATE.zoom = new_zoom
      saveSetting("timeline_zoom", new_zoom)
      STATE.view_start = math.max(0, math.min(info.len - new_visible_len, new_view_start))
    end
  end

  -- Click vs Pan
  if imgui.IsItemClicked(ctx, 0) then
    STATE.pending_click = true
    STATE.drag_start_mx = mx
    STATE.drag_start_view = view_start
    STATE.drag_mode = nil
  end

  if is_active and STATE.pending_click then
    local dx = mx - STATE.drag_start_mx
    if math.abs(dx) > 4 then
      STATE.drag_mode = "pan"
      STATE.pending_click = false
    end
  end

  if STATE.drag_mode == "pan" and is_active then
    local seconds_per_pixel = visible_len / w
    STATE.view_start = math.max(0, math.min(info.len - visible_len,
      STATE.drag_start_view - (mx - STATE.drag_start_mx) * seconds_per_pixel))
  end

  if not is_active and STATE.pending_click then
    if not hovered_comment then
      local click_ratio = math.max(0, math.min(1, (mx - cx) / w))
      local seek_time = view_start + click_ratio * visible_len
      reaper.SetEditCurPos(info.pos + seek_time, true, true)
    end
    STATE.pending_click = false
    STATE.drag_mode = nil
    STATE.drag_start_mx = nil
  end

  if not is_active then
    STATE.pending_click = false
    STATE.drag_mode = nil
    STATE.drag_start_mx = nil
  end

  imgui.SetCursorScreenPos(ctx, cx, y2 + 20)
end

-- =====================================================================
-- FILE LOADING HELPER
-- =====================================================================
local function load_frameio_file_dialog()
  local ret, path = reaper.GetUserFileNameForRead("", "Select Frame.io Export", ".txt")
  if ret and #path > 0 then
    local ok, err = parse_file(path)
    if ok then
      STATE.current_file = path
      return true
    else
      reaper.ShowMessageBox(err or "Parse error", "Error", 0)
    end
  end
  return false
end

-- =====================================================================
-- 11. COMMENT LIST WINDOW
-- =====================================================================
local function draw_comment_list_window()
  if not STATE.show_comment_window then return end
  if #STATE.comments == 0 then return end

  if STATE.comment_win_first_open then
    local rect = STATE.comment_win_rect
    if not rect.applied and rect.w > 0 then
      imgui.SetNextWindowPos(ctx, rect.x, rect.y, imgui.Cond_Always)
      imgui.SetNextWindowSize(ctx, rect.w, rect.h, imgui.Cond_Always)
      rect.applied = true
    else
      imgui.SetNextWindowSize(ctx, 480, 520, imgui.Cond_FirstUseEver)
    end
    STATE.comment_win_first_open = false
  end

  local completed_count, total_count = getCompletionProgress()
  local flags = imgui.WindowFlags_None
  local title = string.format(
    "Comment List (%d/%d completed)###FrameioCommentList",
    completed_count, total_count
  )
  local visible, open = imgui.Begin(ctx, title, true, flags)

  if visible then
    local rect = STATE.comment_win_rect
    rect.x, rect.y = imgui.GetWindowPos(ctx)
    rect.w, rect.h = imgui.GetWindowWidth(ctx), imgui.GetWindowHeight(ctx)
    if imgui.IsMouseReleased(ctx, 0) then
      saveWindowRect("comment_window", rect.x, rect.y, rect.w, rect.h)
    end

    if imgui.IsWindowFocused(ctx, imgui.FocusedFlags_RootAndChildWindows) then
      if imgui.IsKeyPressed(ctx, imgui.Key_Escape) then
        STATE.show_comment_window = false
        saveSetting("show_comment_window", 0)
      end
    end
    local info = STATE.item_info
    if not info then
      imgui.TextColored(ctx, COLORS.warn, "No item locked or selected.")
    else
      local offset = STATE.use_manual_offset and tc_to_sec(STATE.manual_offset_str) or STATE.tc_offset
      if not offset then offset = 0 end

      -- Navigation buttons at top
      if imgui.Button(ctx, "< Prev Comment") then
        go_to_prev_comment(info)
      end
      imgui.SameLine(ctx)
      if imgui.Button(ctx, "Next Comment >") then
        go_to_next_comment(info)
      end
      imgui.SameLine(ctx)
      local follow_changed, follow_value = imgui.Checkbox(
        ctx, "Follow Current Comment", STATE.follow_current_comment
      )
      if follow_changed then
        STATE.follow_current_comment = follow_value
        saveSetting("follow_current_comment", follow_value and 1 or 0)
        if follow_value and STATE.active_comment then
          STATE.scroll_to_comment = STATE.active_comment
        end
      end
      if imgui.IsItemHovered(ctx) then
        set_tooltip_wrapped(
          "Highlight the comment at the playhead and automatically keep it visible in this list."
        )
      end
      imgui.SameLine(ctx)
      imgui.Text(ctx, "Cursor: " .. sec_to_tc(get_current_time()))

      imgui.Text(ctx, "Search")
      imgui.SameLine(ctx)
      local search_w = imgui.GetContentRegionAvail(ctx)
      imgui.PushItemWidth(ctx, math.max(100, search_w))
      local search_changed, search_value = imgui.InputText(
        ctx, "##comment_search", STATE.comment_search
      )
      imgui.PopItemWidth(ctx)
      if search_changed then STATE.comment_search = search_value end

      imgui.Text(ctx, "Show")
      imgui.SameLine(ctx)
      imgui.PushItemWidth(ctx, 130)
      local filter_changed, filter_value = imgui.Combo(
        ctx, "##comment_filter", STATE.comment_filter,
        "All\0Incomplete\0Completed\0Current\0Nearby (10s)\0"
      )
      imgui.PopItemWidth(ctx)
      if filter_changed then STATE.comment_filter = filter_value end

      imgui.SameLine(ctx)
      imgui.Text(ctx, string.format(
        "Completed: %d / %d (%d%%)",
        completed_count, total_count,
        total_count > 0 and math.floor(completed_count / total_count * 100 + 0.5) or 0
      ))
      imgui.Separator(ctx)

      local display_comments = {}
      local search = STATE.comment_search:lower()
      local current_pos = get_current_time()
      for _, c in ipairs(STATE.comments) do
        local rel = c.t - offset
        local abs = info.pos + rel
        local completed = isCommentCompleted(c)
        local current = c.id == STATE.active_comment_id
        local matches_search = search == "" or
          c.text:lower():find(search, 1, true) ~= nil or
          c.tc:lower():find(search, 1, true) ~= nil
        local matches_filter =
          STATE.comment_filter == 0 or
          (STATE.comment_filter == 1 and not completed) or
          (STATE.comment_filter == 2 and completed) or
          (STATE.comment_filter == 3 and current) or
          (STATE.comment_filter == 4 and math.abs(current_pos - abs) <= 10)

        if matches_search and matches_filter then
          table.insert(display_comments, {comment = c, abs = abs})
        end
      end

      -- Find the visible scroll target before drawing.
      local scroll_target_idx = nil
      if STATE.scroll_to_comment then
        for idx, entry in ipairs(display_comments) do
          if entry.comment == STATE.scroll_to_comment then
            scroll_target_idx = idx
            break
          end
        end
      end

      local list_h = math.max(120, imgui.GetContentRegionAvail(ctx) - 4)
      if imgui.BeginChild(ctx, "##clist", 0, list_h, 0) then
        if #display_comments == 0 then
          imgui.TextDisabled(ctx, "No comments match the current search and filter.")
        end

        for idx, entry in ipairs(display_comments) do
          local c = entry.comment
          local abs = entry.abs
          local is_active = c.id == STATE.active_comment_id
          local is_completed = isCommentCompleted(c)

          imgui.PushID(ctx, c.id)
          if is_completed then
            imgui.PushStyleColor(ctx, imgui.Col_Text, COLORS.completed)
          elseif is_active then
            imgui.PushStyleColor(ctx, imgui.Col_Text, COLORS.active)
          end

          local completion_changed = false
          completion_changed = select(1, imgui.Checkbox(ctx, "##completed", is_completed))
          if completion_changed then
            toggleCommentCompleted(c)
          end
          if imgui.IsItemHovered(ctx) then
            set_tooltip_wrapped("Mark this comment completed")
          end
          imgui.SameLine(ctx)

          local avail_w = imgui.GetContentRegionAvail(ctx)
          local wrap_x = imgui.GetCursorPosX(ctx) + avail_w - 10
          imgui.PushTextWrapPos(ctx, wrap_x)

          local label = string.format("%s  |  %s", c.tc, c.text)
          imgui.TextWrapped(ctx, label)

          -- Scroll after submitting the target item so ImGui can align that
          -- exact row rather than the row that preceded it.
          if scroll_target_idx and idx == scroll_target_idx then
            imgui.SetScrollHereY(ctx, 0.35)
            scroll_target_idx = nil
            STATE.scroll_to_comment = nil
          end

          imgui.PopTextWrapPos(ctx)

          if imgui.IsItemClicked(ctx, 0) then
            if imgui.IsKeyDown(ctx, imgui.Key_LeftAlt) then
              toggleCommentCompleted(c)
            else
              reaper.SetEditCurPos(abs, true, true)
            end
          end

          if is_completed or is_active then imgui.PopStyleColor(ctx) end
          imgui.PopID(ctx)

          imgui.Dummy(ctx, 0, 2)
        end
        imgui.EndChild(ctx)
      end
    end
    imgui.End(ctx)
  end

  if not open then
    STATE.show_comment_window = false
    saveSetting("show_comment_window", 0)
  end
end

-- =====================================================================
-- 12. MAIN LOOP
-- =====================================================================
local function loop()
  if not STATE.main_open then return end
  
  local info = nil
  if STATE.locked_item then
    info = get_item_info_from_ptr(STATE.locked_item)
    if not info then STATE.locked_item = nil end
  end
  if not info then
    local it = reaper.GetSelectedMediaItem(0, 0)
    if it then info = get_item_info_from_ptr(it) end
  end
  STATE.item_info = info
  updateActiveComment(info)

  if not STATE.has_opened then
    imgui.SetNextWindowSize(ctx, 720, 240, imgui.Cond_FirstUseEver)
    STATE.has_opened = true
  end

  if STATE.pending_dock_id ~= nil then
    imgui.SetNextWindowDockID(ctx, STATE.pending_dock_id)
    STATE.pending_dock_id = nil
  end

  local flags = imgui.WindowFlags_MenuBar
  local visible, open = imgui.Begin(ctx, "Frame.io Timeline Viewer", true, flags)
  local actual_dock_id = imgui.GetWindowDockID(ctx)
  if actual_dock_id ~= STATE.current_dock_id then
    STATE.current_dock_id = actual_dock_id
    -- Native REAPER Docker IDs and floating state are stable across sessions.
    if actual_dock_id <= 0 then
      saveSetting("main_dock_id", actual_dock_id)
    end
  end

  if visible then
    STATE.last_width = imgui.GetWindowWidth(ctx)
    
    -- Keyboard shortcuts (only when main window is focused, not typing in inputs)
    if imgui.IsWindowFocused(ctx, imgui.FocusedFlags_RootAndChildWindows) then
      handle_keyboard(info)
    end

    -- Menu
    if imgui.BeginMenuBar(ctx) then
      if imgui.BeginMenu(ctx, "File") then
        if imgui.MenuItem(ctx, "Load Frame.io TXT...") then
          load_frameio_file_dialog()
        end
        if imgui.MenuItem(ctx, "Reload") and #STATE.current_file > 0 then
          parse_file(STATE.current_file)
        end
        imgui.Separator(ctx)
        if imgui.MenuItem(ctx, "Exit") then open = false end
        imgui.EndMenu(ctx)
      end

      if imgui.BeginMenu(ctx, "View") then
        local label = STATE.show_comment_window and "Hide Comment List" or "Show Comment List"
        if imgui.MenuItem(ctx, label) then
          STATE.show_comment_window = not STATE.show_comment_window
          saveSetting("show_comment_window", STATE.show_comment_window and 1 or 0)
          if STATE.show_comment_window then
            STATE.comment_win_first_open = true
            if STATE.follow_current_comment and STATE.active_comment then
              STATE.scroll_to_comment = STATE.active_comment
            end
          end
        end
        imgui.EndMenu(ctx)
      end

      if imgui.BeginMenu(ctx, "Dock") then
        if imgui.MenuItem(
          ctx, "Undock / Floating", nil, STATE.current_dock_id == 0
        ) then
          requestMainDock(0)
        end

        imgui.Separator(ctx)
        for _, side in ipairs(DOCK_POSITIONS) do
          local dock_id = findNativeDockForPosition(side.value)
          local selected = dock_id and STATE.current_dock_id == dock_id or false
          local label = "Dock " .. side.label
          if not dock_id then label = label .. " (no Docker configured)" end
          if imgui.MenuItem(ctx, label, nil, selected, dock_id ~= nil) then
            requestMainDock(dock_id)
          end
        end

        imgui.EndMenu(ctx)
      end

      if imgui.BeginMenu(ctx, "Colors") then
        if imgui.MenuItem(ctx, "Edit Colors...") then
          show_color_editor = true
        end
        imgui.EndMenu(ctx)
      end
      imgui.EndMenuBar(ctx)
    end

    -- Status
    if #STATE.current_file == 0 then
      imgui.TextColored(ctx, COLORS.warn, "No file loaded. Use File > Load Frame.io TXT...")
    else
      imgui.Text(ctx, "File: " .. STATE.current_file:match("([^\\/]+)$"))
      imgui.SameLine(ctx)
      imgui.Text(ctx, "| Comments: " .. #STATE.comments)
      local completed_count, total_count = getCompletionProgress()
      imgui.SameLine(ctx)
      imgui.Text(ctx, string.format("| Completed: %d/%d", completed_count, total_count))
    end
    imgui.Separator(ctx)

    -- Item lock toggle
    if STATE.locked_item and STATE.item_info then
      if imgui.Button(ctx, "Unlock Item") then
        STATE.locked_item = nil
        STATE.last_item_ptr = nil
      end
      imgui.SameLine(ctx)
      imgui.Text(ctx, STATE.item_info.name .. "  |  Length: " .. sec_to_tc(STATE.item_info.len))
      if imgui.IsItemHovered(ctx) then
        set_tooltip_wrapped("Start: " .. sec_to_tc(STATE.item_info.pos) .. "\nEnd: " .. sec_to_tc(STATE.item_info.end_))
      end
      -- Manual offset controls are only visible while an item is locked.
      imgui.SameLine(ctx)
      local chg, val = imgui.Checkbox(ctx, "Manual TC Offset", STATE.use_manual_offset)
      if chg then
        STATE.use_manual_offset = val
        saveSetting("use_manual_offset", val and 1 or 0)
      end
      if imgui.IsItemHovered(ctx) then
        set_tooltip_wrapped(
          "Override the automatically detected Frame.io timecode offset.\n" ..
          "Detected offset: " .. sec_to_tc(STATE.tc_offset)
        )
      end
      if STATE.use_manual_offset then
        imgui.SameLine(ctx)
        imgui.PushItemWidth(ctx, 110)
        local chg2, newtxt = imgui.InputText(ctx, "##off", STATE.manual_offset_str,
          imgui.InputTextFlags_CharsNoBlank + imgui.InputTextFlags_EnterReturnsTrue)
        imgui.PopItemWidth(ctx)
        if chg2 then
          STATE.manual_offset_str = newtxt
          saveSetting("manual_offset_str", newtxt)
        end
        if imgui.IsItemHovered(ctx) then
          set_tooltip_wrapped(
            "Enter the Frame.io timecode that should line up with the locked item's start."
          )
        end
      end
    else
      if imgui.Button(ctx, "Lock Selected Item") then
        local it = reaper.GetSelectedMediaItem(0, 0)
        if it then
          STATE.locked_item = it
          STATE.last_item_ptr = it
        else
          reaper.ShowMessageBox("No item selected in Arrange view.", "Error", 0)
        end
      end
    end

    if not STATE.item_info then
      imgui.TextColored(ctx, COLORS.warn, "Select a video item and click 'Lock Selected Item'.")
    else
      local i = STATE.item_info

      imgui.Dummy(ctx, 0, 4)
      draw_timeline(i)
      imgui.Dummy(ctx, 0, 2)

      -- Compact navigation arrows
      if imgui.Button(ctx, "<") then
        go_to_prev_comment(i)
      end
      imgui.SameLine(ctx)
      if imgui.Button(ctx, ">") then
        go_to_next_comment(i)
      end
      imgui.SameLine(ctx)
      if imgui.Button(ctx, "Comment List") then
        if #STATE.comments == 0 then
          load_frameio_file_dialog()
          if #STATE.comments > 0 then
            STATE.show_comment_window = true
            saveSetting("show_comment_window", 1)
            STATE.comment_win_first_open = true
            if STATE.follow_current_comment and STATE.active_comment then
              STATE.scroll_to_comment = STATE.active_comment
            end
          end
        else
          STATE.show_comment_window = not STATE.show_comment_window
          saveSetting("show_comment_window", STATE.show_comment_window and 1 or 0)
          if STATE.show_comment_window then
            STATE.comment_win_first_open = true
            if STATE.follow_current_comment and STATE.active_comment then
              STATE.scroll_to_comment = STATE.active_comment
            end
          end
        end
      end
      imgui.SameLine(ctx)
      local follow_changed, follow_value = imgui.Checkbox(
        ctx, "Follow", STATE.follow_current_comment
      )
      if follow_changed then
        STATE.follow_current_comment = follow_value
        saveSetting("follow_current_comment", follow_value and 1 or 0)
        if follow_value and STATE.active_comment then
          STATE.scroll_to_comment = STATE.active_comment
        end
      end
      if imgui.IsItemHovered(ctx) then
        set_tooltip_wrapped(
          "Follow Current Comment: keep the playhead's active comment highlighted and visible in the comment list."
        )
      end
      imgui.SameLine(ctx)
      imgui.Text(ctx, "Cursor: " .. sec_to_tc(get_current_time()))
    end

    imgui.End(ctx)
  end

  if not open then
    STATE.main_open = false
  end

  -- =====================================================================
  -- COMMENT LIST POPUP WINDOW
  -- =====================================================================
  draw_comment_list_window()

  -- =====================================================================
  -- COLOR EDITOR WINDOW
  -- =====================================================================
  draw_color_editor_window()

  -- =====================================================================
  -- PRESET SAVE POPUP
  -- =====================================================================
  if show_preset_save_popup then
    imgui.SetNextWindowSize(ctx, 280, 100, imgui.Cond_Always)
    local vis2, open2 = imgui.Begin(ctx, "Save Preset", true, imgui.WindowFlags_NoCollapse + imgui.WindowFlags_NoResize)
    if vis2 then
      if imgui.IsWindowFocused(ctx, imgui.FocusedFlags_RootAndChildWindows) then
        if imgui.IsKeyPressed(ctx, imgui.Key_Enter) or imgui.IsKeyPressed(ctx, imgui.Key_KeypadEnter) then
          local idx = preset_sel_idx + 1
          if idx >= 1 and idx <= MAX_PRESETS then
            saveColorPreset(idx, preset_input_name)
          end
          show_preset_save_popup = false
        end
        if imgui.IsKeyPressed(ctx, imgui.Key_Escape) then
          show_preset_save_popup = false
        end
      end
      imgui.Text(ctx, "Preset name:")
      local chg, new_name = imgui.InputText(ctx, "##presetname", preset_input_name, imgui.InputTextFlags_EnterReturnsTrue)
      if chg then preset_input_name = new_name end
      if imgui.Button(ctx, "Save", 60, 0) then
        local idx = preset_sel_idx + 1
        if idx >= 1 and idx <= MAX_PRESETS then
          saveColorPreset(idx, preset_input_name)
        end
        show_preset_save_popup = false
      end
      imgui.SameLine(ctx)
      if imgui.Button(ctx, "Cancel", 60, 0) then
        show_preset_save_popup = false
      end
      imgui.End(ctx)
    end
    if not open2 then
      show_preset_save_popup = false
    end
  end

  -- =====================================================================
  -- COLOR PICKER POPUP WINDOW
  -- =====================================================================
  draw_color_picker_popup()

  if STATE.main_open then
    reaper.defer(loop)
  end
end

-- =====================================================================
-- 13. INIT
-- =====================================================================
loadColors()
loadWorkflowSettings()
loop()

