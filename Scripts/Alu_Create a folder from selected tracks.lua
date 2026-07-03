-- Create a folder from selected tracks in REAPER
-- @author Alejandro (Alu) 

-- Get number of selected tracks
local num_selected_tracks = reaper.CountSelectedTracks(0)

-- Create a new folder track
local folder_track = reaper.CreateNewTrack(0, 0)

-- Move the selected tracks into the folder track
for i = 0, num_selected_tracks - 1 do
  local track = reaper.GetSelectedTrack(0, i)
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 1)
end

-- Update the arrangement (to add the folder track to the project)
reaper.PreventUIRefresh(1)
reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)

-- Select the folder track
reaper.SetOnlyTrackSelected(folder_track)

-- Show the folder track in the TCP region
reaper.TrackList_AdjustWindows(false)
reaper.SetMixerScroll(folder_track)

