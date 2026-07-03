-- @description Trim nearest item edge to edit cursor
-- @author Alu
-- @version 1.0

function main()
    local cursor = reaper.GetCursorPosition()

    -- Save current item selection
    local selected = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        selected[#selected + 1] = reaper.GetSelectedMediaItem(0, i)
    end

    if #selected == 0 then return end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    for _, item in ipairs(selected) do
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = pos + len

        local distLeft  = math.abs(cursor - pos)
        local distRight = math.abs(cursor - itemEnd)

        -- Select only this item
        reaper.Main_OnCommand(40289, 0) -- Unselect all items
        reaper.SetMediaItemSelected(item, true)

        if distLeft < distRight then
            -- Move left edge of item to edit cursor
            reaper.Main_OnCommand(41305, 0)
        else
            -- Move right edge of item to edit cursor
            reaper.Main_OnCommand(41311, 0)
        end
    end

    -- Restore original selection
    reaper.Main_OnCommand(40289, 0)
    for _, item in ipairs(selected) do
        reaper.SetMediaItemSelected(item, true)
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Trim nearest item edge to edit cursor", -1)
end

main()

