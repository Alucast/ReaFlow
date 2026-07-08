-- Add Active Fixed Lane
-- Adds a new fixed lane to selected track(s) (or track under mouse) and activates them

-- ==================== INPUT SECTION ====================
-- Change the value below to control how the new lane behaves:

local LANE_PLAY_MODE = 2  -- 0 = Inactive (muted)
                         -- 1 = Plays Exclusively (solos this lane, mutes others)
                         -- 2 = Plays Alongside (active with other lanes)

-- =======================================================

function addLaneToTrack(track)
  -- Enable fixed lanes if the track isn't already using them
  if reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") ~= 2 then
    reaper.SetMediaTrackInfo_Value(track, "I_FREEMODE", 2)
  end

  -- Get current lane count; the new lane index equals the current count
  local numLanes = reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES")
  local newLane = numLanes

  -- Add the new lane by incrementing the fixed lane count
  reaper.SetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES", numLanes + 1)

  -- Apply the configured play mode to the new lane
  reaper.SetMediaTrackInfo_Value(track, "C_LANEPLAYS:" .. newLane, LANE_PLAY_MODE)
end

function main()
  local selectedCount = reaper.CountSelectedTracks(0)
  local tracksToProcess = {}

  -- If multiple tracks are selected, process all of them
  if selectedCount > 0 then
    for i = 0, selectedCount - 1 do
      local track = reaper.GetSelectedTrack(0, i)
      table.insert(tracksToProcess, track)
    end
  else
    -- No tracks selected: fall back to track under mouse cursor
    local mouse_x, mouse_y = reaper.GetMousePosition()
    local track = reaper.GetTrackFromPoint(mouse_x, mouse_y)

    if track then
      reaper.SetOnlyTrackSelected(track)
      table.insert(tracksToProcess, track)
    end
  end

  -- If we have no tracks to process, show an error
  if #tracksToProcess == 0 then
    reaper.MB("Please select one or more tracks, or hover over a track before running this action.", "Add Active Fixed Lane", 0)
    return
  end

  reaper.Undo_BeginBlock()

  -- Add lanes to all targeted tracks
  for _, track in ipairs(tracksToProcess) do
    addLaneToTrack(track)
  end

  reaper.UpdateTimeline()
  reaper.UpdateArrange()

  local undoMsg = "Add active fixed lane"
  if #tracksToProcess > 1 then
    undoMsg = undoMsg .. "s to " .. #tracksToProcess .. " tracks"
  end
  undoMsg = undoMsg .. " (mode: " .. LANE_PLAY_MODE .. ")"

  reaper.Undo_EndBlock(undoMsg, -1)
end

main()
