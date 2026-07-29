-- @description Alu Project Timer
-- @author Alejandro (Alu)
-- @version 2.3
-- @about
--   Project-aware work timer with AFK detection and a transport timer.
--   This version safely follows REAPER project-tab changes.

local reaper = reaper

local CONFIG = {
    SECTION_NAME = "AI_ProjectTimer",
    FONT_FAMILY = "sans-serif",
    FONT_SIZE = 13,
    AUTO_SAVE_INTERVAL = 5,
    DEFAULT_AFK_THRESHOLD = 1,
    MAX_AFK_THRESHOLD = 60,
    ACTIVITY_CHECK_INTERVAL = 0.5,
    DEFAULT_TOOLTIP_DELAY = 1.5,
    DEFAULT_FORMAT_MODE = 2,
    DEFAULT_INITIAL_PAUSED = true,
    DEFAULT_TRANSPORT_MODE_ACTIVE = false,
    MIN_FONT_SIZE = 8,
    MAX_FONT_SIZE = 24,
    MAX_FRAME_DELTA = 2
}

if not reaper.ImGui_GetBuiltinPath then
    reaper.MB("ReaImGui extension is required.", "Missing Dependency", 0)
    return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local imgui_ok, ImGui = pcall(function()
    return require("imgui")("0.9.3")
end)

if not imgui_ok then
    reaper.MB(
        "Unable to load ReaImGui:\n\n" .. tostring(ImGui),
        "Project Timer",
        0
    )
    return
end

local ctx = ImGui.CreateContext("Project Time Counter")

local WindowFlags = ImGui.WindowFlags_AlwaysAutoResize
    | ImGui.WindowFlags_NoSavedSettings
    | ImGui.WindowFlags_NoTitleBar

local settings = {
    afk_threshold = CONFIG.DEFAULT_AFK_THRESHOLD,
    afk_enabled = true,
    paused = CONFIG.DEFAULT_INITIAL_PAUSED,
    initial_paused = CONFIG.DEFAULT_INITIAL_PAUSED,
    timer = 0,
    format_mode = CONFIG.DEFAULT_FORMAT_MODE,
    time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0},
    last_action_time = reaper.time_precise(),
    prev_proj_change_count = 0,
    last_time = reaper.time_precise(),
    collapsed = true,
    last_save_time = reaper.time_precise(),
    cache = {
        last_timer_value = -1,
        last_format_mode = -1,
        formatted_string = "00:00:00"
    },
    activity = {
        last_mouse_x = 0,
        last_mouse_y = 0,
        last_cursor_pos = 0,
        last_check_time = 0,
        check_interval = CONFIG.ACTIVITY_CHECK_INTERVAL
    },
    transport_mode_active = CONFIG.DEFAULT_TRANSPORT_MODE_ACTIVE,
    transport_timer = 0,
    window_pos_x = 100,
    window_pos_y = 100,
    font_size = CONFIG.FONT_SIZE
}

local settings_dirty = false
local hover_times = {}
local font_update_pending = false
local window_position_pending = true
local current_project

local font = ImGui.CreateFont(CONFIG.FONT_FAMILY, settings.font_size)
local applied_font_size = settings.font_size
ImGui.Attach(ctx, font)

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(value, maximum))
end

local function finite_number(value, default)
    local number = tonumber(value)
    if not number
        or number ~= number
        or number == math.huge
        or number == -math.huge
    then
        return default
    end
    return number
end

local function load_setting(project, key, default, convert_func)
    local exists, value =
        reaper.GetProjExtState(project, CONFIG.SECTION_NAME, key)

    if not exists or exists <= 0 or value == nil or value == "" then
        return default
    end

    local success, result = pcall(function()
        if convert_func then
            return convert_func(value)
        end
        return value
    end)

    if success and result ~= nil then
        return result
    end
    return default
end

local function save_setting(project, key, value)
    if project and value ~= nil then
        reaper.SetProjExtState(
            project,
            CONFIG.SECTION_NAME,
            key,
            tostring(value)
        )
    end
end

local function format_time(timer_value)
    local total = math.max(0, math.floor(finite_number(timer_value, 0)))
    local seconds = total % 60
    local total_minutes = math.floor(total / 60)
    local minutes = total_minutes % 60
    local total_hours = math.floor(total_minutes / 60)
    local hours = total_hours % 24
    local total_days = math.floor(total_hours / 24)
    local days = total_days % 7
    local weeks = math.floor(total_days / 7)

    if settings.format_mode == 1 then
        return string.format(
            "%dd %02d:%02d:%02d",
            total_days,
            hours,
            minutes,
            seconds
        )
    elseif settings.format_mode == 2 then
        return string.format(
            "%02d:%02d:%02d",
            total_hours,
            minutes,
            seconds
        )
    end

    return string.format(
        "%dw %dd %02d:%02d:%02d",
        weeks,
        days,
        hours,
        minutes,
        seconds
    )
end

local function refresh_timer_cache(force)
    local floored_timer = math.max(0, math.floor(settings.timer))
    if force
        or floored_timer ~= settings.cache.last_timer_value
        or settings.format_mode ~= settings.cache.last_format_mode
    then
        settings.cache.formatted_string = format_time(settings.timer)
        settings.cache.last_timer_value = floored_timer
        settings.cache.last_format_mode = settings.format_mode
    end
end

local function apply_font_update()
    if not font_update_pending then
        return
    end

    font_update_pending = false
    if settings.font_size == applied_font_size then
        return
    end

    local success, err = pcall(function()
        local replacement =
            ImGui.CreateFont(CONFIG.FONT_FAMILY, settings.font_size)
        ImGui.Attach(ctx, replacement)
        ImGui.Detach(ctx, font)
        font = replacement
        applied_font_size = settings.font_size
    end)

    if not success then
        settings.font_size = applied_font_size
        settings_dirty = true
        reaper.ShowConsoleMsg(
            "Project Timer: error updating font: "
                .. tostring(err)
                .. "\n"
        )
    end
end

local function restore_settings(project, current_time)
    settings.timer = math.max(
        0,
        load_setting(project, "timer", 0, function(value)
            return finite_number(value, 0)
        end)
    )

    settings.format_mode = clamp(
        math.floor(
            load_setting(
                project,
                "format_mode",
                CONFIG.DEFAULT_FORMAT_MODE,
                function(value)
                    return finite_number(value, CONFIG.DEFAULT_FORMAT_MODE)
                end
            )
        ),
        1,
        3
    )

    settings.afk_threshold = clamp(
        math.floor(
            load_setting(
                project,
                "afk_threshold",
                CONFIG.DEFAULT_AFK_THRESHOLD,
                function(value)
                    return finite_number(value, CONFIG.DEFAULT_AFK_THRESHOLD)
                end
            )
        ),
        1,
        CONFIG.MAX_AFK_THRESHOLD
    )

    settings.afk_enabled =
        load_setting(project, "afk_enabled", 1, tonumber) == 1

    settings.initial_paused =
        load_setting(
            project,
            "initial_state",
            CONFIG.DEFAULT_INITIAL_PAUSED and 1 or 0,
            tonumber
        ) == 1

    settings.paused = settings.initial_paused

    settings.transport_timer = math.max(
        0,
        load_setting(project, "transport_timer", 0, function(value)
            return finite_number(value, 0)
        end)
    )

    settings.transport_mode_active =
        load_setting(
            project,
            "transport_mode_active",
            CONFIG.DEFAULT_TRANSPORT_MODE_ACTIVE and 1 or 0,
            tonumber
        ) == 1

    settings.window_pos_x =
        load_setting(project, "window_pos_x", 100, function(value)
            return finite_number(value, 100)
        end)

    settings.window_pos_y =
        load_setting(project, "window_pos_y", 100, function(value)
            return finite_number(value, 100)
        end)

    settings.font_size = clamp(
        math.floor(
            load_setting(
                project,
                "font_size",
                CONFIG.FONT_SIZE,
                function(value)
                    return finite_number(value, CONFIG.FONT_SIZE)
                end
            )
        ),
        CONFIG.MIN_FONT_SIZE,
        CONFIG.MAX_FONT_SIZE
    )

    settings.time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0}
    settings.last_action_time = current_time
    settings.last_time = current_time
    settings.last_save_time = current_time
    settings.prev_proj_change_count =
        reaper.GetProjectStateChangeCount(project)

    local mouse_x, mouse_y = reaper.GetMousePosition()
    settings.activity.last_mouse_x = mouse_x
    settings.activity.last_mouse_y = mouse_y
    settings.activity.last_cursor_pos = reaper.GetCursorPosition()
    settings.activity.last_check_time = current_time

    refresh_timer_cache(true)
    font_update_pending = settings.font_size ~= applied_font_size
    window_position_pending = true
    settings_dirty = false
end

local function store_settings(project)
    if not project then
        return false
    end

    save_setting(project, "timer", string.format("%.3f", settings.timer))
    save_setting(project, "format_mode", settings.format_mode)
    save_setting(project, "afk_threshold", settings.afk_threshold)
    save_setting(project, "afk_enabled", settings.afk_enabled and 1 or 0)
    save_setting(
        project,
        "initial_state",
        settings.initial_paused and 1 or 0
    )
    save_setting(
        project,
        "transport_timer",
        string.format("%.3f", settings.transport_timer)
    )
    save_setting(
        project,
        "transport_mode_active",
        settings.transport_mode_active and 1 or 0
    )
    save_setting(
        project,
        "window_pos_x",
        string.format("%.1f", settings.window_pos_x)
    )
    save_setting(
        project,
        "window_pos_y",
        string.format("%.1f", settings.window_pos_y)
    )
    save_setting(project, "font_size", settings.font_size)

    settings_dirty = false
    return true
end

local function get_active_project()
    return reaper.EnumProjects(-1, "")
end

local function project_is_open(project)
    if not project then
        return false
    end

    for index = 0, 999 do
        local candidate = reaper.EnumProjects(index, "")
        if not candidate then
            return false
        end
        if candidate == project then
            return true
        end
    end

    return false
end

local function switch_project(project, current_time)
    if project == current_project then
        return
    end

    if current_project and project_is_open(current_project) then
        store_settings(current_project)
    end

    current_project = project
    if current_project then
        restore_settings(current_project, current_time)
    end
end

local function apply_offset()
    local offset_seconds =
        settings.time_offset.weeks * 7 * 86400
        + settings.time_offset.days * 86400
        + settings.time_offset.hours * 3600
        + settings.time_offset.minutes * 60

    if settings.transport_mode_active then
        settings.transport_timer =
            math.max(0, settings.transport_timer + offset_seconds)
    else
        settings.timer = math.max(0, settings.timer + offset_seconds)
        settings.last_action_time = reaper.time_precise()
        refresh_timer_cache(true)
    end

    settings.time_offset = {weeks = 0, days = 0, hours = 0, minutes = 0}
    settings_dirty = true
end

local function check_user_activity(current_time, play_state)
    if current_time - settings.activity.last_check_time
        < settings.activity.check_interval
    then
        return false
    end

    local mouse_x, mouse_y = reaper.GetMousePosition()
    local cursor_pos = reaper.GetCursorPosition()
    local transport_running = (play_state & 1) ~= 0

    local activity_detected =
        mouse_x ~= settings.activity.last_mouse_x
        or mouse_y ~= settings.activity.last_mouse_y
        or cursor_pos ~= settings.activity.last_cursor_pos
        or transport_running

    settings.activity.last_mouse_x = mouse_x
    settings.activity.last_mouse_y = mouse_y
    settings.activity.last_cursor_pos = cursor_pos
    settings.activity.last_check_time = current_time

    return activity_detected
end

local function cleanup()
    local success, is_open = pcall(project_is_open, current_project)
    if success and is_open then
        pcall(store_settings, current_project)
    end
end

local function handle_delayed_tooltip(key, text, delay)
    local current_time = reaper.time_precise()
    if ImGui.IsItemHovered(ctx) then
        if not hover_times[key] then
            hover_times[key] = current_time
        end
        if current_time - hover_times[key]
            >= (delay or CONFIG.DEFAULT_TOOLTIP_DELAY)
        then
            ImGui.BeginTooltip(ctx)
            ImGui.Text(ctx, text)
            ImGui.EndTooltip(ctx)
        end
    else
        hover_times[key] = nil
    end
end

local function draw_settings_popup()
    if not ImGui.BeginPopup(ctx, "Settings") then
        return
    end

    ImGui.PushFont(ctx, font)

    ImGui.Text(ctx, "Time Format:")
    handle_delayed_tooltip(
        "time_format_tooltip",
        "Choose how time is displayed"
    )
    ImGui.Spacing(ctx)

    local changed
    changed, settings.format_mode =
        ImGui.RadioButtonEx(ctx, "Hours", settings.format_mode, 2)
    if changed then
        settings_dirty = true
        refresh_timer_cache(true)
    end

    ImGui.SameLine(ctx)
    changed, settings.format_mode =
        ImGui.RadioButtonEx(ctx, "Days", settings.format_mode, 1)
    if changed then
        settings_dirty = true
        refresh_timer_cache(true)
    end

    ImGui.SameLine(ctx)
    changed, settings.format_mode =
        ImGui.RadioButtonEx(ctx, "Weeks", settings.format_mode, 3)
    if changed then
        settings_dirty = true
        refresh_timer_cache(true)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "Initial State:")
    ImGui.Spacing(ctx)

    local initial_state = settings.initial_paused and 1 or 0
    local start_paused_clicked
    start_paused_clicked, initial_state =
        ImGui.RadioButtonEx(ctx, "Start Paused", initial_state, 1)
    if start_paused_clicked then
        settings.initial_paused = true
        settings_dirty = true
    end

    ImGui.SameLine(ctx)
    local start_running_clicked
    start_running_clicked, initial_state =
        ImGui.RadioButtonEx(ctx, "Start Running", initial_state, 0)
    if start_running_clicked then
        settings.initial_paused = false
        settings_dirty = true
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "AFK Detection:")
    ImGui.SameLine(ctx)
    changed, settings.afk_enabled =
        ImGui.Checkbox(ctx, "##afk_enabled", settings.afk_enabled)
    if changed then
        settings_dirty = true
        settings.last_action_time = reaper.time_precise()
    end
    handle_delayed_tooltip(
        "afk_enabled_tooltip",
        "Enable or disable AFK detection"
    )

    if settings.afk_enabled then
        ImGui.Spacing(ctx)
        ImGui.PushItemWidth(ctx, 80)
        changed, settings.afk_threshold = ImGui.InputInt(
            ctx,
            "in minutes##afk",
            settings.afk_threshold,
            1,
            5
        )
        if changed then
            settings.afk_threshold = clamp(
                settings.afk_threshold,
                1,
                CONFIG.MAX_AFK_THRESHOLD
            )
            settings.last_action_time = reaper.time_precise()
            settings_dirty = true
        end
        handle_delayed_tooltip(
            "afk_input_tooltip",
            "AFK threshold in minutes (maximum: 60)"
        )
        ImGui.PopItemWidth(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "Font Size:")
    ImGui.PushItemWidth(ctx, 100)
    local changed_font, new_font_size = ImGui.SliderInt(
        ctx,
        "##font_size",
        settings.font_size,
        CONFIG.MIN_FONT_SIZE,
        CONFIG.MAX_FONT_SIZE
    )
    ImGui.PopItemWidth(ctx)

    if changed_font then
        settings.font_size = new_font_size
        settings_dirty = true
    end

    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
        font_update_pending = true
    end

    handle_delayed_tooltip(
        "font_size_tooltip",
        "Adjust font size ("
            .. CONFIG.MIN_FONT_SIZE
            .. "-"
            .. CONFIG.MAX_FONT_SIZE
            .. ")"
    )

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if ImGui.Button(ctx, "Close") then
        ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
end

local function draw_time_offset_popup()
    if not ImGui.BeginPopup(ctx, "Time Offset") then
        return
    end

    ImGui.PushFont(ctx, font)

    local target_name =
        settings.transport_mode_active and "transport timer" or "project timer"
    ImGui.Text(ctx, "Adjust " .. target_name .. ":")

    local input_width = 80

    local function offset_input(label, value)
        ImGui.PushItemWidth(ctx, input_width)
        local changed, new_value = ImGui.InputInt(ctx, label, value)
        ImGui.PopItemWidth(ctx)

        if ImGui.IsItemActive(ctx)
            and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
        then
            apply_offset()
            ImGui.CloseCurrentPopup(ctx)
        end

        return changed, new_value
    end

    local changed
    changed, settings.time_offset.weeks =
        offset_input("Weeks", settings.time_offset.weeks)
    changed, settings.time_offset.days =
        offset_input("Days", settings.time_offset.days)
    changed, settings.time_offset.hours =
        offset_input("Hours", settings.time_offset.hours)
    changed, settings.time_offset.minutes =
        offset_input("Minutes", settings.time_offset.minutes)

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, "Apply") then
        apply_offset()
        ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then
        settings.time_offset = {
            weeks = 0,
            days = 0,
            hours = 0,
            minutes = 0
        }
        ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
end

local function draw_main_window(current_time)
    if window_position_pending then
        ImGui.SetNextWindowPos(
            ctx,
            settings.window_pos_x,
            settings.window_pos_y,
            ImGui.Cond_Always
        )
    end

    local visible, open = ImGui.Begin(ctx, "Timer", true, WindowFlags)
    window_position_pending = false

    if visible then
        ImGui.PushFont(ctx, font)

        local window_pos_x, window_pos_y = ImGui.GetWindowPos(ctx)
        if math.abs(window_pos_x - settings.window_pos_x) > 0.5
            or math.abs(window_pos_y - settings.window_pos_y) > 0.5
        then
            settings.window_pos_x = window_pos_x
            settings.window_pos_y = window_pos_y
            settings_dirty = true
        end

        ImGui.AlignTextToFramePadding(ctx)
        refresh_timer_cache(false)

        local timer_display = settings.transport_mode_active
                and (format_time(settings.transport_timer) .. " [T]")
            or settings.cache.formatted_string
        ImGui.Text(ctx, timer_display)

        if ImGui.IsWindowFocused(ctx)
            and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
        then
            open = false
        end

        handle_delayed_tooltip(
            "timer_display_tooltip",
            settings.transport_mode_active
                and "Time accumulated while REAPER is playing or recording"
                or "Current project work timer"
        )

        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, settings.collapsed and "+" or "-") then
            settings.collapsed = not settings.collapsed
        end

        if not settings.collapsed then
            ImGui.Spacing(ctx)

            -- Match the buttons to the compact timer-and-toggle row. The
            -- Transport label supplies a small minimum if it is wider.
            local frame_padding_x =
                ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
            local item_spacing_x =
                ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
            local compact_row_width =
                ImGui.CalcTextSize(ctx, timer_display)
                + item_spacing_x
                + ImGui.CalcTextSize(ctx, "-")
                + frame_padding_x * 2
            local transport_width =
                ImGui.CalcTextSize(ctx, "Transport") + frame_padding_x * 2
            local button_width =
                math.ceil(math.max(compact_row_width, transport_width))

            if not settings.transport_mode_active then
                if ImGui.Button(
                    ctx,
                    settings.paused and "Start" or "Pause",
                    button_width,
                    0
                ) then
                    settings.paused = not settings.paused
                    settings.last_action_time = current_time
                    settings_dirty = true
                end
            end

            if ImGui.Button(ctx, "Transport", button_width, 0) then
                settings.transport_mode_active =
                    not settings.transport_mode_active
                settings_dirty = true
            end
            handle_delayed_tooltip(
                "transport_toggle_tooltip",
                "Show and run the timer only while REAPER plays or records"
            )

            if ImGui.Button(ctx, "Offset", button_width, 0) then
                ImGui.OpenPopup(ctx, "Time Offset")
            end

            if ImGui.Button(ctx, "Settings", button_width, 0) then
                ImGui.OpenPopup(ctx, "Settings")
            end

            if ImGui.Button(ctx, "Reset", button_width, 0) then
                if settings.transport_mode_active then
                    settings.transport_timer = 0
                else
                    settings.timer = 0
                    settings.last_action_time = current_time
                    refresh_timer_cache(true)
                end
                settings_dirty = true
            end
            handle_delayed_tooltip(
                "reset_tooltip",
                "Reset only the timer currently shown"
            )

        end

        draw_settings_popup()
        draw_time_offset_popup()

        ImGui.PopFont(ctx)
        ImGui.End(ctx)
    end

    return open
end

local function advance_timers(
    dt,
    current_time,
    play_state,
    project_changed
)
    if project_changed then
        settings.last_action_time = current_time
    end

    if not settings.paused and dt > 0 then
        local user_active =
            project_changed or check_user_activity(current_time, play_state)

        if user_active then
            settings.last_action_time = current_time
        end

        local active_dt = dt
        if settings.afk_enabled and not user_active then
            local threshold_seconds = settings.afk_threshold * 60
            local active_until =
                settings.last_action_time + threshold_seconds
            local frame_start = current_time - dt
            active_dt = clamp(active_until - frame_start, 0, dt)
        end

        if active_dt > 0 then
            settings.timer = settings.timer + active_dt
            settings_dirty = true
        end
    end

    local transport_running = (play_state & 1) ~= 0
    if settings.transport_mode_active and transport_running and dt > 0 then
        settings.transport_timer = settings.transport_timer + dt
        settings_dirty = true
    end

    refresh_timer_cache(false)
end

local function main()
    local current_time = reaper.time_precise()
    local active_project = get_active_project()
    switch_project(active_project, current_time)

    if not current_project then
        reaper.defer(main)
        return
    end

    apply_font_update()

    local play_state = reaper.GetPlayStateEx(current_project)
    local proj_change_count =
        reaper.GetProjectStateChangeCount(current_project)
    local project_changed =
        proj_change_count ~= settings.prev_proj_change_count

    local raw_dt = current_time - settings.last_time
    local dt = clamp(raw_dt, 0, CONFIG.MAX_FRAME_DELTA)
    settings.last_time = current_time

    advance_timers(dt, current_time, play_state, project_changed)
    settings.prev_proj_change_count = proj_change_count

    local open = draw_main_window(current_time)

    if settings_dirty
        and current_time - settings.last_save_time
            >= CONFIG.AUTO_SAVE_INTERVAL
    then
        if store_settings(current_project) then
            settings.last_save_time = current_time

            -- Ignore project-state changes caused by our own extstate writes.
            settings.prev_proj_change_count =
                reaper.GetProjectStateChangeCount(current_project)
        end
    end

    if open then
        reaper.defer(main)
    end
end

current_project = get_active_project()
if current_project then
    restore_settings(current_project, reaper.time_precise())
end

reaper.atexit(cleanup)
reaper.defer(main)
