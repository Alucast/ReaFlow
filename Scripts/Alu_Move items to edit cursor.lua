-- Move Selected Items to Edit Cursor (Preserve Relative Spacing)
-- Works with separate tracks and fixed item lanes
-- @author Alejandro (Alu) 

function main()
    -- Get edit cursor position
    local edit_cursor = reaper.GetCursorPosition()
    
    -- Get selected items count
    local num_selected = reaper.CountSelectedMediaItems(0)
    if num_selected == 0 then
        return
    end
    
    -- Create table to store items organized by track and lane
    local track_lane_groups = {}
    
    -- Collect all selected items and organize by track/lane
    for i = 0, num_selected - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItemTrack(item)
        local track_id = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        local lane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        local start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        
        -- Create unique key for track + lane combination
        local key = track_id .. "_" .. lane
        
        if not track_lane_groups[key] then
            track_lane_groups[key] = {}
        end
        
        table.insert(track_lane_groups[key], {
            item = item,
            start_time = start_time
        })
    end
    
    -- Begin undo block
    reaper.Undo_BeginBlock()
    
    -- Process each track/lane group
    for key, items in pairs(track_lane_groups) do
        if #items > 0 then
            -- Sort items by start time
            table.sort(items, function(a, b)
                return a.start_time < b.start_time
            end)
            
            -- Find the earliest start time in this group
            local earliest_time = items[1].start_time
            
            -- Calculate offset needed to move earliest item to edit cursor
            local offset = edit_cursor - earliest_time
            
            -- Move all items in this group by the same offset
            for _, item_data in ipairs(items) do
                local new_position = item_data.start_time + offset
                reaper.SetMediaItemInfo_Value(item_data.item, "D_POSITION", new_position)
            end
        end
    end
    
    -- Update timeline
    reaper.UpdateTimeline()
    reaper.UpdateArrange()
    
    -- End undo block
    reaper.Undo_EndBlock("Move selected items to edit cursor (preserve spacing)", -1)
end

-- Run the script
main()
