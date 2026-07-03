-- @description Quick Send
-- @version 3.3
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

    if reaper.ImGui_IsItemHovered(ctx) then
        local tip = armed and "Disarm record on this track" or "Arm record on this track"
        reaper.ImGui_SetTooltip(ctx, tip)
    end
    if clicked then
        toggle_track_rec_arm(tr)
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
    local src_tracks = get_cached_source_tracks()
    if #src_tracks == 0 then return end
    local dest_guid = reaper.GetTrackGUID(dest_tr)

    reaper.Undo_BeginBlock()
    for _, src_tr in ipairs(src_tracks) do
        local num_sends = reaper.GetTrackNumSends(src_tr, 0)
        for s = num_sends - 1, 0, -1 do
            local current_dest = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK")
            if current_dest and reaper.ValidatePtr2(0, current_dest, "MediaTrack*") and reaper.GetTrackGUID(current_dest) == dest_guid then
                reaper.RemoveTrackSend(src_tr, 0, s)
            end
        end
    end
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Quick Send: Delete", -1)
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
        if reaper.ImGui_MenuItem(ctx, "Go to track") then
            go_to_track(tr)
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

local function draw_track_row(tr, button_width, show_remove_history)
    if not tr then return end
    local guid = reaper.GetTrackGUID(tr)
    reaper.ImGui_PushID(ctx, guid)
    draw_color_square(get_track_color_u32(tr), 14)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, get_track_name(tr), button_width, 0) then
        create_send_to(tr)
    end
    draw_track_context_menu(tr, show_remove_history)
    reaper.ImGui_SameLine(ctx)
    draw_rec_arm_button(tr)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "X", 24, 0) then
        delete_send_to(tr)
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
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Click to create send to " .. get_track_name_only(tr))
    end
    reaper.ImGui_PopID(ctx)
end

local function draw_current_panel()
    local current_tr = get_track_by_guid(cached_current_guid)
    reaper.ImGui_Text(ctx, "Current selected track")
    
    -- Draw color square
    draw_color_square(get_track_color_u32(current_tr), 16)
    
    -- Move to same line and vertically center the text with the square
    reaper.ImGui_SameLine(ctx)
    local frame_h = 20
    local ok, fh = pcall(function() return reaper.ImGui_GetFrameHeight(ctx) end)
    if ok then frame_h = fh end
    local text_h = 13
    local ok2, th = pcall(function() return reaper.ImGui_GetTextLineHeight(ctx) end)
    if ok2 then text_h = th end
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + math.max(0, (frame_h - text_h) * 0.5))
    reaper.ImGui_Text(ctx, get_track_name(current_tr))

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
    
    -- Plain tracklist preview — no background box, no border overlay
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
            draw_track_row(tr, 190, false)
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
    if not found_any then
        reaper.ImGui_Text(ctx, "All recent destinations are already pinned as favorites.")
    end
end

local function loop()
    cache_selected_tracks()
    
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then 
        if should_open_preview then
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
        local fav_drawn = draw_favorites()
        if fav_drawn then
            reaper.ImGui_Separator(ctx)
        end
        draw_recent()
        reaper.ImGui_End(ctx)
    end
    if open then reaper.defer(loop) end
end

-- Select track under mouse before starting the UI loop
select_track_under_mouse()

reaper.defer(loop)
