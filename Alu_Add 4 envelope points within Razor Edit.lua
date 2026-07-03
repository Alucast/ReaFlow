-- User-configurable percentage value (change this value as needed)
-- @author Alejandro (Alu) 
-- @modified to support both track envelopes and take envelopes

local percentage = 2  -- Percentage from the edges

-- Parse P_RAZOREDITS string into a table of {start_time, end_time, guid} entries
function ParseRazorEditAreas(areas_str)
    local result = {}
    if not areas_str or areas_str == "" then return result end
    
    local pos = 1
    local len = #areas_str
    
    while pos <= len do
        while pos <= len and areas_str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        if pos > len then break end
        
        local start_time_str = ""
        while pos <= len and not areas_str:sub(pos, pos):match("%s") do
            start_time_str = start_time_str .. areas_str:sub(pos, pos)
            pos = pos + 1
        end
        local start_time = tonumber(start_time_str)
        
        while pos <= len and areas_str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        if pos > len then break end
        
        local end_time_str = ""
        while pos <= len and not areas_str:sub(pos, pos):match("%s") do
            end_time_str = end_time_str .. areas_str:sub(pos, pos)
            pos = pos + 1
        end
        local end_time = tonumber(end_time_str)
        
        while pos <= len and areas_str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        if pos > len then break end
        
        local guid = ""
        if areas_str:sub(pos, pos) == '"' then
            pos = pos + 1
            while pos <= len and areas_str:sub(pos, pos) ~= '"' do
                guid = guid .. areas_str:sub(pos, pos)
                pos = pos + 1
            end
            pos = pos + 1
        else
            while pos <= len and not areas_str:sub(pos, pos):match("%s") do
                guid = guid .. areas_str:sub(pos, pos)
                pos = pos + 1
            end
        end
        
        if start_time and end_time then
            table.insert(result, {start_time = start_time, end_time = end_time, guid = guid})
        end
    end
    
    return result
end

function GetAllRazorEditAreas()
    local all_areas = {}
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local _, areas = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
        if areas and areas ~= "" then
            local parsed = ParseRazorEditAreas(areas)
            for _, area in ipairs(parsed) do
                area.track = track
                table.insert(all_areas, area)
            end
        end
    end
    
    return all_areas
end

-- Get envelope value at a specific time
function GetEnvelopeValueAtTime(envelope, time)
    local retval, value = reaper.Envelope_Evaluate(envelope, time, 0, 0)
    return value
end

-- Add 4 envelope points to a TRACK envelope (project time)
function AddFourTrackEnvelopePoints(envelope, start_time, end_time, percentage)
    local time_range = end_time - start_time
    local offset = time_range * percentage / 100
    
    local inner_point1 = start_time + offset
    local inner_point2 = end_time - offset
    
    local start_value = GetEnvelopeValueAtTime(envelope, start_time)
    local inner_value1 = GetEnvelopeValueAtTime(envelope, inner_point1)
    local inner_value2 = GetEnvelopeValueAtTime(envelope, inner_point2)
    local end_value = GetEnvelopeValueAtTime(envelope, end_time)
    
    reaper.InsertEnvelopePoint(envelope, start_time, start_value, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, inner_point1, inner_value1, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, inner_point2, inner_value2, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, end_time, end_value, 0, 0, false, true)
    
    reaper.Envelope_SortPoints(envelope)
end

-- Add 4 envelope points to a TAKE envelope
-- CRITICAL: Take envelope times are in take-local time (affected by playrate)
function AddFourTakeEnvelopePoints(take, envelope, item_pos, start_time, end_time, percentage)
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    
    -- Convert project time to take-local time
    local take_start = (start_time - item_pos) * playrate
    local take_end = (end_time - item_pos) * playrate
    
    local time_range = take_end - take_start
    local offset = time_range * percentage / 100
    
    local inner_point1 = take_start + offset
    local inner_point2 = take_end - offset
    
    -- Evaluate at take-local times
    local _, start_value = reaper.Envelope_Evaluate(envelope, take_start, 0, 0)
    local _, inner_value1 = reaper.Envelope_Evaluate(envelope, inner_point1, 0, 0)
    local _, inner_value2 = reaper.Envelope_Evaluate(envelope, inner_point2, 0, 0)
    local _, end_value = reaper.Envelope_Evaluate(envelope, take_end, 0, 0)
    
    reaper.InsertEnvelopePoint(envelope, take_start, start_value, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, inner_point1, inner_value1, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, inner_point2, inner_value2, 0, 0, false, true)
    reaper.InsertEnvelopePoint(envelope, take_end, end_value, 0, 0, false, true)
    
    reaper.Envelope_SortPoints(envelope)
end

function DeselectAllEnvelopePoints(envelope)
    if not envelope then return end
    local point_count = reaper.CountEnvelopePoints(envelope)
    for i = 0, point_count - 1 do
        reaper.SetEnvelopePoint(envelope, i, nil, nil, nil, nil, false, false)
    end
end

function ProcessTrackEnvelopeRazorEdit(track, start_time, end_time, guid)
    local env_count = reaper.CountTrackEnvelopes(track)
    for env_idx = 0, env_count - 1 do
        local envelope = reaper.GetTrackEnvelope(track, env_idx)
        if envelope then
            local _, env_guid = reaper.GetSetEnvelopeInfo_String(envelope, "GUID", "", false)
            env_guid = env_guid:gsub('"', '')
            
            if env_guid == guid then
                AddFourTrackEnvelopePoints(envelope, start_time, end_time, percentage)
                DeselectAllEnvelopePoints(envelope)
                return true
            end
        end
    end
    return false
end

function ProcessItemRazorEdit(track, start_time, end_time)
    local item_count = reaper.CountTrackMediaItems(track)
    local success = false
    
    for item_idx = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, item_idx)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_len
        
        -- Check if razor edit overlaps with this item
        if start_time < item_end and end_time > item_pos then
            local take = reaper.GetActiveTake(item)
            if take then
                -- Try to get the volume take envelope by name
                local envelope = reaper.GetTakeEnvelopeByName(take, "Volume")
                
                -- If no volume envelope, try to find any take envelope
                if not envelope then
                    local take_env_count = reaper.CountTakeEnvelopes(take)
                    if take_env_count > 0 then
                        envelope = reaper.GetTakeEnvelope(take, 0)
                    end
                end
                
                if envelope then
                    -- Clip to item bounds (in project time)
                    local clip_start = math.max(start_time, item_pos)
                    local clip_end = math.min(end_time, item_end)
                    
                    AddFourTakeEnvelopePoints(take, envelope, item_pos, clip_start, clip_end, percentage)
                    DeselectAllEnvelopePoints(envelope)
                    success = true
                end
            end
        end
    end
    
    -- Fallback to track envelope
    if not success then
        local track_env = reaper.GetTrackEnvelope(track, 0)
        if track_env then
            AddFourTrackEnvelopePoints(track_env, start_time, end_time, percentage)
            DeselectAllEnvelopePoints(track_env)
            success = true
        end
    end
    
    return success
end

function ClearRazorEditSelection(track)
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", true)
end

function main()
    local areas = GetAllRazorEditAreas()
    
    if #areas == 0 then
        reaper.ShowMessageBox("No valid Razor Edit selection found.", "Error", 0)
        return
    end
    
    local success = false
    local processed_tracks = {}
    
    for _, area in ipairs(areas) do
        local track = area.track
        local start_time = area.start_time
        local end_time = area.end_time
        local guid = area.guid
        
        if start_time and end_time and start_time < end_time then
            local area_success = false
            
            if guid == "" then
                area_success = ProcessItemRazorEdit(track, start_time, end_time)
            else
                area_success = ProcessTrackEnvelopeRazorEdit(track, start_time, end_time, guid)
            end
            
            if area_success then
                success = true
                processed_tracks[track] = true
            end
        end
    end
    
    if success then
        for track, _ in pairs(processed_tracks) do
            ClearRazorEditSelection(track)
        end
        reaper.UpdateArrange()
    else
        reaper.ShowMessageBox("No valid envelope found for the Razor Edit selection.", "Error", 0)
    end
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Add Envelope Points in Razor Edit Time Selection", -1)
