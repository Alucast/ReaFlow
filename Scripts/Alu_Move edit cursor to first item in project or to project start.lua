-- @author Alejandro (Alu) 

reaper.Undo_BeginBlock()

local num_tracks = reaper.GetNumTracks()

local times = {}
for i = 0, num_tracks - 1 do

  local tr = reaper.GetTrack( 0, i )
  local item = reaper.GetTrackMediaItem( tr, 0 )

  if item then
    table.insert(times, reaper.GetMediaItemInfo_Value( item, "D_POSITION" ) )
  end

end

local cursor_pos = 0

if #times > 0 then
  table.sort(times)
  cursor_pos = times[1]
end

-- Always move to the minimum of first item position or project start (which is zero)
if cursor_pos < 0 then cursor_pos = 0 end
reaper.SetEditCurPos(cursor_pos, true, false)

reaper.Undo_EndBlock("Move cursor to start of first item in project, or start of project if no items exist", 0)

