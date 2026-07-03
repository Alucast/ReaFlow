-- Color regions from track colors by numeric name matching (silent)
-- @author Alejandro (Alu) 

local function extract_track_number(track_name)
  if not track_name then return nil end
  local num = track_name:match("^%s*(%d+)%s*$")
  if num then return tonumber(num) end
  return nil
end

local function extract_region_part_number(region_name)
  if not region_name then return nil end
  local lower_name = region_name:lower()
  local num = lower_name:match("part%s*(%d+)")
  if num then return tonumber(num) end
  return nil
end

local function build_track_color_map()
  local map = {}
  local track_count = reaper.CountTracks(0)

  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local _, track_name = reaper.GetTrackName(track, "")
    local track_num = extract_track_number(track_name)

    if track_num then
      local color = reaper.GetTrackColor(track)
      if color ~= 0 then
        map[track_num] = color
      end
    end
  end

  return map
end

local function color_regions_from_tracks()
  local color_map = build_track_color_map()
  local retval, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 0, total - 1 do
    local retval2, isrgn, pos, rgnend, name, markrgnindexnumber, current_color =
      reaper.EnumProjectMarkers3(0, i)

    if isrgn then
      local part_num = extract_region_part_number(name)

      if part_num then
        local track_color = color_map[part_num]
        if track_color and track_color ~= 0 then
          reaper.SetProjectMarkerByIndex2(
            0,
            i,
            true,
            pos,
            rgnend,
            markrgnindexnumber,
            name,
            track_color,
            0
          )
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Color regions from matching track colors", -1)
end

color_regions_from_tracks()
