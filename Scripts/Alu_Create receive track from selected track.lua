-- @author Alejandro (Alu) 

-- Options
local disableMasterSend = false -- Set to 'true' to disable "Master/Parent Send" for the new track, 'false' to keep it enabled.
local lightenAmount = 60       -- Amount to lighten the new track's color (increase for lighter effect, decrease for subtle effect)

-- Get default send volume and flag from REAPER's configuration
local defsendvol = ({reaper.BR_Win32_GetPrivateProfileString('REAPER', 'defsendvol', '0', reaper.get_ini_file())})[2]
local defsendflag = ({reaper.BR_Win32_GetPrivateProfileString('REAPER', 'defsendflag', '0', reaper.get_ini_file())})[2]

-- Function to convert hex color to RGB
function hexToRGB(hex)
    hex = hex:gsub("#","")
    return tonumber("0x"..hex:sub(1,2)), tonumber("0x"..hex:sub(3,4)), tonumber("0x"..hex:sub(5,6))
end

-- Function to lighten RGB color
function lightenColor(r, g, b, amount)
    r = math.min(r + amount, 255)
    g = math.min(g + amount, 255)
    b = math.min(b + amount, 255)
    return r, g, b
end

-- Function to select track under mouse cursor
function selectTrackUnderMouseCursor()
    reaper.Main_OnCommand(41110, 0) -- Track: Select track under mouse
end

-- Function to set the input of a track to "Input: None"
function setTrackInputNone(track)
    reaper.SetMediaTrackInfo_Value(track, 'I_RECINPUT', -1) -- -1 corresponds to "Input: None"
end

-- Main function
function main()
    -- Select the track under the mouse cursor
    selectTrackUnderMouseCursor()
    
    -- Define the name for the destination track
    local destTrackName = "send"

    -- Get the first selected track
    local firstSelectedTrack = reaper.GetSelectedTrack(0, 0)
    if firstSelectedTrack == nil then
        reaper.ShowMessageBox("No track selected", "Error", 0)
        return
    end

    local retval, trackName = reaper.GetSetMediaTrackInfo_String(firstSelectedTrack, 'P_NAME', '', false)
    if retval and trackName ~= '' then
        destTrackName = trackName .. " send"
    end

    -- Get the index of the first selected track
    local firstTrackIndex = reaper.GetMediaTrackInfo_Value(firstSelectedTrack, "IP_TRACKNUMBER") - 1

  -- Insert the new track below the first selected track
  reaper.InsertTrackAtIndex(firstTrackIndex + 1, true)
  local new_dest_tr = reaper.GetTrack(0, firstTrackIndex + 1)
  

    -- Arm the new destination track for recording
    reaper.SetMediaTrackInfo_Value(new_dest_tr, 'I_RECARM', 1)
    -- Set the track to record output (stereo)
    reaper.SetMediaTrackInfo_Value(new_dest_tr, 'I_RECMODE', 3)  -- 3 corresponds to "Record: Output (stereo)"

    -- Set the track input to "Input: None"
    setTrackInputNone(new_dest_tr)
    
    -- Set the name of the destination track
    reaper.GetSetMediaTrackInfo_String(new_dest_tr, 'P_NAME', destTrackName, true)
    
    -- Get the color of the first selected track and lighten it
    local originalColor = reaper.GetTrackColor(firstSelectedTrack)
    local r, g, b = reaper.ColorFromNative(originalColor)
    r, g, b = lightenColor(r, g, b, lightenAmount) -- Use lightenAmount to adjust the color
    local newColor = reaper.ColorToNative(r, g, b)|0x1000000
    reaper.SetTrackColor(new_dest_tr, newColor)
    
    -- Disable "Master/Parent Send" if the option is set to true
    if disableMasterSend then
        reaper.SetMediaTrackInfo_Value(new_dest_tr, 'B_MAINSEND', 0)
    end

    for i = 1, reaper.CountSelectedTracks(0) do
        local tr = reaper.GetSelectedTrack(0, i - 1)
        if tr then
            local new_send_id = reaper.CreateTrackSend(tr, new_dest_tr)
            if new_send_id >= 0 then
                reaper.SetTrackSendInfo_Value(tr, 0, new_send_id, 'D_VOL', defsendvol)
                reaper.SetTrackSendInfo_Value(tr, 0, new_send_id, 'I_SENDMODE', defsendflag)
            end
        end
    end

    reaper.TrackList_AdjustWindows(false)
end

main()

