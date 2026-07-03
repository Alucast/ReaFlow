-- @description Metronome Volume Slider (Matched Icon Colors + Clamped Shadow + Position Toggle + Border Toggle)
-- @version 5.8
-- @author Alejandro (Alu) + adjusted defaults

local ctx = reaper.ImGui_CreateContext('MetroFullColor')

-- Settings
local EXT_SECTION = 'MetroVolSlider'

-- Tooltip delay in seconds
local TOOLTIP_DELAY = 1.0

-- Load States
local HUE = tonumber(reaper.GetExtState(EXT_SECTION, 'hue')) or 0.6
local SAT = tonumber(reaper.GetExtState(EXT_SECTION, 'sat')) or 0.75
local VAL = tonumber(reaper.GetExtState(EXT_SECTION, 'val')) or 0.85
local GUI_SCALE = tonumber(reaper.GetExtState(EXT_SECTION, 'scale')) or 1.5
local CONTRAST = tonumber(reaper.GetExtState(EXT_SECTION, 'contrast')) or 0.5

-- Position mode (true = follow mouse, false = remember last position)
local FOLLOW_MOUSE = (reaper.GetExtState(EXT_SECTION, 'follow_mouse') ~= 'false')
local LAST_X = tonumber(reaper.GetExtState(EXT_SECTION, 'last_x'))
local LAST_Y = tonumber(reaper.GetExtState(EXT_SECTION, 'last_y'))

-- Border toggle (saved)
local SHOW_BORDER = (reaper.GetExtState(EXT_SECTION, 'show_border') == 'true')

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

-- Fallback for first-run fixed mode
if not LAST_X then LAST_X = mouse_x end
if not LAST_Y then LAST_Y = mouse_y end

local first_frame, show_picker, picker_first_frame = true, false, true
local drag_scale_start_y, drag_scale_start_value = nil, nil
local drag_contrast_start_y, drag_contrast_start_value = nil, nil
local main_wx, main_wy = 0, 0

-- Window drag state (NEW)
local window_drag_mode = false
local drag_start_mx, drag_start_my = 0, 0
local drag_start_wx, drag_start_wy = 0, 0
local drag_threshold_met = false
local force_pos_x, force_pos_y = 0, 0
local force_position = false

-- Tooltip state
local scale_hover_start, contrast_hover_start, toggle_hover_start, border_hover_start = nil, nil, nil, nil

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

  -- Apply forced position from drag, or spawn logic
  if force_position then
    reaper.ImGui_SetNextWindowPos(ctx, force_pos_x, force_pos_y, reaper.ImGui_Cond_Always())
    force_position = false
  elseif first_frame then
    if FOLLOW_MOUSE then
      reaper.ImGui_SetNextWindowPos(ctx, mouse_x, mouse_y, reaper.ImGui_Cond_Always(), 0.5, 0.5)
    else
      reaper.ImGui_SetNextWindowPos(ctx, LAST_X, LAST_Y, reaper.ImGui_Cond_Always())
    end
    first_frame = false
  end

  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_WIDTH, WINDOW_HEIGHT)
  local visible, open = reaper.ImGui_Begin(ctx, 'MainVol', true, flags)

  if visible then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    main_wx, main_wy = wx, wy

    -- Remember last position when in fixed mode
    if not FOLLOW_MOUSE and not window_drag_mode then
      local ix, iy = math.floor(wx), math.floor(wy)
      if ix ~= LAST_X or iy ~= LAST_Y then
        LAST_X, LAST_Y = ix, iy
        reaper.SetExtState(EXT_SECTION, 'last_x', tostring(ix), true)
        reaper.SetExtState(EXT_SECTION, 'last_y', tostring(iy), true)
      end
    end

    local tx, ty = wx + PADDING, wy + PADDING

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
    local item_hovered = reaper.ImGui_IsItemHovered(ctx)

    -- Left-click drag = volume
    if reaper.ImGui_IsItemActive(ctx) then
      local _, my = reaper.ImGui_GetMousePos(ctx)
      current_vol = 1.0 - math.max(0, math.min(1, (my - (ty + handle_h / 2)) / (SLIDER_HEIGHT - handle_h)))
      applyVolume(current_vol)
    end

    -- Right-click: drag to move window (locked mode) or toggle picker
    if item_hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
      if FOLLOW_MOUSE then
        show_picker = not show_picker
        if show_picker then picker_first_frame = true end
      else
        window_drag_mode = true
        drag_start_mx, drag_start_my = reaper.ImGui_GetMousePos(ctx)
        drag_start_wx, drag_start_wy = wx, wy
        drag_threshold_met = false
      end
    end

    if window_drag_mode then
      if reaper.ImGui_IsMouseDown(ctx, 1) then
        local mx, my = reaper.ImGui_GetMousePos(ctx)
        local dx = mx - drag_start_mx
        local dy = my - drag_start_my
        if not drag_threshold_met and (math.abs(dx) > 4 or math.abs(dy) > 4) then
          drag_threshold_met = true
        end
        if drag_threshold_met then
          local new_x = drag_start_wx + dx
          local new_y = drag_start_wy + dy
          force_pos_x, force_pos_y = new_x, new_y
          force_position = true
          LAST_X, LAST_Y = math.floor(new_x), math.floor(new_y)
          reaper.SetExtState(EXT_SECTION, 'last_x', tostring(LAST_X), true)
          reaper.SetExtState(EXT_SECTION, 'last_y', tostring(LAST_Y), true)
        end
      else
        -- Right mouse released
        if not drag_threshold_met then
          show_picker = not show_picker
          if show_picker then picker_first_frame = true end
        end
        window_drag_mode = false
        drag_threshold_met = false
      end
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

      -- Tooltip logic for scale button (hidden when dragging)
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

      -- Tooltip logic for contrast button (hidden when dragging)
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

      -- 3. Border Toggle (outlined square)
      local border_y = py + PICKER_HEIGHT - PICKER_PADDING - btn_size * 2 - math.floor(8 * GUI_SCALE)
      reaper.ImGui_SetCursorScreenPos(ctx, icon_x, border_y)
      reaper.ImGui_InvisibleButton(ctx, '##border_btn', btn_size, btn_size)
      local b_hover = reaper.ImGui_IsItemHovered(ctx)
      local b_active = reaper.ImGui_IsItemActive(ctx)

      -- Draw an outlined square: bright when border ON, dim when OFF
      local b_col = b_hover and 0xFFFFFFFF or (SHOW_BORDER and 0xDDFFFFFF or 0x22FFFFFF)
      local b_pad = btn_size * 0.2
      reaper.ImGui_DrawList_AddRect(dl,
        icon_x + b_pad, border_y + b_pad,
        icon_x + btn_size - b_pad, border_y + btn_size - b_pad,
        b_col, 2, nil, 1.5)

      -- Tooltip
      if b_hover and not b_active then
        if not border_hover_start then border_hover_start = reaper.time_precise() end
        local b_tip = SHOW_BORDER and 'Click to hide window border' or 'Click to show window border'
        checkTooltip(border_hover_start, b_tip)
      else
        border_hover_start = nil
      end

      if reaper.ImGui_IsItemClicked(ctx, 0) then
        SHOW_BORDER = not SHOW_BORDER
        reaper.SetExtState(EXT_SECTION, 'show_border', tostring(SHOW_BORDER), true)
      end

      -- 4. Position Mode Toggle (filled square)
      local toggle_y = py + PICKER_HEIGHT - PICKER_PADDING - btn_size
      reaper.ImGui_SetCursorScreenPos(ctx, icon_x, toggle_y)
      reaper.ImGui_InvisibleButton(ctx, '##toggle_pos', btn_size, btn_size)
      local t_hover = reaper.ImGui_IsItemHovered(ctx)
      local t_active = reaper.ImGui_IsItemActive(ctx)

      -- Much darker when OFF (follow mouse) so the contrast between states is higher
      local t_col = t_hover and 0xFFFFFFFF or (FOLLOW_MOUSE and 0x22FFFFFF or 0xDDFFFFFF)
      local sq_pad = btn_size * 0.2
      reaper.ImGui_DrawList_AddRectFilled(dl,
        icon_x + sq_pad, toggle_y + sq_pad,
        icon_x + btn_size - sq_pad, toggle_y + btn_size - sq_pad,
        t_col, 2)

      -- Tooltip
      if t_hover and not t_active then
        if not toggle_hover_start then toggle_hover_start = reaper.time_precise() end
        local tip = FOLLOW_MOUSE and 'Click to lock window position' or 'Click to follow mouse cursor'
        checkTooltip(toggle_hover_start, tip)
      else
        toggle_hover_start = nil
      end

      if reaper.ImGui_IsItemClicked(ctx, 0) then
        FOLLOW_MOUSE = not FOLLOW_MOUSE
        reaper.SetExtState(EXT_SECTION, 'follow_mouse', tostring(FOLLOW_MOUSE), true)
        if not FOLLOW_MOUSE then
          -- Snap current position so it doesn't jump to an old value
          local ix, iy = math.floor(main_wx), math.floor(main_wy)
          LAST_X, LAST_Y = ix, iy
          reaper.SetExtState(EXT_SECTION, 'last_x', tostring(ix), true)
          reaper.SetExtState(EXT_SECTION, 'last_y', tostring(iy), true)
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
