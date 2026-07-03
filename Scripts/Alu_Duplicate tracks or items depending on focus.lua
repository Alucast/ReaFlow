-- @author Alejandro (Alu) 

reaper.Undo_BeginBlock()

local proj = 0
local countSelectedItems = reaper.CountSelectedMediaItems(proj)

-- Check for razor edits
local function HasAnyRazorEdit()
    for i = 0, reaper.CountTracks(proj) - 1 do
        local track = reaper.GetTrack(proj, i)
        local _, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)

        if string.len(razorStr) > 0 then return true end
    end
    return false
end

-- Get the mouse cursor context
local window, segment, details = reaper.BR_GetMouseCursorContext()

if HasAnyRazorEdit() then
    reaper.Main_OnCommand(reaper.NamedCommandLookup(41296), 0) -- Item: Duplicate selected area of items
elseif countSelectedItems > 0 then
    -- Check if the mouse is over the arrange view to duplicate items, or TCP for tracks
    if segment == "track" then
        reaper.Main_OnCommand(reaper.NamedCommandLookup(40062), 0) -- Track: Duplicate tracks
    elseif segment == "items" then
        reaper.Main_OnCommand(reaper.NamedCommandLookup(41295), 0) -- Item: Duplicate items
    else
        reaper.ShowMessageBox("Mouse is not over a valid context to duplicate.", "Warning", 0)
    end
else
    reaper.Main_OnCommand(reaper.NamedCommandLookup(40062), 0) -- Track: Duplicate tracks (fallback if nothing is selected)
end

reaper.Undo_EndBlock("Duplicate selected tracks or items", -1)

