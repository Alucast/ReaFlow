--[[
Insert Tool
Requires: ReaImGui
-- @author Alejandro (Alu) 
-- Modified: Timecode only; default MIDI item; toggle to audio; empty prefix remembered; leading zeros preserved; empty fields default to "00"; compact minimized layout with right-aligned toggle; title bar removed; minimize button vertically centered; buttons centered in minimized view; minimize button fixed in expanded view; header text added; tighter minimized window; minimize button aligned to right edge in expanded view; minimized buttons horizontally centered with window padding compensation
--]]

math.randomseed(os.time())

local ctx = reaper.ImGui_CreateContext('Insert Tool')

-- ========================
-- PERSISTENCE
-- ========================
local EMPTY_SENTINEL = "__ALU_EMPTY__"

local function load(key, default)
    local val = reaper.GetExtState("INSERT_TOOL", key)
    if val == "" then return default end
    if val == "true" then return true end
    if val == "false" then return false end
    return tonumber(val) or val
end

local function load_string(key, default)
    local val = reaper.GetExtState("INSERT_TOOL", key)
    if val == "" then return default end
    if val == EMPTY_SENTINEL then return "" end
    return val
end

local function save(key, val)
    reaper.SetExtState("INSERT_TOOL", key, tostring(val), true)
end

local function save_string(key, val)
    if val == "" then
        reaper.SetExtState("INSERT_TOOL", key, EMPTY_SENTINEL, true)
    else
        reaper.SetExtState("INSERT_TOOL", key, val, true)
    end
end

-- ========================
-- STATE
-- ========================
local prefix_initialized = load("prefix_initialized", false)
local name_prefix
if not prefix_initialized then
    name_prefix = "Cue"
    save("prefix", name_prefix)
    save("prefix_initialized", true)
else
    name_prefix = load_string("prefix", "")
end

local hours   = load_string("hours", "00")
local minutes = load_string("minutes", "00")
local seconds = load_string("seconds", "00")
local frames  = load_string("frames", "00")

local snap = load("snap", true)
local insert_region = load("region", false)
local auto_reset_counter = load("autoreset", true)
local append_track_name = load("trackname", false)
local counter = load("counter", 1)
local audio_mode = load("audio_mode", false)
local minimized = load("minimized", false)

-- ========================
-- HELPERS
-- ========================
local function get_project_fps()
    local fps_val, dropFrame = reaper.TimeMap_curFrameRate(0)
    return math.floor(fps_val + 0.5)
end

local function timecode_to_seconds(h, m, s, f, fps)
    h = tonumber(h) or 0
    m = tonumber(m) or 0
    s = tonumber(s) or 0
    f = tonumber(f) or 0
    fps = tonumber(fps) or get_project_fps()
    return h * 3600 + m * 60 + s + (f / fps)
end

local function get_razor_range()
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then return nil end
    local _, area = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    if area == "" then return nil end
    local start_pos, end_pos = area:match("([%d%.]+) ([%d%.]+)")
    return tonumber(start_pos), tonumber(end_pos)
end

local function get_insert_range(length_sec)
    local r_start, r_end = get_razor_range()
    if r_start and r_end then return r_start, r_end end
    local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if ts_end > ts_start then return ts_start, ts_end end
    local cur = reaper.GetCursorPosition()
    return cur, cur + length_sec
end

local function get_track_name(tr)
    if not tr then return "" end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    return name
end

local function has_item_or_region_before(track, pos)
    if track then
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                if item_pos < pos then return true end
            end
        end
    end
    local num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, rgn_pos = reaper.EnumProjectMarkers(i)
        if retval and isrgn and rgn_pos < pos then return true end
    end
    return false
end

local function next_name(track, pos)
    if auto_reset_counter and not has_item_or_region_before(track, pos) then
        counter = 1
    end
    local track_name = get_track_name(track)
    local name
    if append_track_name and track_name ~= "" then
        if name_prefix ~= "" then
            name = string.format("%s_%s_%02d", name_prefix, track_name, counter)
        else
            name = string.format("%s_%02d", track_name, counter)
        end
    else
        if name_prefix ~= "" then
            name = string.format("%s_%02d", name_prefix, counter)
        else
            name = string.format("%02d", counter)
        end
    end
    counter = counter + 1
    save("counter", counter)
    return name
end

local function random_color()
    local r = math.random(50, 255)
    local g = math.random(50, 255)
    local b = math.random(50, 255)
    return reaper.ColorToNative(r, g, b) + 0x1000000
end

local function clamp_numeric(val, min_val, max_val)
    if val == "" then return string.format("%02d", min_val) end
    local num = tonumber(val)
    if not num then return string.format("%02d", min_val) end
    if num < min_val then num = min_val end
    if num > max_val then num = max_val end
    return string.format("%02d", num)
end

local function validate_timecode_field(current_val, min_val, max_val)
    return clamp_numeric(current_val, min_val, max_val)
end

local function do_insert(start_pos, end_pos)
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
        reaper.ShowMessageBox("Select a track first", "Error", 0)
        return
    end

    if snap then
        start_pos = reaper.SnapToGrid(0, start_pos)
        end_pos = reaper.SnapToGrid(0, end_pos)
    end

    local length_sec = end_pos - start_pos
    if length_sec <= 0 then return end

    reaper.Undo_BeginBlock()

    if insert_region then
        reaper.AddProjectMarker2(0, true, start_pos, end_pos, next_name(track, start_pos), -1, 0)
    else
        local item
        if audio_mode then
            item = reaper.AddMediaItemToTrack(track)
            reaper.SetMediaItemPosition(item, start_pos, false)
            reaper.SetMediaItemLength(item, length_sec, false)
        else
            item = reaper.CreateNewMIDIItemInProj(track, start_pos, end_pos, false)
        end

        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", random_color())

        local take
        if audio_mode then
            take = reaper.AddTakeToMediaItem(item)
        else
            take = reaper.GetMediaItemTake(item, 0)
        end

        if take then
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", next_name(track, start_pos), true)
        else
            reaper.GetSetMediaItemInfo_String(item, "P_NOTES", next_name(track, start_pos), true)
        end
    end

    reaper.SetEditCurPos(end_pos, true, false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Insert Tool", -1)
end

local function insert(length_sec)
    if not length_sec or length_sec <= 0 then
        reaper.ShowMessageBox("Invalid duration (must be positive)", "Error", 0)
        return
    end
    local start_pos, end_pos = get_insert_range(length_sec)
    do_insert(start_pos, end_pos)
end

-- ========================
-- GUI
-- ========================
local function draw()
    -- Minimized: exact fit around buttons. Expanded: full UI width.
    local insert_width = 80
    local insert_height = 22
    local btn_size = 18
    local gap = 6
    local padding_x = 8
    local padding_y = 8

    local minimized_width = insert_width + gap + btn_size + (padding_x * 2)
    local minimized_height = insert_height + (padding_y * 2)

    local win_width = minimized and minimized_width or 240
    local min_height = minimized and minimized_height or 55
    local max_height = 400

    reaper.ImGui_SetNextWindowSizeConstraints(ctx, win_width, min_height, win_width, max_height)

    -- Remove title bar: NoTitleBar + NoCollapse + NoScrollbar flags
    local window_flags = reaper.ImGui_WindowFlags_NoResize()
                       | reaper.ImGui_WindowFlags_NoTitleBar()
                       | reaper.ImGui_WindowFlags_NoCollapse()
                       | reaper.ImGui_WindowFlags_NoScrollbar()
    if reaper.ImGui_WindowFlags_AlwaysAutoResize then
        window_flags = window_flags | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    end

    local visible, open = reaper.ImGui_Begin(ctx, 'Insert Tool', true, window_flags)

    if visible then
        -- ESC closes the script
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
            open = false
        end

        -- =========================================================
        -- MINIMIZED: centered buttons row, tight window
        -- =========================================================
        if minimized then
            local total_width = insert_width + gap + btn_size

            -- Center using window width (accounts for padding correctly)
            local win_w = reaper.ImGui_GetWindowWidth(ctx)
            local start_x = (win_w - total_width) * 0.5
            reaper.ImGui_SetCursorPosX(ctx, start_x)

            -- INSERT button
            if reaper.ImGui_Button(ctx, "INSERT", insert_width, insert_height) then
                local fps = get_project_fps()
                hours   = validate_timecode_field(hours, 0, 99)
                minutes = validate_timecode_field(minutes, 0, 99)
                seconds = validate_timecode_field(seconds, 0, 99)
                frames  = validate_timecode_field(frames, 0, fps - 1)

                local length_sec = timecode_to_seconds(hours, minutes, seconds, frames, fps)
                insert(length_sec)
            end

            -- Minimize button, vertically centered with INSERT button
            reaper.ImGui_SameLine(ctx, 0, gap)
            local vertical_offset = (insert_height - btn_size) * 0.5
            reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + vertical_offset)
            if reaper.ImGui_Button(ctx, "+", btn_size, btn_size) then
                minimized = not minimized
                save("minimized", minimized)
            end

        -- =========================================================
        -- FULL UI
        -- =========================================================
        else
            -- Header text on the left
            local btn_size = 18
            local header_text = "Insert empty item"
            reaper.ImGui_Text(ctx, header_text)

            -- Minimize button aligned to the far right edge
            reaper.ImGui_SameLine(ctx)
            local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
            reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + avail_width - btn_size)

            if reaper.ImGui_Button(ctx, "-", btn_size, btn_size) then
                minimized = not minimized
                save("minimized", minimized)
            end

            reaper.ImGui_Dummy(ctx, 0, 4)

            reaper.ImGui_Text(ctx, "Length")

            local input_width = 35
            local spacing = 4
            local fps = get_project_fps()
            local input_flags = reaper.ImGui_InputTextFlags_CharsDecimal()

            reaper.ImGui_PushItemWidth(ctx, input_width)

            -- HOURS
            local changed_h, new_h = reaper.ImGui_InputText(ctx, "##hours", hours, input_flags)
            hours = new_h
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                hours = validate_timecode_field(hours, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- MINUTES
            local changed_m, new_m = reaper.ImGui_InputText(ctx, "##minutes", minutes, input_flags)
            minutes = new_m
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                minutes = validate_timecode_field(minutes, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- SECONDS
            local changed_s, new_s = reaper.ImGui_InputText(ctx, "##seconds", seconds, input_flags)
            seconds = new_s
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                seconds = validate_timecode_field(seconds, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- FRAMES
            local changed_f, new_f = reaper.ImGui_InputText(ctx, "##frames", frames, input_flags)
            frames = new_f
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                frames = validate_timecode_field(frames, 0, fps - 1)
            end

            reaper.ImGui_PopItemWidth(ctx)

            -- Labels row
            reaper.ImGui_Dummy(ctx, 0, 2)
            local label_offset = 8
            reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + label_offset)
            reaper.ImGui_Text(ctx, "H")
            reaper.ImGui_SameLine(ctx, 0, 28)
            reaper.ImGui_Text(ctx, "M")
            reaper.ImGui_SameLine(ctx, 0, 28)
            reaper.ImGui_Text(ctx, "S")
            reaper.ImGui_SameLine(ctx, 0, 28)
            reaper.ImGui_Text(ctx, "F")

            reaper.ImGui_Dummy(ctx, 0, 4)
            reaper.ImGui_Text(ctx, "Project FPS: " .. tostring(fps))

            reaper.ImGui_Dummy(ctx, 0, 4)

            retval, insert_region = reaper.ImGui_Checkbox(ctx, "Region Mode", insert_region)
            reaper.ImGui_SameLine(ctx, 0, 16)
            retval, snap = reaper.ImGui_Checkbox(ctx, "Snap", snap)
            reaper.ImGui_SameLine(ctx, 0, 16)
            retval, audio_mode = reaper.ImGui_Checkbox(ctx, "Audio Item", audio_mode)

            reaper.ImGui_Dummy(ctx, 0, 4)
            retval, auto_reset_counter = reaper.ImGui_Checkbox(ctx, "Auto-reset counter", auto_reset_counter)

            reaper.ImGui_Dummy(ctx, 0, 4)

            reaper.ImGui_PushItemWidth(ctx, 80)
            retval, name_prefix = reaper.ImGui_InputText(ctx, "Prefix", name_prefix)
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx, 0, 12)
            retval, append_track_name = reaper.ImGui_Checkbox(ctx, "Track name", append_track_name)

            reaper.ImGui_Dummy(ctx, 0, 4)

            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Text(ctx, "Quick Presets:")
            reaper.ImGui_Dummy(ctx, 0, 4)

            local avail = reaper.ImGui_GetContentRegionAvail(ctx)
            local btn_count = 3
            local btn_width = 60
            local total_btn_width = btn_width * btn_count
            local gap = math.max(4, (avail - total_btn_width) / (btn_count - 1))

            if reaper.ImGui_Button(ctx, "1 sec", btn_width, 0) then insert(1) end
            reaper.ImGui_SameLine(ctx, 0, gap)
            if reaper.ImGui_Button(ctx, "2 sec", btn_width, 0) then insert(2) end
            reaper.ImGui_SameLine(ctx, 0, gap)
            if reaper.ImGui_Button(ctx, "5 sec", btn_width, 0) then insert(5) end

            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Dummy(ctx, 0, 4)

            -- INSERT button (centered)
            local avail_width2 = reaper.ImGui_GetContentRegionAvail(ctx)
            local button_width = 80
            reaper.ImGui_SetCursorPosX(ctx, (avail_width2 - button_width) * 0.5)
            if reaper.ImGui_Button(ctx, "INSERT", button_width, 0) then
                local fps = get_project_fps()
                hours   = validate_timecode_field(hours, 0, 99)
                minutes = validate_timecode_field(minutes, 0, 99)
                seconds = validate_timecode_field(seconds, 0, 99)
                frames  = validate_timecode_field(frames, 0, fps - 1)

                local length_sec = timecode_to_seconds(hours, minutes, seconds, frames, fps)
                insert(length_sec)
            end
        end

        -- Save state
        save_string("hours", hours)
        save_string("minutes", minutes)
        save_string("seconds", seconds)
        save_string("frames", frames)
        save("prefix", name_prefix)
        save("snap", snap)
        save("region", insert_region)
        save("autoreset", auto_reset_counter)
        save("trackname", append_track_name)
        save("audio_mode", audio_mode)
        save("minimized", minimized)

        reaper.ImGui_End(ctx)
    end

    if open then
        reaper.defer(draw)
    end
end

reaper.defer(draw)
