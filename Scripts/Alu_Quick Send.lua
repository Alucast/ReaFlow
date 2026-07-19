-- @description Quick Send
-- @version 3.7
-- @author Alejandro (Alu) 

local ctx = reaper.ImGui_CreateContext('Quick Send Menu')
local history_key = "GEMINI_SEND_GUID_HISTORY"
local favorites_key = "GEMINI_SEND_GUID_FAVORITES"
local input_val = ""
local set_focus_once = true
local cached_source_guids = {}
local cached_current_guid = nil
local preview_results = {}
local should_open_preview = false
local delete_popup_guid = nil
local delete_popup_sources = {}
local delete_popup_selected = {}

-- + button hover state (persisted across frames for custom background drawing)
local plus_btn_hovered = false
local plus_btn_active = false

-- Deduplication: tracks already drawn this frame (prevents ImGui ID conflicts)
local drawn_track_guids = {}

-- Options for receive-track creation
local disableMasterSend = false -- Set to true to disable "Master/Parent Send" on the new receive track
local lightenAmount = 60        -- How much to lighten the new track's color

-- Tooltip delay system
local tooltip_delay = 1.0 -- seconds
local hover_timers = {}
local last_hover_id = nil
local last_frame_time = nil

-- Select the track under the mouse cursor
local function select_track_under_mouse()
    local window, segment, details = reaper.BR_GetMouseCursorContext()
    if segment == "track" then
        local tr = reaper.BR_GetMouseCursorContext_Track()
        if tr then
            reaper.SetOnlyTrackSelected(tr)
            reaper.UpdateArrange()
        end
    end
end

local function get_track_by_guid(guid_str)
    if not guid_str or guid_str == "" then return nil end
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if tr and reaper.GetTrackGUID(tr) == guid_str then return tr end
    end
    return nil
end

local function get_track_name(tr)
    if not tr then return "No track" end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    if name == "" then name = "Track" end
    return string.format("%d: %s", idx, name)
end

local function get_track_name_only(tr)
    if not tr then return "" end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == "" then name = "Track" end
    return name
end

local function get_track_color_u32(tr)
    if not tr then return 0x666666FF end
    local native = reaper.GetTrackColor(tr)
    if not native or native == 0 then return 0x666666FF end
    local r, g, b = reaper.ColorFromNative(native)
    return reaper.ImGui_ColorConvertDouble4ToU32(r / 255, g / 255, b / 255, 1.0)
end

local function draw_color_square(color_u32, size)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
    local frame_h = 20
    local ok, fh = pcall(function() return reaper.ImGui_GetFrameHeight(ctx) end)
    if ok then frame_h = fh end
    local offset_y = math.max(0, (frame_h - size) * 0.5)
    y = y + offset_y
    reaper.ImGui_Dummy(ctx, size, size)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size, color_u32, 2)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + size, y + size, 0x000000FF, 2)
end

local function is_track_rec_armed(tr)
    return tr and reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
end

local function toggle_track_rec_arm(tr)
    if not tr then return end
    local new_state = is_track_rec_armed(tr) and 0 or 1
    reaper.Undo_BeginBlock()
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", new_state)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Toggle record arm", -1)
end

local function is_track_soloed(tr)
    return tr and reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") ~= 0
end

local function toggle_track_solo(tr)
    if not tr then return end
    local new_state = is_track_soloed(tr) and 0 or 1
    reaper.Undo_BeginBlock()
    reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", new_state)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Toggle solo", -1)
end

local function toggle_recording()
    if reaper.GetPlayState() & 4 == 4 then
        reaper.Main_OnCommand(1016, 0) -- Transport: Stop
    else
        reaper.Main_OnCommand(1013, 0) -- Transport: Record
    end
end

local function get_delta_time()
    local now = reaper.time_precise()
    if last_frame_time == nil then
        last_frame_time = now
        return 0
    end
    local dt = now - last_frame_time
    last_frame_time = now
    return dt
end

local function draw_rec_arm_button(tr)
    if not tr then return false end
    local armed = is_track_rec_armed(tr)
    local blink_on = true
    if armed then
        blink_on = math.floor(reaper.time_precise() * 2.8) % 2 == 0
    end
    local bg = armed and (blink_on and 0xE13333FF or 0x5A1F1FFF) or 0x3A3A3AFF
    local hovered = armed and 0xF05050FF or 0x505050FF
    local active = armed and 0xA81F1FFF or 0x2A2A2AFF
    local text = armed and 0xFFFFFFFF or 0xB0B0B0FF

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hovered)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), text)
    local clicked = reaper.ImGui_Button(ctx, "●", 22, 0)
    reaper.ImGui_PopStyleColor(ctx, 4)

    -- Manual delayed tooltip
    local hover_id = "rec_" .. reaper.GetTrackGUID(tr)
    if reaper.ImGui_IsItemHovered(ctx) then
        if last_hover_id ~= hover_id then
            hover_timers = {}
            last_hover_id = hover_id
        end
        hover_timers[hover_id] = (hover_timers[hover_id] or 0) + get_delta_time()
        if hover_timers[hover_id] >= tooltip_delay then
            local shift_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())
            if shift_down then
                reaper.ImGui_SetTooltip(ctx, "Shift+Click to toggle solo")
            else
                local tip = armed and "Disarm record on this track" or "Arm record on this track"
                local rec_tooltip = (reaper.GetPlayState() & 4 == 4) and "Right-click to stop recording" or "Right-click to start recording"
                reaper.ImGui_SetTooltip(ctx, tip .. "\n" .. rec_tooltip)
            end
        end
    elseif last_hover_id == hover_id then
        last_hover_id = nil
        hover_timers = {}
    end

    if clicked then
        local shift_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())
        if shift_down then
            toggle_track_solo(tr)
        else
            toggle_track_rec_arm(tr)
        end
        return true
    end

    if reaper.ImGui_IsItemClicked(ctx, reaper.ImGui_MouseButton_Right()) then
        toggle_recording()
        return true
    end

    return false
end

local function read_guid_list(key)
    local str = reaper.GetExtState("GEMINI_SCRIPTS", key)
    local list = {}
    if str ~= "" then
        for guid in str:gmatch("([^,]+)") do list[#list + 1] = guid end
    end
    return list
end

local function save_guid_list(key, list)
    reaper.SetExtState("GEMINI_SCRIPTS", key, table.concat(list, ","), true)
end

local function get_history() return read_guid_list(history_key) end
local function save_history(history) save_guid_list(history_key, history) end
local function get_favorites() return read_guid_list(favorites_key) end
local function save_favorites(favorites) save_guid_list(favorites_key, favorites) end

local function is_favorite_guid(guid)
    for _, v in ipairs(get_favorites()) do
        if v == guid then return true end
    end
    return false
end

local function toggle_favorite(tr)
    if not tr then return end
    local guid = reaper.GetTrackGUID(tr)
    local favorites = get_favorites()
    for i, v in ipairs(favorites) do
        if v == guid then
            table.remove(favorites, i)
            save_favorites(favorites)
            return
        end
    end
    table.insert(favorites, 1, guid)
    save_favorites(favorites)
end

local function remove_from_history(guid)
    local history = get_history()
    for i, v in ipairs(history) do
        if v == guid then
            table.remove(history, i)
            save_history(history)
            return
        end
    end
end

local function add_to_history(tr)
    if not tr then return end
    local guid = reaper.GetTrackGUID(tr)
    local history = get_history()
    for _, v in ipairs(history) do
        if v == guid then return end
    end
    table.insert(history, 1, guid)
    while #history > 5 do table.remove(history) end
    save_history(history)
end

local function cache_selected_tracks()
    cached_source_guids = {}
    local count = reaper.CountSelectedTracks(0)
    for i = 0, count - 1 do
        local tr = reaper.GetSelectedTrack(0, i)
        if tr then
            cached_source_guids[#cached_source_guids + 1] = reaper.GetTrackGUID(tr)
        end
    end
    local current_tr = reaper.GetSelectedTrack(0, 0)
    cached_current_guid = current_tr and reaper.GetTrackGUID(current_tr) or nil
end

local function get_cached_source_tracks()
    local tracks = {}
    for _, guid in ipairs(cached_source_guids) do
        local tr = get_track_by_guid(guid)
        if tr then tracks[#tracks + 1] = tr end
    end
    return tracks
end

local function track_send_exists(src_tr, dest_tr)
    if not src_tr or not dest_tr then return false end
    local dest_guid = reaper.GetTrackGUID(dest_tr)
    local num_sends = reaper.GetTrackNumSends(src_tr, 0)
    for s = 0, num_sends - 1 do
        local current_dest = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK")
        if current_dest and reaper.ValidatePtr2(0, current_dest, "MediaTrack*") and reaper.GetTrackGUID(current_dest) == dest_guid then
            return true
        end
    end
    return false
end

local function get_send_index(src_tr, dest_tr)
    if not src_tr or not dest_tr then return nil end
    local dest_guid = reaper.GetTrackGUID(dest_tr)
    local num_sends = reaper.GetTrackNumSends(src_tr, 0)
    for s = 0, num_sends - 1 do
        local current_dest = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK")
        if current_dest and reaper.ValidatePtr2(0, current_dest, "MediaTrack*") and reaper.GetTrackGUID(current_dest) == dest_guid then
            return s
        end
    end
    return nil
end

local function get_sending_tracks(dest_tr)
    if not dest_tr then return {} end
    local dest_guid = reaper.GetTrackGUID(dest_tr)
    local sources = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if tr then
            local num_sends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, num_sends - 1 do
                local current_dest = reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK")
                if current_dest and reaper.ValidatePtr2(0, current_dest, "MediaTrack*") and reaper.GetTrackGUID(current_dest) == dest_guid then
                    sources[#sources + 1] = tr
                    break
                end
            end
        end
    end
    return sources
end

local function delete_send_from_to(src_tr, dest_tr)
    if not src_tr or not dest_tr then return end
    local dest_guid = reaper.GetTrackGUID(dest_tr)
    
    reaper.Undo_BeginBlock()
    local num_sends = reaper.GetTrackNumSends(src_tr, 0)
    for s = num_sends - 1, 0, -1 do
        local current_dest = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK")
        if current_dest and reaper.ValidatePtr2(0, current_dest, "MediaTrack*") and reaper.GetTrackGUID(current_dest) == dest_guid then
            reaper.RemoveTrackSend(src_tr, 0, s)
        end
    end
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Delete", -1)
end

local function toggle_send_mute(src_tr, dest_tr)
    if not src_tr or not dest_tr then return end
    local send_idx = get_send_index(src_tr, dest_tr)
    if send_idx == nil then return end
    
    local current_mute = reaper.GetTrackSendInfo_Value(src_tr, 0, send_idx, "B_MUTE")
    local new_mute = current_mute == 0 and 1 or 0
    
    reaper.Undo_BeginBlock()
    reaper.SetTrackSendInfo_Value(src_tr, 0, send_idx, "B_MUTE", new_mute)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Toggle send mute", -1)
end

local function is_send_muted(src_tr, dest_tr)
    if not src_tr or not dest_tr then return false end
    local send_idx = get_send_index(src_tr, dest_tr)
    if send_idx == nil then return false end
    return reaper.GetTrackSendInfo_Value(src_tr, 0, send_idx, "B_MUTE") == 1
end

local function toggle_send_pre_post(src_tr, dest_tr)
    if not src_tr or not dest_tr then return end
    local send_idx = get_send_index(src_tr, dest_tr)
    if send_idx == nil then return end
    
    local current_mode = reaper.GetTrackSendInfo_Value(src_tr, 0, send_idx, "I_SENDMODE")
    local new_mode = current_mode == 0 and 1 or 0
    
    reaper.Undo_BeginBlock()
    reaper.SetTrackSendInfo_Value(src_tr, 0, send_idx, "I_SENDMODE", new_mode)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Toggle pre/post fader", -1)
end

local function get_send_mode_str(src_tr, dest_tr)
    if not src_tr or not dest_tr then return "" end
    local send_idx = get_send_index(src_tr, dest_tr)
    if send_idx == nil then return "" end
    local mode = reaper.GetTrackSendInfo_Value(src_tr, 0, send_idx, "I_SENDMODE")
    if mode == 0 then return "Post-fader"
    elseif mode == 1 then return "Pre-fader"
    elseif mode == 2 then return "Pre-FX"
    else return "Unknown" end
end

local function create_send_to(dest_tr)
    if not dest_tr then return end
    local src_tracks = get_cached_source_tracks()
    if #src_tracks == 0 then return end
    local dest_guid = reaper.GetTrackGUID(dest_tr)

    reaper.Undo_BeginBlock()
    for _, src_tr in ipairs(src_tracks) do
        if reaper.GetTrackGUID(src_tr) ~= dest_guid and not track_send_exists(src_tr, dest_tr) then
            reaper.CreateTrackSend(src_tr, dest_tr)
        end
    end
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Create", -1)
    add_to_history(dest_tr)
    input_val = ""
    should_open_preview = false
end

local function delete_send_to(dest_tr)
    if not dest_tr then return end
    local dest_guid = reaper.GetTrackGUID(dest_tr)
    
    local src_tracks = get_cached_source_tracks()
    local valid_sources = {}
    
    for _, src_tr in ipairs(src_tracks) do
        if track_send_exists(src_tr, dest_tr) then
            valid_sources[#valid_sources + 1] = src_tr
        end
    end
    
    if #valid_sources == 1 then
        delete_send_from_to(valid_sources[1], dest_tr)
    elseif #valid_sources > 1 then
        delete_popup_guid = dest_guid
        delete_popup_sources = valid_sources
        delete_popup_selected = {}
        for i = 1, #valid_sources do delete_popup_selected[i] = false end
    else
        local sending_tracks = get_sending_tracks(dest_tr)
        
        if #sending_tracks == 0 then
            return
        elseif #sending_tracks == 1 then
            delete_send_from_to(sending_tracks[1], dest_tr)
        else
            delete_popup_guid = dest_guid
            delete_popup_sources = sending_tracks
            delete_popup_selected = {}
            for i = 1, #sending_tracks do delete_popup_selected[i] = false end
        end
    end
end

local function go_to_track(tr)
    if not tr then return end
    reaper.SetOnlyTrackSelected(tr)
    reaper.Main_OnCommand(40913, 0)
    reaper.Main_OnCommand(40914, 0)
end

local function normalize_query(s)
    return (s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function find_tracks_matching_query(query)
    local results = {}
    local q = normalize_query(query)
    if q == "" then return results end

    local num = tonumber(q)
    if num then
        local tr = reaper.GetTrack(0, math.floor(num) - 1)
        if tr then results[#results + 1] = tr end
        return results
    end

    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local hay = (get_track_name_only(tr) .. " " .. tostring(i + 1)):lower()
        if hay:find(q, 1, true) then
            results[#results + 1] = tr
            if #results >= 8 then break end
        end
    end
    return results
end

local function send_from_input()
    local matches = find_tracks_matching_query(input_val)
    if #matches >= 1 then
        create_send_to(matches[1])
    end
end

-- ============================================================
-- Create receive track from selected tracks
-- ============================================================
local function create_receive_track(arm_recording)
    local src_tracks = get_cached_source_tracks()
    if #src_tracks == 0 then return end

    local first_tr = src_tracks[1]
    local firstTrackIndex = math.floor(reaper.GetMediaTrackInfo_Value(first_tr, "IP_TRACKNUMBER")) - 1

    -- Name
    local retval, trackName = reaper.GetSetMediaTrackInfo_String(first_tr, 'P_NAME', '', false)
    local destTrackName = "send"
    if retval and trackName ~= '' then
        destTrackName = trackName .. " send"
    end

    -- Default send settings from REAPER preferences
    local defsendvol_str = ({reaper.BR_Win32_GetPrivateProfileString('REAPER', 'defsendvol', '0', reaper.get_ini_file())})[2]
    local defsendflag_str = ({reaper.BR_Win32_GetPrivateProfileString('REAPER', 'defsendflag', '0', reaper.get_ini_file())})[2]
    local defsendvol = tonumber(defsendvol_str) or 1.0
    local defsendflag = tonumber(defsendflag_str) or 0

    reaper.Undo_BeginBlock()

    -- Insert new track below the first selected track
    reaper.InsertTrackAtIndex(firstTrackIndex + 1, true)
    local new_dest_tr = reaper.GetTrack(0, firstTrackIndex + 1)

    -- Arm only if requested (right-click)
    if arm_recording then
        reaper.SetMediaTrackInfo_Value(new_dest_tr, 'I_RECARM', 1)
    end
    -- Set to record output (stereo)
    reaper.SetMediaTrackInfo_Value(new_dest_tr, 'I_RECMODE', 3)
    -- No hardware input
    reaper.SetMediaTrackInfo_Value(new_dest_tr, 'I_RECINPUT', -1)

    -- Name it
    reaper.GetSetMediaTrackInfo_String(new_dest_tr, 'P_NAME', destTrackName, true)

    -- Lighten the source track's color
    local originalColor = reaper.GetTrackColor(first_tr)
    if originalColor and originalColor ~= 0 then
        local r, g, b = reaper.ColorFromNative(originalColor)
        r = math.min(r + lightenAmount, 255)
        g = math.min(g + lightenAmount, 255)
        b = math.min(b + lightenAmount, 255)
        local newColor = reaper.ColorToNative(r, g, b) | 0x1000000
        reaper.SetTrackColor(new_dest_tr, newColor)
    end

    -- Optional: disable Master/Parent Send
    if disableMasterSend then
        reaper.SetMediaTrackInfo_Value(new_dest_tr, 'B_MAINSEND', 0)
    end

    -- Create sends from all selected tracks
    for _, tr in ipairs(src_tracks) do
        local new_send_id = reaper.CreateTrackSend(tr, new_dest_tr)
        if new_send_id >= 0 then
            reaper.SetTrackSendInfo_Value(tr, 0, new_send_id, 'D_VOL', defsendvol)
            reaper.SetTrackSendInfo_Value(tr, 0, new_send_id, 'I_SENDMODE', defsendflag)
        end
    end

    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Create receive track", -1)

    -- Add the new track to history so it appears in Recent
    add_to_history(new_dest_tr)
end
-- ============================================================

local function draw_track_context_menu(tr, show_remove_history)
    if not tr then return end
    if reaper.ImGui_BeginPopupContextItem(ctx, "row_menu") then
        local is_fav = is_favorite_guid(reaper.GetTrackGUID(tr))
        if reaper.ImGui_MenuItem(ctx, is_fav and "Remove from favorites" or "Add to favorites") then
            toggle_favorite(tr)
        end
        if show_remove_history then
            if reaper.ImGui_MenuItem(ctx, "Remove from history") then
                remove_from_history(reaper.GetTrackGUID(tr))
            end
        end
        
        -- Send mute toggle (only if a send exists from selected tracks)
        local src_tracks = get_cached_source_tracks()
        local has_send = false
        local is_muted = false
        for _, src_tr in ipairs(src_tracks) do
            if track_send_exists(src_tr, tr) then
                has_send = true
                if is_send_muted(src_tr, tr) then
                    is_muted = true
                end
            end
        end
        
        if has_send then
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_MenuItem(ctx, is_muted and "Unmute send" or "Mute send") then
                for _, src_tr in ipairs(src_tracks) do
                    if track_send_exists(src_tr, tr) then
                        toggle_send_mute(src_tr, tr)
                    end
                end
            end
            
            -- Pre/post fader toggle
            local mode_str = ""
            for _, src_tr in ipairs(src_tracks) do
                if track_send_exists(src_tr, tr) then
                    mode_str = get_send_mode_str(src_tr, tr)
                    break
                end
            end
            if reaper.ImGui_MenuItem(ctx, "Toggle pre/post (" .. mode_str .. ")") then
                for _, src_tr in ipairs(src_tracks) do
                    if track_send_exists(src_tr, tr) then
                        toggle_send_pre_post(src_tr, tr)
                    end
                end
            end
        end
        
        reaper.ImGui_EndPopup(ctx)
    end
end

local function draw_track_row(tr, button_width, show_remove_history)
    if not tr then return end
    local guid = reaper.GetTrackGUID(tr)
    
    -- Deduplicate: skip if this track was already drawn this frame
    if drawn_track_guids[guid] then return end
    drawn_track_guids[guid] = true
    
    reaper.ImGui_PushID(ctx, guid)
    draw_color_square(get_track_color_u32(tr), 14)
    reaper.ImGui_SameLine(ctx)
    
    -- Check if Ctrl is held for removal mode
    local ctrl_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
    local can_remove = ctrl_down and (is_favorite_guid(guid) or show_remove_history)
    
    -- Track name button with conditional red styling when Ctrl+hover for removal
    if can_remove then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x5A1F1FFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xE13333FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xA81F1FFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    end
    
    if reaper.ImGui_Button(ctx, get_track_name(tr), button_width, 0) then
        if ctrl_down then
            if is_favorite_guid(guid) then
                toggle_favorite(tr)
            elseif show_remove_history then
                remove_from_history(guid)
            end
        else
            create_send_to(tr)
        end
    end
    
    if can_remove then
        reaper.ImGui_PopStyleColor(ctx, 4)
    end
    
    -- Middle-click to go to track
    if reaper.ImGui_IsItemClicked(ctx, reaper.ImGui_MouseButton_Middle()) then
        go_to_track(tr)
    end
    
    -- Delayed tooltip with send info
    local hover_id = "track_" .. guid
    if reaper.ImGui_IsItemHovered(ctx) then
        if last_hover_id ~= hover_id then
            hover_timers = {}
            last_hover_id = hover_id
        end
        hover_timers[hover_id] = (hover_timers[hover_id] or 0) + get_delta_time()
        if hover_timers[hover_id] >= tooltip_delay then
            local src_tracks = get_cached_source_tracks()
            local tooltip_lines = {}
            for _, src_tr in ipairs(src_tracks) do
                if track_send_exists(src_tr, tr) then
                    local send_idx = get_send_index(src_tr, tr)
                    local vol = reaper.GetTrackSendInfo_Value(src_tr, 0, send_idx, "D_VOL")
                    local db = 20 * math.log(vol, 10)
                    local mode = get_send_mode_str(src_tr, tr)
                    local muted = is_send_muted(src_tr, tr) and " [MUTED]" or ""
                    table.insert(tooltip_lines, get_track_name(src_tr) .. " → " .. string.format("%.1f dB", db) .. " (" .. mode .. ")" .. muted)
                end
            end
            if #tooltip_lines > 0 then
                reaper.ImGui_SetTooltip(ctx, table.concat(tooltip_lines, "\n") .. "\n\nCtrl+Click: Remove from list\nMiddle-click: Go to track")
            else
                reaper.ImGui_SetTooltip(ctx, "Click to create send\nCtrl+Click: Remove from list\nMiddle-click: Go to track")
            end
        end
    elseif last_hover_id == hover_id then
        last_hover_id = nil
        hover_timers = {}
    end
    
    draw_track_context_menu(tr, show_remove_history)
    reaper.ImGui_SameLine(ctx)
    draw_rec_arm_button(tr)
    reaper.ImGui_SameLine(ctx)
    
    -- X delete button with red hover
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xE13333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xA81F1FFF)
    if reaper.ImGui_Button(ctx, "X", 24, 0) then
        delete_send_to(tr)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)
    
    -- Delayed tooltip for X button
    local x_hover_id = "xbtn_" .. guid
    if reaper.ImGui_IsItemHovered(ctx) then
        if last_hover_id ~= x_hover_id then
            hover_timers = {}
            last_hover_id = x_hover_id
        end
        hover_timers[x_hover_id] = (hover_timers[x_hover_id] or 0) + get_delta_time()
        if hover_timers[x_hover_id] >= tooltip_delay then
            reaper.ImGui_SetTooltip(ctx, "Delete send")
        end
    elseif last_hover_id == x_hover_id then
        last_hover_id = nil
        hover_timers = {}
    end
    
    reaper.ImGui_PopID(ctx)
end

local function draw_preview_row(tr, width)
    if not tr then return end
    local guid = reaper.GetTrackGUID(tr)
    reaper.ImGui_PushID(ctx, "preview_" .. guid)
    draw_color_square(get_track_color_u32(tr), 14)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, get_track_name(tr), width, 0) then
        create_send_to(tr)
    end
    
    -- Delayed tooltip for preview rows
    local hover_id = "preview_" .. guid
    if reaper.ImGui_IsItemHovered(ctx) then
        if last_hover_id ~= hover_id then
            hover_timers = {}
            last_hover_id = hover_id
        end
        hover_timers[hover_id] = (hover_timers[hover_id] or 0) + get_delta_time()
        if hover_timers[hover_id] >= tooltip_delay then
            reaper.ImGui_SetTooltip(ctx, "Click to create send to " .. get_track_name_only(tr))
        end
    elseif last_hover_id == hover_id then
        last_hover_id = nil
        hover_timers = {}
    end
    
    reaper.ImGui_PopID(ctx)
end

local function draw_current_panel()
    local current_tr = get_track_by_guid(cached_current_guid)
    reaper.ImGui_Text(ctx, "Current selected track")
    
    local color_size = 16
    local frame_h = 20
    local ok, fh = pcall(function() return reaper.ImGui_GetFrameHeight(ctx) end)
    if ok then frame_h = fh end
    
    -- Capture the line's base Y before drawing anything
    local base_y = reaper.ImGui_GetCursorPosY(ctx)
    
    -- Color square
    draw_color_square(get_track_color_u32(current_tr), color_size)
    
    -- Track name text
    reaper.ImGui_SameLine(ctx)
    local text_h = 13
    local ok2, th = pcall(function() return reaper.ImGui_GetTextLineHeight(ctx) end)
    if ok2 then text_h = th end
    reaper.ImGui_SetCursorPosY(ctx, base_y + math.max(0, (frame_h - text_h) * 0.5))
    reaper.ImGui_Text(ctx, get_track_name(current_tr))
    
    -- + button: create receive track
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetCursorPosY(ctx, base_y + math.max(0, (frame_h - color_size) * 0.5))
    
    local btn_x, btn_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Draw background + border using last frame's hover state (one frame lag is imperceptible)
    local bg = plus_btn_active and 0x333333FF or (plus_btn_hovered and 0x777777FF or 0x555555FF)
    reaper.ImGui_DrawList_AddRectFilled(dl, btn_x, btn_y, btn_x + color_size, btn_y + color_size, bg, 2)
    reaper.ImGui_DrawList_AddRect(dl, btn_x, btn_y, btn_x + color_size, btn_y + color_size, 0x000000FF, 2)
    
    -- Transparent button: ImGui handles text centering perfectly using real font metrics
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 2)
    
    if reaper.ImGui_Button(ctx, "+", color_size, color_size) then
        create_receive_track(false)
    end
    
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 4)
    
    -- Update hover state for next frame's background color
    plus_btn_hovered = reaper.ImGui_IsItemHovered(ctx)
    plus_btn_active = reaper.ImGui_IsItemActive(ctx)
    
    -- Right-click on + button: create armed receive track
    if reaper.ImGui_IsItemClicked(ctx, reaper.ImGui_MouseButton_Right()) then
        create_receive_track(true)
    end
    
    -- Delayed tooltip for + button
    local plus_hover_id = "plus_btn"
    if reaper.ImGui_IsItemHovered(ctx) then
        if last_hover_id ~= plus_hover_id then
            hover_timers = {}
            last_hover_id = plus_hover_id
        end
        hover_timers[plus_hover_id] = (hover_timers[plus_hover_id] or 0) + get_delta_time()
        if hover_timers[plus_hover_id] >= tooltip_delay then
            reaper.ImGui_SetTooltip(ctx, "Click: Create receive track\nRight-click: Create armed receive track")
        end
    elseif last_hover_id == plus_hover_id then
        last_hover_id = nil
        hover_timers = {}
    end

    local count = #cached_source_guids
    if count > 1 then
        reaper.ImGui_Text(ctx, "Selected source tracks: " .. tostring(count))
    end
end

local function handle_combined_input()
    if set_focus_once or reaper.ImGui_IsWindowAppearing(ctx) then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        set_focus_once = false
    end

    reaper.ImGui_Text(ctx, "Track number or search")
    reaper.ImGui_SetNextItemWidth(ctx, 142)
    
    local changed, new_val = reaper.ImGui_InputText(ctx, "##searchbox", input_val, 0)
    if new_val ~= nil then
        input_val = new_val
    end
    
    if reaper.ImGui_IsItemFocused(ctx) then
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
            send_from_input()
        end
        if reaper.ImGui_Key_KeypadEnter and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter()) then
            send_from_input()
        end
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Send", 54, 0) then
        send_from_input()
    end
    
    preview_results = find_tracks_matching_query(input_val)
    should_open_preview = (#preview_results > 0) and (normalize_query(input_val) ~= "")
    
    if should_open_preview and #preview_results > 0 then
        for _, tr in ipairs(preview_results) do
            draw_preview_row(tr, 123)
        end
    end
end

local function draw_favorites()
    local favorites = get_favorites()
    local has_any = false
    for _, guid in ipairs(favorites) do
        local tr = get_track_by_guid(guid)
        if tr then
            if not has_any then
                reaper.ImGui_Text(ctx, "Favorites")
            end
            has_any = true
            draw_track_row(tr, 120, false)
        end
    end
    return has_any
end

local function draw_recent()
    reaper.ImGui_Text(ctx, "Recent destinations")
    local history = get_history()
    if #history == 0 then
        reaper.ImGui_Text(ctx, "No history yet.")
        return
    end
    local found_any = false
    for _, guid in ipairs(history) do
        if not is_favorite_guid(guid) then
            local tr = get_track_by_guid(guid)
            if tr then
                found_any = true
                draw_track_row(tr, 120, true)
            end
        end
    end
end

local function draw_delete_popup()
    if not delete_popup_guid then return end
    
    local dest_tr = get_track_by_guid(delete_popup_guid)
    if not dest_tr then
        delete_popup_guid = nil
        delete_popup_sources = {}
        delete_popup_selected = {}
        return
    end
    
    local popup_name = "Delete Send##delete_popup"
    reaper.ImGui_OpenPopup(ctx, popup_name)
    
    local main_x, main_y = reaper.ImGui_GetWindowPos(ctx)
    local main_w, main_h = reaper.ImGui_GetWindowSize(ctx)
    local center_x = main_x + main_w * 0.5
    local center_y = main_y + main_h * 0.5
    reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    
    if reaper.ImGui_BeginPopupModal(ctx, popup_name, nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Multiple tracks send to " .. get_track_name(dest_tr))
        reaper.ImGui_Text(ctx, "Select which sources to remove:")
        reaper.ImGui_Separator(ctx)
        
        for i, src_tr in ipairs(delete_popup_sources) do
            local src_guid = reaper.GetTrackGUID(src_tr)
            reaper.ImGui_PushID(ctx, "popup_src_" .. src_guid)
            
            -- Checkbox for multi-select
            local changed, new_val = reaper.ImGui_Checkbox(ctx, "", delete_popup_selected[i])
            if changed then
                delete_popup_selected[i] = new_val
            end
            reaper.ImGui_SameLine(ctx)
            
            draw_color_square(get_track_color_u32(src_tr), 14)
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_Text(ctx, get_track_name(src_tr))
            reaper.ImGui_PopID(ctx)
        end
        
        reaper.ImGui_Separator(ctx)
        
        -- Delete selected button (enabled only if something is checked)
        local any_selected = false
        for _, v in ipairs(delete_popup_selected) do
            if v then any_selected = true; break end
        end
        
        local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        local btn_width = 100
        
        if any_selected then
            reaper.ImGui_SetCursorPosX(ctx, (avail_width - btn_width) * 0.5)
            if reaper.ImGui_Button(ctx, "Delete Selected", btn_width, 0) then
                reaper.Undo_BeginBlock()
                for i, src_tr in ipairs(delete_popup_sources) do
                    if delete_popup_selected[i] then
                        delete_send_from_to(src_tr, dest_tr)
                    end
                end
                reaper.TrackList_AdjustWindows(false)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("Quick Send: Delete Multiple", -1)
                reaper.ImGui_CloseCurrentPopup(ctx)
                delete_popup_guid = nil
                delete_popup_sources = {}
                delete_popup_selected = {}
            end
        else
            reaper.ImGui_BeginDisabled(ctx)
            reaper.ImGui_SetCursorPosX(ctx, (avail_width - btn_width) * 0.5)
            reaper.ImGui_Button(ctx, "Delete Selected", btn_width, 0)
            reaper.ImGui_EndDisabled(ctx)
        end
        
        reaper.ImGui_Spacing(ctx)
        
        -- Cancel button
        reaper.ImGui_SetCursorPosX(ctx, (avail_width - 80) * 0.5)
        if reaper.ImGui_Button(ctx, "Cancel", 80, 0) then
            reaper.ImGui_CloseCurrentPopup(ctx)
            delete_popup_guid = nil
            delete_popup_sources = {}
            delete_popup_selected = {}
        end
        
        reaper.ImGui_EndPopup(ctx)
    end
end

local function loop()
    cache_selected_tracks()
    
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then 
        if delete_popup_guid then
            delete_popup_guid = nil
            delete_popup_sources = {}
            delete_popup_selected = {}
        elseif should_open_preview then
            should_open_preview = false
        else
            return 
        end
    end

    local window_flags = reaper.ImGui_WindowFlags_NoCollapse()
    if reaper.ImGui_WindowFlags_AlwaysAutoResize then
        window_flags = window_flags + reaper.ImGui_WindowFlags_AlwaysAutoResize()
    end
    
    local visible, open = reaper.ImGui_Begin(ctx, 'Quick Send', true, window_flags)
    if visible then
        draw_current_panel()
        reaper.ImGui_Separator(ctx)
        handle_combined_input()
        reaper.ImGui_Separator(ctx)
        
        -- Reset deduplication set before drawing track lists
        drawn_track_guids = {}
        
        local fav_drawn = draw_favorites()
        if fav_drawn then
            reaper.ImGui_Separator(ctx)
        end
        draw_recent()
        
        draw_delete_popup()
        
        reaper.ImGui_End(ctx)
    end
    
    -- Reset frame time at end of loop so delta time is accurate
    last_frame_time = reaper.time_precise()
    
    if open then reaper.defer(loop) end
end

select_track_under_mouse()
reaper.defer(loop)
