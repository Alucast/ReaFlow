-- @description Alu_MIDI Note Length Adjuster with Tight Ripple
-- @version 1.6
-- @author Alu

-- ReaImGui context
local ctx = reaper.ImGui_CreateContext('Midi Note Length Halver')

local ripple = false
local gap_ppq = 1 -- 1 PPQ gap between rippled notes

-- Settings file for saving window position
local script_name = "Alu_MidiNoteLengthHalver"
local settings_path = reaper.GetResourcePath() .. "/Scripts/AluScripts/" .. script_name .. "_settings.ini"

function SaveSettings(pos_x, pos_y)
    reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts/AluScripts", 0)
    local file = io.open(settings_path, "w")
    if file then
        file:write("pos_x=" .. tostring(pos_x) .. "\n")
        file:write("pos_y=" .. tostring(pos_y) .. "\n")
        file:write("ripple=" .. tostring(ripple) .. "\n")
        file:close()
    end
end

function LoadSettings()
    local file = io.open(settings_path, "r")
    if file then
        for line in file:lines() do
            local key, value = line:match("^(%w+)=(.+)$")
            if key == "pos_x" then
                reaper.ImGui_SetWindowPos(ctx, 'Midi Note Length Halver', tonumber(value), nil, reaper.ImGui_Cond_FirstUseEver())
            elseif key == "pos_y" then
                reaper.ImGui_SetWindowPos(ctx, 'Midi Note Length Halver', nil, tonumber(value), reaper.ImGui_Cond_FirstUseEver())
            elseif key == "ripple" then
                ripple = (value == "true")
            end
        end
        file:close()
    end
end

-- Load saved settings on startup
LoadSettings()

function GetSelectedNotes(take)
    local notes = {}
    local _, note_count = reaper.MIDI_CountEvts(take)
    
    for i = 0, note_count - 1 do
        local retval, selected, muted, start_ppq, end_ppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
        if retval and selected then
            table.insert(notes, {
                idx = i,
                start_ppq = start_ppq,
                end_ppq = end_ppq,
                length = end_ppq - start_ppq,
                pitch = pitch,
                chan = chan,
                vel = vel,
                muted = muted
            })
        end
    end
    
    table.sort(notes, function(a, b)
        if a.start_ppq ~= b.start_ppq then
            return a.start_ppq < b.start_ppq
        else
            return a.pitch < b.pitch
        end
    end)
    
    return notes
end

function AdjustLengths(lengthen)
    local ME = reaper.MIDIEditor_GetActive()
    if not ME then return end
    local take = reaper.MIDIEditor_GetTake(ME)
    if not take or not reaper.TakeIsMIDI(take) then return end
    
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    
    local notes = GetSelectedNotes(take)
    if #notes == 0 then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("MIDI Note Length Adjust", -1)
        return
    end
    
    -- First pass: halve or double each note's length
    local processed = {}
    for _, note in ipairs(notes) do
        local new_length
        if lengthen then
            new_length = note.length * 2
        else
            new_length = math.floor(note.length / 2)
            if new_length < 1 then new_length = 1 end
        end
        
        table.insert(processed, {
            idx = note.idx,
            original_start = note.start_ppq,
            original_end = note.end_ppq,
            new_length = new_length,
            pitch = note.pitch,
            chan = note.chan,
            vel = note.vel,
            muted = note.muted
        })
    end
    
    -- Second pass: apply positions
    if ripple then
        local last_end = nil
        for i, p in ipairs(processed) do
            local new_start, new_end
            
            if i == 1 then
                new_start = p.original_start
                new_end = new_start + p.new_length
            else
                new_start = last_end + gap_ppq
                new_end = new_start + p.new_length
            end
            
            reaper.MIDI_SetNote(take, p.idx, true, p.muted, new_start, new_end, p.chan, p.pitch, p.vel, true)
            last_end = new_end
        end
    else
        for _, p in ipairs(processed) do
            local new_end = p.original_start + p.new_length
            reaper.MIDI_SetNote(take, p.idx, true, p.muted, p.original_start, new_end, p.chan, p.pitch, p.vel, true)
        end
    end
    
    reaper.MIDI_Sort(take)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("MIDI Note Length Adjust (" .. (lengthen and "Double" or "Halve") .. (ripple and " + Ripple" or "") .. ")", -1)
    reaper.UpdateArrange()
end

-- Main GUI loop
function loop()
    -- Close on ESC key
    if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_Escape()) then
        local pos_x, pos_y = reaper.ImGui_GetWindowPos(ctx)
        SaveSettings(pos_x, pos_y)
        return
    end
    
    -- NoTitleBar flag removes the window title bar
    local window_flags = reaper.ImGui_WindowFlags_NoTitleBar() 
                       | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    
    local visible, open = reaper.ImGui_Begin(ctx, 'Midi Note Length Halver', true, window_flags)
    
    if visible then
        local changed, new_val = reaper.ImGui_Checkbox(ctx, "Ripple", ripple)
        if changed then ripple = new_val end
        
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        
        local btn_w, btn_h = 120, 45
        
        -- Up arrow on top
        if reaper.ImGui_Button(ctx, "▲", btn_w, btn_h) then
            AdjustLengths(true)
        end
        
        -- Down arrow below
        if reaper.ImGui_Button(ctx, "▼", btn_w, btn_h) then
            AdjustLengths(false)
        end
        
        reaper.ImGui_End(ctx)
    end
    
    if open then
        reaper.defer(loop)
    else
        -- Window was closed via X button - save position
        local pos_x, pos_y = reaper.ImGui_GetWindowPos(ctx)
        SaveSettings(pos_x, pos_y)
    end
end

-- Start
reaper.defer(loop)
