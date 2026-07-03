--[[
Insert Tool
Requires: ReaImGui
-- @author Alejandro (Alu) 
--]]

math.randomseed(os.time())

local ctx = reaper.ImGui_CreateContext('Insert Tool')

-- ========================
-- PERSISTENCE
-- ========================
local function load(key, default)
    local val = reaper.GetExtState("INSERT_TOOL", key)
    if val == "" then return default end
    if val == "true" then return true end
    if val == "false" then return false end
    return tonumber(val) or val
end

local function save(key, val)
    reaper.SetExtState("INSERT_TOOL", key, tostring(val), true)
end

-- ========================
-- STATE
-- ========================
local hours   = load("hours", "00")
local minutes = load("minutes", "00")
local seconds = load("seconds", "05")
local frames  = load("frames", "00")
local beats_bars = load("beats_bars", "1")
local beats_beats = load("beats_beats", "0")
local mode = load("mode", 0)
local snap = load("snap", true)
local insert_region = load("region", false)
local auto_reset_counter = load("autoreset", true)
local append_track_name = load("trackname", false)
local name_prefix = load("prefix", "Cue")
local counter = load("counter", 1)

-- Auto-sync FPS from project
local function get_project_fps()
    local fps_val, dropFrame = reaper.TimeMap_curFrameRate(0)
    return math.floor(fps_val + 0.5)
end

-- Get project time signature
local function get_time_signature()
    local tempo, num, den, beat = reaper.TimeMap_GetTimeSigAtTime(0, reaper.GetCursorPosition())
    return num, den
end

-- ========================
-- HELPERS
-- ========================
local function timecode_to_seconds(h, m, s, f, fps)
    h = tonumber(h) or 0
    m = tonumber(m) or 0
    s = tonumber(s) or 0
    f = tonumber(f) or 0
    fps = tonumber(fps) or get_project_fps()
    return h * 3600 + m * 60 + s + (f / fps)
end

-- Tempo-map aware beats from bars+beats
local function bars_beats_to_seconds(bars, beats)
    bars = tonumber(bars) or 0
    beats = tonumber(beats) or 0
    if not bars or not beats then return nil end

    local num, den = get_time_signature()
    local total_beats = (bars * num) + beats
    
    local start_time = reaper.GetCursorPosition()
    local end_time = reaper.TimeMap2_beatsToTime(0, total_beats + reaper.TimeMap2_timeToBeats(0, start_time))

    return end_time - start_time
end

-- Razor Edit detection
local function get_razor_range()
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then return nil end

    local _, area = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    if area == "" then return nil end

    local start_pos, end_pos = area:match("([%d%.]+) ([%d%.]+)")
    return tonumber(start_pos), tonumber(end_pos)
end

-- Priority: Razor > Time Selection > Cursor
local function get_insert_range(length_sec)
    local r_start, r_end = get_razor_range()
    if r_start and r_end then return r_start, r_end end

    local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if ts_end > ts_start then return ts_start, ts_end end

    local cur = reaper.GetCursorPosition()
    return cur, cur + length_sec
end

-- Get track name
local function get_track_name(tr)
    if not tr then return "" end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    return name
end

-- Check if there is any item or region at or before the insert position
local function has_item_or_region_before(track, pos)
    if track then
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                if item_pos < pos then
                    return true
                end
            end
        end
    end

    local num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, rgn_pos, rgn_end, rgn_name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval and isrgn and rgn_pos < pos then
            return true
        end
    end

    return false
end

-- Auto naming
local function next_name(track, pos)
    if auto_reset_counter and not has_item_or_region_before(track, pos) then
        counter = 1
    end
    local track_name = get_track_name(track)
    local name
    if append_track_name and track_name ~= "" then
        name = string.format("%s_%s_%02d", name_prefix, track_name, counter)
    else
        name = string.format("%s_%02d", name_prefix, counter)
    end
    counter = counter + 1
    save("counter", counter)
    return name
end

-- Random color
local function random_color()
    local r = math.random(50, 255)
    local g = math.random(50, 255)
    local b = math.random(50, 255)
    return reaper.ColorToNative(r, g, b) + 0x1000000
end

-- ========================
-- INPUT CLAMPING
-- ========================
local function clamp_numeric(val, min_val, max_val)
    local num = tonumber(val)
    if not num then return string.format("%02d", min_val) end
    if num < min_val then num = min_val end
    if num > max_val then num = max_val end
    return string.format("%02d", num)
end

local function validate_timecode_field(current_val, min_val, max_val)
    return clamp_numeric(current_val, min_val, max_val)
end

-- INSERT FUNCTION
local function insert(length_sec)
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
        reaper.ShowMessageBox("Select a track first", "Error", 0)
        return
    end

    local start_pos, end_pos = get_insert_range(length_sec)

    if snap then
        start_pos = reaper.SnapToGrid(0, start_pos)
        end_pos = reaper.SnapToGrid(0, end_pos)
    end

    reaper.Undo_BeginBlock()

    if insert_region then
        reaper.AddProjectMarker2(0, true, start_pos, end_pos, next_name(track, start_pos), -1, 0)
    else
        local item = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemPosition(item, start_pos, false)
        reaper.SetMediaItemLength(item, end_pos - start_pos, false)

        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", random_color())

        local take = reaper.AddTakeToMediaItem(item)
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

-- ========================
-- GUI
-- ========================
local function draw()
    local window_flags = reaper.ImGui_WindowFlags_NoResize()
    if reaper.ImGui_WindowFlags_AlwaysAutoResize then
        window_flags = window_flags + reaper.ImGui_WindowFlags_AlwaysAutoResize()
    end

    local visible, open = reaper.ImGui_Begin(ctx, 'Insert Tool', true, window_flags)

    if visible then
        if reaper.ImGui_RadioButton(ctx, "Timecode", mode == 0) then mode = 0 end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_RadioButton(ctx, "Beats", mode == 1) then mode = 1 end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Dummy(ctx, 0, 4)

        if mode == 0 then
            reaper.ImGui_Text(ctx, "Length")

            local input_width = 35
            local spacing = 4
            local fps = get_project_fps()
            local input_flags = reaper.ImGui_InputTextFlags_CharsDecimal() + reaper.ImGui_InputTextFlags_EnterReturnsTrue()

            reaper.ImGui_PushItemWidth(ctx, input_width)

            -- HOURS
            if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0) then
                reaper.ImGui_SetKeyboardFocusHere(ctx, -1)
            end
            local changed_h, new_h = reaper.ImGui_InputText(ctx, "##hours", hours, input_flags)
            if changed_h then hours = new_h end
            if reaper.ImGui_IsItemActivated(ctx) then
                reaper.ImGui_SetKeyboardFocusHere(ctx, -1)
            end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if hours == "" then hours = "00" end
                hours = validate_timecode_field(hours, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- MINUTES
            local changed_m, new_m = reaper.ImGui_InputText(ctx, "##minutes", minutes, input_flags)
            if changed_m then minutes = new_m end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if minutes == "" then minutes = "00" end
                minutes = validate_timecode_field(minutes, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- SECONDS
            local changed_s, new_s = reaper.ImGui_InputText(ctx, "##seconds", seconds, input_flags)
            if changed_s then seconds = new_s end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if seconds == "" then seconds = "00" end
                seconds = validate_timecode_field(seconds, 0, 99)
            end
            reaper.ImGui_SameLine(ctx, 0, spacing)
            reaper.ImGui_Text(ctx, ":")
            reaper.ImGui_SameLine(ctx, 0, spacing)

            -- FRAMES
            local changed_f, new_f = reaper.ImGui_InputText(ctx, "##frames", frames, input_flags)
            if changed_f then frames = new_f end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if frames == "" then frames = "00" end
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
        else
            -- Beats mode with bars + beats
            local num, den = get_time_signature()
            
            reaper.ImGui_Text(ctx, "Time Signature: " .. num .. "/" .. den)
            reaper.ImGui_Dummy(ctx, 0, 4)

            local input_width = 50
            local input_flags = reaper.ImGui_InputTextFlags_CharsDecimal() + reaper.ImGui_InputTextFlags_EnterReturnsTrue()
            
            reaper.ImGui_PushItemWidth(ctx, input_width)
            
            -- BARS
            reaper.ImGui_Text(ctx, "Bars")
            local changed_bb, new_bb = reaper.ImGui_InputText(ctx, "##beats_bars", beats_bars, input_flags)
            if changed_bb then beats_bars = new_bb end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if beats_bars == "" then beats_bars = "00" end
                beats_bars = validate_timecode_field(beats_bars, 0, 99)
            end
            
            reaper.ImGui_SameLine(ctx, 0, 16)
            
            -- BEATS
            reaper.ImGui_Text(ctx, "Beats")
            local changed_bbt, new_bbt = reaper.ImGui_InputText(ctx, "##beats_beats", beats_beats, input_flags)
            if changed_bbt then beats_beats = new_bbt end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                if beats_beats == "" then beats_beats = "00" end
                beats_beats = validate_timecode_field(beats_beats, 0, num - 1)
            end
            
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_Dummy(ctx, 0, 4)
        end

        reaper.ImGui_Dummy(ctx, 0, 4)

        retval, insert_region = reaper.ImGui_Checkbox(ctx, "Region Mode", insert_region)
        reaper.ImGui_SameLine(ctx, 0, 16)
        retval, snap = reaper.ImGui_Checkbox(ctx, "Snap", snap)

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
        local gap = (avail - total_btn_width) / (btn_count - 1)

        if reaper.ImGui_Button(ctx, "1 Bar", btn_width, 0) then 
            if mode == 1 then
                beats_bars = "01"
                beats_beats = "00"
            end
            insert(beats_to_seconds(4)) 
        end
        reaper.ImGui_SameLine(ctx, 0, gap)
        if reaper.ImGui_Button(ctx, "2 Bars", btn_width, 0) then 
            if mode == 1 then
                beats_bars = "02"
                beats_beats = "00"
            end
            insert(beats_to_seconds(8)) 
        end
        reaper.ImGui_SameLine(ctx, 0, gap)
        if reaper.ImGui_Button(ctx, "4 Bars", btn_width, 0) then 
            if mode == 1 then
                beats_bars = "04"
                beats_beats = "00"
            end
            insert(beats_to_seconds(16)) 
        end

        avail = reaper.ImGui_GetContentRegionAvail(ctx)
        btn_count = 3
        btn_width = 60
        total_btn_width = btn_width * btn_count
        gap = (avail - total_btn_width) / (btn_count - 1)

        if reaper.ImGui_Button(ctx, "1 sec", btn_width, 0) then insert(1) end
        reaper.ImGui_SameLine(ctx, 0, gap)
        if reaper.ImGui_Button(ctx, "2 sec", btn_width, 0) then insert(2) end
        reaper.ImGui_SameLine(ctx, 0, gap)
        if reaper.ImGui_Button(ctx, "5 sec", btn_width, 0) then insert(5) end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Dummy(ctx, 0, 4)

        local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        local button_width = 80
        reaper.ImGui_SetCursorPosX(ctx, (avail_width - button_width) * 0.5)
        if reaper.ImGui_Button(ctx, "INSERT", button_width, 0) then
            -- Validate all fields before insert
            if mode == 0 then
                local fps = get_project_fps()
                if hours == "" then hours = "00" end
                if minutes == "" then minutes = "00" end
                if seconds == "" then seconds = "00" end
                if frames == "" then frames = "00" end
                hours   = validate_timecode_field(hours, 0, 99)
                minutes = validate_timecode_field(minutes, 0, 99)
                seconds = validate_timecode_field(seconds, 0, 99)
                frames  = validate_timecode_field(frames, 0, fps - 1)
            else
                local num, den = get_time_signature()
                if beats_bars == "" then beats_bars = "00" end
                if beats_beats == "" then beats_beats = "00" end
                beats_bars = validate_timecode_field(beats_bars, 0, 99)
                beats_beats = validate_timecode_field(beats_beats, 0, num - 1)
            end

            local length_sec = nil
            if mode == 0 then
                length_sec = timecode_to_seconds(hours, minutes, seconds, frames, get_project_fps())
            else
                length_sec = bars_beats_to_seconds(beats_bars, beats_beats)
            end

            if not length_sec then
                reaper.ShowMessageBox("Invalid input", "Error", 0)
            else
                insert(length_sec)
            end
        end

        -- Save state
        save("hours", hours)
        save("minutes", minutes)
        save("seconds", seconds)
        save("frames", frames)
        save("beats_bars", beats_bars)
        save("beats_beats", beats_beats)
        save("mode", mode)
        save("snap", snap)
        save("region", insert_region)
        save("autoreset", auto_reset_counter)
        save("trackname", append_track_name)
        save("prefix", name_prefix)

        reaper.ImGui_End(ctx)
    end

    if open then
        reaper.defer(draw)
    end
end

reaper.defer(draw)
