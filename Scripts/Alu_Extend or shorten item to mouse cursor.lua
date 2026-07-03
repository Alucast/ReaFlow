-- @description Trim nearest item edge to mouse cursor position
-- @author Alu
-- @version 1.0

function GetMouseTime()
    -- Method 1: SWS BR_GetMouseCursorContext (most accurate, requires SWS)
    if reaper.APIExists("BR_GetMouseCursorContext") then
        reaper.BR_GetMouseCursorContext()
        local mouse_time = reaper.BR_GetMouseCursorContext_Position()
        if mouse_time and mouse_time >= 0 then
            return mouse_time
        end
    end

    -- Method 2: Try using JS extension to find arrange view and convert coordinates
    if reaper.APIExists("JS_Window_Find") and reaper.APIExists("JS_Window_GetClientRect") then
        local arrange_hwnd = reaper.JS_Window_Find("REAPERArrangeView", true)
        if arrange_hwnd then
            local _, ax, ay, ar, ab = reaper.JS_Window_GetClientRect(arrange_hwnd)
            local arrange_w = ar - ax

            local mouse_x, mouse_y = reaper.GetMousePosition()

            -- Check if mouse is within arrange view
            if mouse_x >= ax and mouse_x <= ar and mouse_y >= ay and mouse_y <= ab then
                local rel_x = mouse_x - ax
                local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
                local time_range = end_time - start_time
                return start_time + (rel_x / arrange_w) * time_range
            end
        end
    end

    -- Method 3: Fallback to edit cursor
    return reaper.GetCursorPosition()
end

function main()
    local mouse_time = GetMouseTime()
    local original_cursor = reaper.GetCursorPosition()

    -- Save current item selection
    local selected = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        selected[#selected + 1] = reaper.GetSelectedMediaItem(0, i)
    end

    if #selected == 0 then return end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Temporarily move edit cursor to mouse position (without moving view)
    reaper.SetEditCurPos2(0, mouse_time, false, false)

    for _, item in ipairs(selected) do
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = pos + len

        local distLeft  = math.abs(mouse_time - pos)
        local distRight = math.abs(mouse_time - itemEnd)

        -- Select only this item
        reaper.Main_OnCommand(40289, 0) -- Unselect all items
        reaper.SetMediaItemSelected(item, true)

        if distLeft < distRight then
            -- Move left edge of item to edit cursor (now at mouse position)
            reaper.Main_OnCommand(41305, 0)
        else
            -- Move right edge of item to edit cursor (now at mouse position)
            reaper.Main_OnCommand(41311, 0)
        end
    end

    -- Restore original selection
    reaper.Main_OnCommand(40289, 0)
    for _, item in ipairs(selected) do
        reaper.SetMediaItemSelected(item, true)
    end

    -- Restore edit cursor
    reaper.SetEditCurPos2(0, original_cursor, false, false)

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Trim nearest item edge to mouse cursor", -1)
end

main()
