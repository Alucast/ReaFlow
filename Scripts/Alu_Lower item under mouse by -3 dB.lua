-- Lower item volume under mouse by 3 dB
-- @author Alu
-- @version 1.3

function main()
    -- Get item under mouse cursor
    local window, segment, details = reaper.BR_GetMouseCursorContext()
    local item = reaper.BR_GetMouseCursorContext_Item()
    
    if not item then return end
    
    -- Select only the item under mouse (deselect others)
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    
    reaper.Undo_BeginBlock()
    
    local take = reaper.GetActiveTake(item)
    if take then
        local vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
        local db = 20 * (math.log(vol) / math.log(10))
        local new_db = db - 3.0
        local new_vol = 10^(new_db / 20)
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", new_vol)
    end
    
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Lower item under mouse -3 dB", -1)
end

reaper.defer(main)
