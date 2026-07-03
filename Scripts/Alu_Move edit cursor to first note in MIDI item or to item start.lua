-- @author Alejandro (Alu) 

function main()
    local MIDIEditor = reaper.MIDIEditor_GetActive()
    if not MIDIEditor then return end
    
    local take = reaper.MIDIEditor_GetTake(MIDIEditor)
    if not take or not reaper.TakeIsMIDI(take) then return end
    
    local _, notecnt = reaper.MIDI_CountEvts(take)
    
    if notecnt == 0 then
        -- No notes: move to start of MIDI item
        local item = reaper.GetMediaItemTake_Item(take)
        if item then
            local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            reaper.SetEditCurPos(item_start, true, true)
        end
    else
        -- Notes exist: move to first note
        local _, _, _, startppqpos = reaper.MIDI_GetNote(take, 0)
        local first_note_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppqpos)
        reaper.SetEditCurPos(first_note_time, true, true)
    end
end

main()
reaper.defer(function() end)  -- No continuous execution needed
