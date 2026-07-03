-- @description Metronome Volume Slider (Matched Icon Colors + Clamped Shadow)
-- @version 6.1
-- @author Alejandro (Alu) + adjusted defaults + position toggle

local ctx = reaper.ImGui_CreateContext('MetroFullColor')

-- Settings
local EXT_SECTION = 'MetroVolSlider'

-- Toggle this to true/false to show/hide the window border
local SHOW_BORDER = false

-- Tooltip delay in seconds
local TOOLTIP_DELAY = 1.0

-- Load States
local HUE = tonumber(reaper.GetExtState(EXT_SECTION, 'hue')) or 0.6
local SAT = tonumber(reaper.GetExtState(EXT_SECTION, 'sat')) or 0.75
local VAL = tonumber(reaper.GetExtState(EXT_SECTION, 'val')) or 0.85
local GUI_SCALE = tonumber(reaper.GetExtState(EXT_SECTION, 'scale')) or 1.5
local CONTRAST = tonumber(reaper.GetExtState(EXT_SECTION, 'contrast')) or 0.5

-- Position mode: 0 = follow mouse, 1 = remember last position
local POS_MODE = tonumber(reaper.GetExtState(EXT_SECTION, 'posmode')) or 0
local SAVED_POS_X = tonumber(reaper.GetExtState(EXT_SECTION, 'pos_x'))
local SAVED_POS_Y = tonumber(reaper.GetExtState(EXT_SECTION, 'pos_y'))

GUI_SCALE = math.max(0.8, math.min(2.5, GUI_SCALE))

local SLIDER_WIDTH, SLIDER_HEIGHT, PADDING
local WINDOW_WIDTH, WINDOW_HEIGHT
local HUE_SLIDER_WIDTH, SV_SIZE, PICKER_PADDING
local PICKER_WIDTH, PICKER_HEIGHT

local function updateGuiMetrics()
  SLIDER_WIDTH = math.floor(36 * GUI_SCALE)
  SLIDER_HEIGHT = math.floor(180 * GUI_SCALE)
  PADDING = math.floor(6 * GUI_SCALE)
  WINDOW_WIDTH = math.ceil(SLIDER_WIDTH + PADDING * 2)
  WINDOW_HEIGHT = math.ceil(SLIDER_HEIGHT + PADDING * 2)
  HUE_SLIDER_WIDTH = math.floor(20 * GUI_SCALE)
  SV_SIZE = math.floor(140 * GUI_SCALE)
  PICKER_PADDING = math.floor(6 * GUI_SCALE)
  PICKER_WIDTH = SV_SIZE + HUE_SLIDER_WIDTH + PICKER_PADDING * 3 + math.floor(18 * GUI_SCALE)
  PICKER_HEIGHT = SV_SIZE + PICKER_PADDING * 2
end

updateGuiMetrics()

local function getHSVColor(h, s, v, a)
  a = a or 1.0
  local r, g, b = reaper.ImGui_ColorConvertHSVtoRGB(h, s, v)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
end

local function updateColors()
  local hover_v = math.min(1, VAL + 0.12)
  local shadow_alpha = 0.6 * CONTRAST
  return getHSVColor(HUE, SAT, VAL), getHSVColor(HUE, SAT, hover_v), getHSVColor(0, 0, 0, shadow_alpha)
end

local BLUE_TINT, BLUE_TINT_HOVER, SHADOW_COLOR = updateColors()

local CMD_VOL_UP = reaper.NamedCommandLookup('_S&M_METRO_VOL_UP')
local CMD_VOL_DOWN = reaper.NamedCommandLookup('_S&M_METRO_VOL_DOWN')
local current_vol, last_applied_vol = 0.5, -1

local function applyVolume(target_vol)
  target_vol = math.max(0, math.min(1, target_vol))
  if math.abs(target_vol - last_applied_vol) < 0.001 then return end
  last_applied_vol = target_vol
  reaper.PreventUIRefresh(1)
  for i = 1, 285 do reaper.Main_OnCommand(CMD_VOL_DOWN, 0) end
  for i = 1, math.floor(100 + target_vol * 170) do reaper.Main_OnCommand(CMD_VOL_UP, 0) end
  reaper.PreventUIRefresh(-1)
end

local function drawHueGradient(dl, x, y, w, h)
  for i = 0, h - 1 do
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y + i, x + w, y + i + 1, getHSVColor(i / (h - 1), 1, 1))
  end
end

local function drawSVSquare(dl, x, y, size)
  for iy = 0, size - 1 do
    local v = 1 - (iy / size)
    for ix = 0, size - 1 do
      local s = ix / size
      reaper.ImGui_DrawList_AddRectFilled(dl, x + ix, y + iy, x + ix + 1, y + iy + 1, getHSVColor(HUE, s, v))
    end
  end
end

local mouse_x, mouse_y = reaper.GetMousePosition()
if reaper.GetOS():match('^OSX') or reaper.GetOS():match('^macOS') then
  local viewport = reaper.ImGui_GetMainViewport(ctx)
  local _, vp_y = reaper.ImGui_Viewport_GetPos(viewport)
  local _, vp_h = reaper.ImGui_Viewport_GetSize(viewport)
  mouse_y = (vp_y + vp_h) - mouse_y
end

local first_frame, show_picker, picker_first_frame = true, false, true
local drag_scale_start_y, drag_scale_start_value = nil, nil
local drag_contrast_start_y, drag_contrast_start_value = nil, nil
local main_wx, main_wy = 0, 0

-- Tooltip state
local scale_hover_start, contrast_hover_start, mode_hover_start = nil, nil, nil

local function checkTooltip(hover_start, text)
  if hover_start and (reaper.time_precise() - hover_start) >= TOOLTIP_DELAY then
    reaper.ImGui_SetTooltip(ctx, text)
  end
end

function main()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)

  local flags = reaper.ImGui_WindowFlags_NoTitleBar() |
                reaper.ImGui_WindowFlags_NoResize() |
                reaper.ImGui_WindowFlags_NoScrollbar()

  if first_frame then
    if POS_MODE == 1 and SAVED_POS_X and SAVED_POS_Y then
      reaper.ImGui_SetNextWindowPos(ctx, SAVED_POS_X, SAVED_POS_Y, reaper.ImGui_Cond_Always())
    else
      reaper.ImGui_SetNextWindowPos(ctx, mouse_x, mouse_y, reaper.ImGui_Cond_Always(), 0.5, 0.5)
    end
    first_frame = false
  end

  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
  local visible, open = reaper.ImGui_Begin(ctx, 'MainVol', true, flags)

  if visible then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    main_wx, main_wy = wx, wy
    local tx, ty = wx + PADDING, wy + PADDING

    -- Save window position if in remember mode and position changed
    if POS_MODE == 1 then
      if (not SAVED_POS_X or math.abs(wx - SAVED_POS_X) > 1 or math.abs(wy - SAVED_POS_Y) > 1) then
        SAVED_POS_X, SAVED_POS_Y = wx, wy
        reaper.SetExtState(EXT_SECTION, 'pos_x', tostring(SAVED_POS_X), true)
        reaper.SetExtState(EXT_SECTION, 'pos_y', tostring(SAVED_POS_Y), true)
      end
    end

    -- Background
    reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + WINDOW_WIDTH, wy + WINDOW_HEIGHT, 0xFF000000, 4)

    -- Optional border that matches the fader color
    if SHOW_BORDER then
      local border_alpha = 0x44000000
      local border_color = (BLUE_TINT & 0x00FFFFFF) | border_alpha
      reaper.ImGui_DrawList_AddRect(dl, wx, wy, wx + WINDOW_WIDTH, wy + WINDOW_HEIGHT, border_color, 4)
    end

    local handle_h = math.floor(12 * GUI_SCALE)
    local handle_y = ty + (SLIDER_HEIGHT - handle_h) - (current_vol * (SLIDER_HEIGHT - handle_h))
    local centerX = tx + (SLIDER_WIDTH / 2)
    local halfW = (SLIDER_WIDTH / 2)
    local fill_inset = math.max(1, math.floor(2 * GUI_SCALE))

    reaper.ImGui_DrawList_AddRectFilled(dl, centerX - halfW + fill_inset, handle_y, centerX + halfW - fill_inset, ty + SLIDER_HEIGHT, BLUE_TINT, 3)
    
    local shadow_length = math.floor(22 * GUI_SCALE * CONTRAST)
    if shadow_length > 0 then
      reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, 
        centerX - halfW, handle_y + handle_h, 
        centerX + halfW, handle_y + handle_h + shadow_length,
        SHADOW_COLOR, SHADOW_COLOR, 0x00000000, 0x00000000)
    end

    reaper.ImGui_DrawList_AddRectFilled(dl, centerX - halfW, handle_y, centerX + halfW, handle_y + handle_h, BLUE_TINT_HOVER, 3)
    reaper.ImGui_DrawList_AddRect(dl, centerX - halfW, handle_y, centerX + halfW, handle_y + handle_h, 0x33000000, 3)

    reaper.ImGui_SetCursorScreenPos(ctx, tx, ty)
    reaper.ImGui_InvisibleButton(ctx, '##vol_btn', SLIDER_WIDTH, SLIDER_HEIGHT)

    if reaper.ImGui_IsItemActive(ctx) then
      local _, my = reaper.ImGui_GetMousePos(ctx)
      current_vol = 1.0 - math.max(0, math.min(1, (my - (ty + handle_h / 2)) / (SLIDER_HEIGHT - handle_h)))
      applyVolume(current_vol)
    elseif reaper.ImGui_IsItemClicked(ctx, 1) then
      show_picker = not show_picker
      if show_picker then picker_first_frame = true end
    end
    if not reaper.ImGui_IsMouseDown(ctx, 0) and reaper.ImGui_IsItemDeactivated(ctx) then open = false end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then open = false end
    reaper.ImGui_End(ctx)
  end

  if show_picker then
    reaper.ImGui_SetNextWindowPos(ctx, main_wx + WINDOW_WIDTH + math.floor(8 * GUI_SCALE), main_wy, reaper.ImGui_Cond_Always())
    reaper.ImGui_SetNextWindowSize(ctx, PICKER_WIDTH, PICKER_HEIGHT)
    local pvis, p_open = reaper.ImGui_Begin(ctx, 'ColorPicker', true, flags)

    if pvis then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local px, py = reaper.ImGui_GetWindowPos(ctx)
      local svx, svy = px + PICKER_PADDING, py + PICKER_PADDING
      local hxx = svx + SV_SIZE + PICKER_PADDING

      reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px + PICKER_WIDTH, py + PICKER_HEIGHT, 0xFF000000, 4)
      drawSVSquare(dl, svx, svy, SV_SIZE)
      drawHueGradient(dl, hxx, svy, HUE_SLIDER_WIDTH, SV_SIZE)

      local btn_size = math.floor(14 * GUI_SCALE)
      local icon_x = hxx + HUE_SLIDER_WIDTH + PICKER_PADDING
      local plus_y = svy + 4
      
      -- 1. Scale Button (+)
      reaper.ImGui_SetCursorScreenPos(ctx, icon_x, plus_y)
      reaper.ImGui_InvisibleButton(ctx, '##scale_btn', btn_size, btn_size)
      local p_hover = reaper.ImGui_IsItemHovered(ctx)
      local p_active = reaper.ImGui_IsItemActive(ctx)
      local p_col = p_hover and 0xFFFFFFFF or 0xCCFFFFFF
      local cx, cy = icon_x + btn_size/2, plus_y + btn_size/2
      reaper.ImGui_DrawList_AddLine(dl, cx - btn_size*0.3, cy, cx + btn_size*0.3, cy, p_col, 1)
      reaper.ImGui_DrawList_AddLine(dl, cx, cy - btn_size*0.3, cx, cy + btn_size*0.3, p_col, 1)

      if p_hover and not p_active then
        if not scale_hover_start then scale_hover_start = reaper.time_precise() end
        checkTooltip(scale_hover_start, 'Drag vertically to resize')
      else
        scale_hover_start = nil
      end

      if p_active then
        local _, my = reaper.ImGui_GetMousePos(ctx)
        if not drag_scale_start_y then drag_scale_start_y, drag_scale_start_value = my, GUI_SCALE end
        GUI_SCALE = math.max(0.8, math.min(2.5, drag_scale_start_value + (drag_scale_start_y - my) * 0.01))
        updateGuiMetrics()
        reaper.SetExtState(EXT_SECTION, 'scale', tostring(GUI_SCALE), true)
      else drag_scale_start_y = nil end

      -- 2. Shadow Intensity Dot
      local contrast_y = plus_y + btn_size + math.floor(10 * GUI_SCALE)
      reaper.ImGui_SetCursorScreenPos(ctx, icon_x, contrast_y)
      reaper.ImGui_InvisibleButton(ctx, '##contrast_btn', btn_size, btn_size)
      local c_hover = reaper.ImGui_IsItemHovered(ctx)
      local c_active = reaper.ImGui_IsItemActive(ctx)
      local c_col = c_hover and 0xFFFFFFFF or 0xCCFFFFFF
      
      local dcx, dcy = icon_x + btn_size/2, contrast_y + btn_size/2
      reaper.ImGui_DrawList_AddCircleFilled(dl, dcx, dcy, btn_size * 0.2, c_col)

      if c_hover and not c_active then
        if not contrast_hover_start then contrast_hover_start = reaper.time_precise() end
        checkTooltip(contrast_hover_start, 'Drag vertically to adjust shadow')
      else
        contrast_hover_start = nil
      end

      if c_active then
        local _, my = reaper.ImGui_GetMousePos(ctx)
        if not drag_contrast_start_y then drag_contrast_start_y, drag_contrast_start_value = my, CONTRAST end
        CONTRAST = math.max(0, math.min(1, drag_contrast_start_value + (drag_contrast_start_y - my) * 0.02))
        BLUE_TINT, BLUE_TINT_HOVER, SHADOW_COLOR = updateColors()
        reaper.SetExtState(EXT_SECTION, 'contrast', tostring(CONTRAST), true)
      else drag_contrast_start_y = nil end

      -- 3. Position Mode Toggle (■) - FIXED CLICK DETECTION
      local mode_y = contrast_y + btn_size + math.floor(10 * GUI_SCALE)
      reaper.ImGui_SetCursorScreenPos(ctx, icon_x, mode_y)
      reaper.ImGui_InvisibleButton(ctx, '##mode_btn', btn_size, btn_size)
      local m_hover = reaper.ImGui_IsItemHovered(ctx)
      
      -- Draw square: hollow if mode=0 (follow mouse), filled if mode=1 (remember position)
      local mx, my = icon_x, mode_y
      local square_color = m_hover and 0xFFFFFFFF or 0xCCFFFFFF
      if POS_MODE == 1 then
        reaper.ImGui_DrawList_AddRectFilled(dl, mx+2, my+2, mx+btn_size-2, my+btn_size-2, square_color)
      else
        reaper.ImGui_DrawList_AddRect(dl, mx+2, my+2, mx+btn_size-2, my+btn_size-2, square_color, 0, 0, 1)
      end

      -- Tooltip
      if m_hover then
        if not mode_hover_start then mode_hover_start = reaper.time_precise() end
        local tooltip_text = POS_MODE == 0 and "Mode: Follow Mouse (click to switch to Remember Position)" or "Mode: Remember Position (click to switch to Follow Mouse)"
        checkTooltip(mode_hover_start, tooltip_text)
      else
        mode_hover_start = nil
      end

      -- CORRECT CLICK HANDLING: use IsItemClicked
      if reaper.ImGui_IsItemClicked(ctx, 0) then
        POS_MODE = 1 - POS_MODE
        reaper.SetExtState(EXT_SECTION, 'posmode', tostring(POS_MODE), true)
        -- If switching to remember mode, save current main window position
        if POS_MODE == 1 and main_wx and main_wy then
          SAVED_POS_X, SAVED_POS_Y = main_wx, main_wy
          reaper.SetExtState(EXT_SECTION, 'pos_x', tostring(SAVED_POS_X), true)
          reaper.SetExtState(EXT_SECTION, 'pos_y', tostring(SAVED_POS_Y), true)
        end
      end

      -- Interaction Boxes
      reaper.ImGui_SetCursorScreenPos(ctx, svx, svy)
      reaper.ImGui_InvisibleButton(ctx, '##sv_btn', SV_SIZE, SV_SIZE)
      if reaper.ImGui_IsItemActive(ctx) then
        local mx, my = reaper.ImGui_GetMousePos(ctx)
        SAT, VAL = math.max(0, math.min(1, (mx - svx) / SV_SIZE)), 1 - math.max(0, math.min(1, (my - svy) / SV_SIZE))
        BLUE_TINT, BLUE_TINT_HOVER, SHADOW_COLOR = updateColors()
      end
      reaper.ImGui_SetCursorScreenPos(ctx, hxx, svy)
      reaper.ImGui_InvisibleButton(ctx, '##hue_btn', HUE_SLIDER_WIDTH, SV_SIZE)
      if reaper.ImGui_IsItemActive(ctx) then
        local _, my = reaper.ImGui_GetMousePos(ctx)
        HUE = math.max(0, math.min(1, (my - svy) / SV_SIZE))
        BLUE_TINT, BLUE_TINT_HOVER, SHADOW_COLOR = updateColors()
      end

      reaper.ImGui_DrawList_AddCircle(dl, svx + SAT * SV_SIZE, svy + (1 - VAL) * SV_SIZE, 4, 0xFFFFFFFF)
      reaper.ImGui_DrawList_AddLine(dl, hxx - 2, svy + HUE * SV_SIZE, hxx + HUE_SLIDER_WIDTH + 2, svy + HUE * SV_SIZE, 0xFFFFFFFF, 2)

      reaper.SetExtState(EXT_SECTION, 'hue', tostring(HUE), true)
      reaper.SetExtState(EXT_SECTION, 'sat', tostring(SAT), true)
      reaper.SetExtState(EXT_SECTION, 'val', tostring(VAL), true)
      reaper.ImGui_End(ctx)
    end

    if not p_open then show_picker = false end
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
  if open then reaper.defer(main) end
end

main()