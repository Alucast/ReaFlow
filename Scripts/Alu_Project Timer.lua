-- @author Alejandro (Alu) 

local reaper = reaper

-- Configuration object for easy customization
local CONFIG = {
    PROJECT_ID = 0,
    SECTION_NAME = "AI_ProjectTimer",
    FONT_FAMILY = "sans-serif",
    FONT_SIZE = 13,
    AUTO_SAVE_INTERVAL = 5,
    DISPLAY_UPDATE_INTERVAL = 0.25,
    DEFAULT_AFK_THRESHOLD = 1,
    MAX_AFK_THRESHOLD = 60,
    ACTIVITY_CHECK_INTERVAL = 0.5,
    DEFAULT_TOOLTIP_DELAY = 1.5,
    DEFAULT_FORMAT_MODE = 2,
    DEFAULT_INITIAL_PAUSED = true,
    DEFAULT_TRANSPORT_MODE_ACTIVE = false,
    MIN_FONT_SIZE = 8,
    MAX_FONT_SIZE = 24
}

-- Error checking for ReaImGui
if not reaper.ImGui_GetBuiltinPath then
    reaper.MB("ReaImGui extension is required", "Missing Dependency", 0)
    return
end

-- Initialize ImGui
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
local ctx = ImGui.CreateContext('Project Time Counter')

-- Window flags
local WindowFlags = ImGui.WindowFlags_AlwaysAutoResize | 
                   ImGui.WindowFlags_NoSavedSettings | 
                   ImGui.WindowFlags_NoTitleBar

-- State
local settings = {
    afk_threshold = CONFIG.DEFAULT_AFK_THRESHOLD,
    afk_enabled = true,
    paused = CONFIG.DEFAULT_INITIAL_PAUSED,
    initial_paused = CONFIG.DEFAULT_INITIAL_PAUSED,
    timer = 0,
    format_mode = CONFIG.DEFAULT_FORMAT_MODE,
    time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0},
    last_action_time = reaper.time_precise(),
    prev_proj_change_count = reaper.GetProjectStateChangeCount(0),
    last_time = reaper.time_precise(),
    collapsed = true,
    last_save_time = reaper.time_precise(),
    cache = {last_timer_value = -1, last_format_mode = -1, formatted_string = "00:00:00"},
    display = {update_interval = CONFIG.DISPLAY_UPDATE_INTERVAL, last_update = 0},
    activity = {
        last_mouse_x = 0, 
        last_mouse_y = 0, 
        last_cursor_pos = 0, 
        last_midi_hash = "",
        last_check_time = 0, 
        check_interval = CONFIG.ACTIVITY_CHECK_INTERVAL
    },
    transport_mode_active = CONFIG.DEFAULT_TRANSPORT_MODE_ACTIVE,
    transport_timer = 0,
    transport_last_time = reaper.time_precise(),
    settings_loaded = false,
    window_pos_x = 100,
    window_pos_y = 100,
    font_size = CONFIG.FONT_SIZE,
}

local settings_dirty = false
local hover_times = {}
local font_update_pending = false

-- Create font once; only recreate when user finishes editing font size
local font = ImGui.CreateFont(CONFIG.FONT_FAMILY, settings.font_size)
ImGui.Attach(ctx, font)

-- Utility functions
local function load_setting(key, default, convert_func)
    local exists, value = reaper.GetProjExtState(CONFIG.PROJECT_ID, CONFIG.SECTION_NAME, key)
    if exists and value and value ~= "" then
        local success, result = pcall(function() return convert_func and convert_func(value) or value end)
        return success and result or default
    end
    return default
end

local function save_setting(key, value)
    if value ~= nil then
        reaper.SetProjExtState(CONFIG.PROJECT_ID, CONFIG.SECTION_NAME, key, tostring(value))
    end
end

local function time_string(timer_value)
    local total = math.floor(timer_value ~= nil and timer_value or settings.timer)
    if timer_value == nil and 
       settings.cache.last_timer_value == total and 
       settings.cache.last_format_mode == settings.format_mode then
        return settings.cache.formatted_string
    end
    
    local seconds = total % 60
    local total_minutes = math.floor(total / 60)
    local minutes = total_minutes % 60
    local total_hours = math.floor(total_minutes / 60)
    local hours = total_hours % 24
    local total_days = math.floor(total_hours / 24)
    local days = total_days % 7
    local weeks = math.floor(total_days / 7)
    
    local result
    if settings.format_mode == 1 then
        result = string.format("%dd %02d:%02d:%02d", total_days, hours, minutes, seconds)
    elseif settings.format_mode == 2 then
        hours = hours + total_days * 24
        result = string.format("%02d:%02d:%02d", hours, minutes, seconds)
    else
        result = string.format("%dw %dd %02d:%02d:%02d", weeks, days, hours, minutes, seconds)
    end
    
    if timer_value == nil then
        settings.cache.last_timer_value = total
        settings.cache.last_format_mode = settings.format_mode
        settings.cache.formatted_string = result
    end
    
    return result
end

local function apply_font_update()
    if font_update_pending then
        local success, err = pcall(function()
            ImGui.Detach(ctx, font)
            font = ImGui.CreateFont(CONFIG.FONT_FAMILY, settings.font_size)
            ImGui.Attach(ctx, font)
        end)
        if not success then
            reaper.ShowConsoleMsg("Error updating font: " .. tostring(err) .. "\n")
        end
        font_update_pending = false
    end
end

local function restore_settings()
    if settings.settings_loaded then return end
    
    settings.timer = load_setting("timer", 0, tonumber)
    settings.format_mode = math.min(math.max(load_setting("format_mode", CONFIG.DEFAULT_FORMAT_MODE, tonumber), 1), 3)
    settings.afk_threshold = math.min(math.max(load_setting("afk_threshold", CONFIG.DEFAULT_AFK_THRESHOLD, tonumber), 1), CONFIG.MAX_AFK_THRESHOLD)
    settings.afk_enabled = load_setting("afk_enabled", 1, tonumber) == 1
    settings.initial_paused = load_setting("initial_state", CONFIG.DEFAULT_INITIAL_PAUSED and 1 or 0, tonumber) == 1
    settings.paused = settings.initial_paused
    settings.transport_timer = load_setting("transport_timer", 0, tonumber)
    settings.transport_mode_active = load_setting("transport_mode_active", CONFIG.DEFAULT_TRANSPORT_MODE_ACTIVE and 1 or 0, tonumber) == 1
    settings.window_pos_x = load_setting("window_pos_x", 100, tonumber)
    settings.window_pos_y = load_setting("window_pos_y", 100, tonumber)
    settings.font_size = load_setting("font_size", CONFIG.FONT_SIZE, tonumber)
    
    settings.cache.formatted_string = time_string()
    settings.cache.last_timer_value = math.floor(settings.timer)
    settings.settings_loaded = true
    
    -- Apply loaded font size immediately
    font_update_pending = true
end

local function store_settings()
    save_setting("timer", math.floor(settings.timer))
    save_setting("format_mode", settings.format_mode)
    save_setting("afk_threshold", settings.afk_threshold)
    save_setting("afk_enabled", settings.afk_enabled and 1 or 0)
    save_setting("initial_state", settings.initial_paused and 1 or 0)
    save_setting("transport_timer", math.floor(settings.transport_timer))
    save_setting("transport_mode_active", settings.transport_mode_active and 1 or 0)
    save_setting("window_pos_x", settings.window_pos_x)
    save_setting("window_pos_y", settings.window_pos_y)
    save_setting("font_size", settings.font_size)
    settings_dirty = false
end

local function apply_offset()
    local offset_seconds = settings.time_offset.weeks * 7 * 86400 +
                          settings.time_offset.days * 86400 +
                          settings.time_offset.hours * 3600 +
                          settings.time_offset.minutes * 60
    
    -- Prevent negative total time
    if offset_seconds < -settings.timer then
        offset_seconds = -settings.timer
    end
    
    settings.timer = math.max(0, settings.timer + offset_seconds)
    settings.time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0}
    settings.cache.formatted_string = time_string()
    settings.cache.last_timer_value = math.floor(settings.timer)
    settings_dirty = true
end

local function check_user_activity(current_time, play_state)
    if current_time - settings.activity.last_check_time < settings.activity.check_interval then 
        return false 
    end
    
    local x, y = reaper.GetMousePosition()
    local cursor_pos = reaper.GetCursorPosition()
    
    local activity_detected = x ~= settings.activity.last_mouse_x or 
                            y ~= settings.activity.last_mouse_y or 
                            cursor_pos ~= settings.activity.last_cursor_pos or
                            play_state ~= 0
    
    -- Only check MIDI if no other activity detected (expensive call)
    if not activity_detected then
        local midi_editor = reaper.MIDIEditor_GetActive()
        if midi_editor then
            local take = reaper.MIDIEditor_GetTake(midi_editor)
            if take then
                local hash = reaper.MIDI_GetTrackHash(take)
                activity_detected = hash ~= settings.activity.last_midi_hash
                settings.activity.last_midi_hash = hash
            end
        end
    end
    
    settings.activity.last_mouse_x, settings.activity.last_mouse_y = x, y
    settings.activity.last_cursor_pos = cursor_pos
    settings.activity.last_check_time = current_time
    
    return activity_detected
end

local function cleanup()
    store_settings()
end

local function handle_delayed_tooltip(key, text, delay)
    local current_time = reaper.time_precise()
    if ImGui.IsItemHovered(ctx) then
        if not hover_times[key] then hover_times[key] = current_time end
        if current_time - hover_times[key] >= (delay or CONFIG.DEFAULT_TOOLTIP_DELAY) then
            ImGui.BeginTooltip(ctx)
            ImGui.Text(ctx, text)
            ImGui.EndTooltip(ctx)
        end
    else
        hover_times[key] = nil
    end
end

local function draw_settings_popup(ctx)
    if ImGui.BeginPopup(ctx, 'Settings') then
        ImGui.PushFont(ctx, font)

        ImGui.Text(ctx, 'Time Format:')
        handle_delayed_tooltip('time_format_tooltip', 'Choose how time is displayed')
        ImGui.Spacing(ctx)
        
        local changed
        changed, settings.format_mode = ImGui.RadioButtonEx(ctx, 'Hours', settings.format_mode, 2)
        if changed then settings_dirty = true end
        ImGui.SameLine(ctx)
        changed, settings.format_mode = ImGui.RadioButtonEx(ctx, 'Days', settings.format_mode, 1)
        if changed then settings_dirty = true end
        ImGui.SameLine(ctx)
        changed, settings.format_mode = ImGui.RadioButtonEx(ctx, 'Weeks', settings.format_mode, 3)
        if changed then settings_dirty = true end
        
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
        ImGui.Spacing(ctx)
        
        ImGui.Text(ctx, 'Initial State:')
        ImGui.Spacing(ctx)
        
        local initial_state = settings.initial_paused and 1 or 0
        changed, initial_state = ImGui.RadioButtonEx(ctx, 'Start Paused', initial_state, 1)
        ImGui.SameLine(ctx)
        changed, initial_state = ImGui.RadioButtonEx(ctx, 'Start Running', initial_state, 0)
        if changed then 
            settings.initial_paused = (initial_state == 1)
            settings_dirty = true
        end
        
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
        ImGui.Spacing(ctx)
        
        ImGui.Text(ctx, 'AFK Detection:')
        ImGui.SameLine(ctx)
        changed, settings.afk_enabled = ImGui.Checkbox(ctx, '##afk_enabled', settings.afk_enabled)
        if changed then settings_dirty = true end
        handle_delayed_tooltip('afk_enabled_tooltip', 'Enable/disable AFK detection')
        
        if settings.afk_enabled then
            ImGui.Spacing(ctx)
            ImGui.PushItemWidth(ctx, 80)
            changed, settings.afk_threshold = ImGui.InputInt(ctx, 'in minutes##afk', settings.afk_threshold, 1, 5)
            if changed then
                settings.afk_threshold = math.max(1, math.min(settings.afk_threshold, CONFIG.MAX_AFK_THRESHOLD))
                settings_dirty = true
            end
            handle_delayed_tooltip('afk_input_tooltip', 'AFK threshold in minutes (Max: 60)')
            ImGui.PopItemWidth(ctx)
        end
        
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
        ImGui.Spacing(ctx)
        
        ImGui.Text(ctx, 'Font Size:')
        ImGui.PushItemWidth(ctx, 100)
        local changed_font, new_font_size = ImGui.SliderInt(ctx, '##font_size', settings.font_size, CONFIG.MIN_FONT_SIZE, CONFIG.MAX_FONT_SIZE)
        ImGui.PopItemWidth(ctx)
        if changed_font then
            settings.font_size = new_font_size
        end
        -- Only rebuild font atlas when user releases the slider
        if changed_font and ImGui.IsItemDeactivatedAfterEdit(ctx) then
            font_update_pending = true
        end
        handle_delayed_tooltip('font_size_tooltip', 'Adjust font size (' .. CONFIG.MIN_FONT_SIZE .. '-' .. CONFIG.MAX_FONT_SIZE .. ')')
        
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
        ImGui.Spacing(ctx)
        
        if ImGui.Button(ctx, 'Close') then
            ImGui.CloseCurrentPopup(ctx)
        end
        
        ImGui.PopFont(ctx)
        ImGui.EndPopup(ctx)
    end
end

local function draw_time_offset_popup(ctx)
    if ImGui.BeginPopup(ctx, 'Time Offset') then
        ImGui.PushFont(ctx, font)

        ImGui.Text(ctx, 'Add/Subtract time offset:')
        local input_width = 80
        
        local function offset_input(label, value)
            ImGui.PushItemWidth(ctx, input_width)
            local changed, val = ImGui.InputInt(ctx, label, value)
            ImGui.PopItemWidth(ctx)
            if ImGui.IsItemActive(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
                apply_offset()
                ImGui.CloseCurrentPopup(ctx)
            end
            return changed, val
        end
        
        local changed
        changed, settings.time_offset.weeks = offset_input('Weeks', settings.time_offset.weeks)
        changed, settings.time_offset.days = offset_input('Days', settings.time_offset.days)
        changed, settings.time_offset.hours = offset_input('Hours', settings.time_offset.hours)
        changed, settings.time_offset.minutes = offset_input('Minutes', settings.time_offset.minutes)
        
        ImGui.Spacing(ctx)
        if ImGui.Button(ctx, 'Apply') then
            apply_offset()
            ImGui.CloseCurrentPopup(ctx)
        end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, 'Cancel') then
            settings.time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0}
            ImGui.CloseCurrentPopup(ctx)
        end

        ImGui.PopFont(ctx)
        ImGui.EndPopup(ctx)
    end
end

local function draw_main_window(ctx, current_time)
    ImGui.SetNextWindowPos(ctx, settings.window_pos_x, settings.window_pos_y, ImGui.Cond_Once)
    
    local visible, open = ImGui.Begin(ctx, 'Timer', true, WindowFlags)
    
    if visible then
        ImGui.PushFont(ctx, font)

        local window_pos_x, window_pos_y = ImGui.GetWindowPos(ctx)
        settings.window_pos_x = window_pos_x
        settings.window_pos_y = window_pos_y
        
        local window_width = ImGui.GetWindowWidth(ctx)
        
        ImGui.AlignTextToFramePadding(ctx)
        local display_string
        
        if settings.transport_mode_active then
            display_string = time_string(settings.transport_timer)
            ImGui.Text(ctx, display_string .. " [T]")
        else
            display_string = settings.cache.formatted_string
            if (current_time - settings.display.last_update) >= settings.display.update_interval then
                display_string = time_string()
                settings.display.last_update = current_time
            end
            ImGui.Text(ctx, display_string)
        end
        
        -- Only close on Escape if this window is actually focused
        if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
            open = false
        end
                
        handle_delayed_tooltip('timer_display_tooltip', settings.transport_mode_active and 'Transport timer' or 'Current project timer')
        
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, settings.collapsed and "+" or "-") then
            settings.collapsed = not settings.collapsed
        end
        
        if not settings.collapsed then
            ImGui.Spacing(ctx)
            local button_width = window_width - 20
            local content_width = ImGui.GetContentRegionAvail(ctx)
            local padding = (content_width - button_width) / 2
            
            ImGui.Indent(ctx, padding)
            
            if ImGui.Button(ctx, settings.paused and "Start" or "Pause", button_width, 0) then
                settings.paused = not settings.paused
                settings.last_action_time = current_time
                settings_dirty = true
            end
            
            if ImGui.Button(ctx, settings.transport_mode_active and "Tr Off" or "Trans On", button_width, 0) then
                settings.transport_mode_active = not settings.transport_mode_active
                if settings.transport_mode_active then
                    settings.transport_last_time = current_time
                end
                settings_dirty = true
            end
            handle_delayed_tooltip('transport_toggle_tooltip', 'Toggle transport mode on/off')
            
            if ImGui.Button(ctx, '- +', button_width, 0) then 
                ImGui.OpenPopup(ctx, 'Time Offset') 
            end
            if ImGui.Button(ctx, 'Settings', button_width, 0) then 
                ImGui.OpenPopup(ctx, 'Settings') 
            end
            if ImGui.Button(ctx, 'Reset', button_width, 0) then
                settings.timer = 0
                settings.transport_timer = 0
                settings.last_action_time = current_time
                settings.cache.formatted_string = time_string()
                settings.cache.last_timer_value = 0
                settings_dirty = true
            end
            
            ImGui.Unindent(ctx, padding)
        end
        
        draw_settings_popup(ctx)
        draw_time_offset_popup(ctx)

        ImGui.PopFont(ctx)
        ImGui.End(ctx)
    end
    
    return open
end 

local function advance_timers(dt, current_time, play_state)
    if not settings.paused then
        local is_user_active = check_user_activity(current_time, play_state)
        
        if is_user_active then
            settings.last_action_time = current_time
        end
        
        local threshold_in_seconds = settings.afk_threshold * 60
        local time_since_last_action = current_time - settings.last_action_time
        local is_afk = settings.afk_enabled and (time_since_last_action >= threshold_in_seconds)
        
        if not is_afk then
            settings.timer = settings.timer + dt
        end
    end
    
    if settings.transport_mode_active and play_state == 1 then
        settings.transport_timer = settings.transport_timer + dt
    end
    
    local floored = math.floor(settings.timer)
    if floored ~= settings.cache.last_timer_value then
        settings.cache.formatted_string = time_string()
        settings.cache.last_timer_value = floored
        settings_dirty = true
    end
end

local function main()
    local current_time = reaper.time_precise()
    local play_state = reaper.GetPlayState()
    local proj_change_count = reaper.GetProjectStateChangeCount(CONFIG.PROJECT_ID)
    
    if not settings.settings_loaded then
        restore_settings()
    end
    
    -- Apply font update before rendering if needed
    apply_font_update()
    
    local dt = current_time - settings.last_time
    
    -- Project state changes count as user activity for AFK reset
    if proj_change_count ~= settings.prev_proj_change_count then
        settings.last_action_time = current_time
    end
    
    advance_timers(dt, current_time, play_state)
    
    settings.transport_last_time = current_time
    settings.last_time = current_time
    settings.prev_proj_change_count = proj_change_count

    local open = draw_main_window(ctx, current_time)
    
    -- Only write to project extstate when something changed
    if settings_dirty and (current_time - settings.last_save_time >= CONFIG.AUTO_SAVE_INTERVAL) then
        store_settings()
        settings.last_save_time = current_time
    end
    
    if open then
        reaper.defer(main)
    end
end

reaper.atexit(cleanup)
reaper.defer(main)
