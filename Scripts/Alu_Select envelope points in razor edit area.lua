-- @description Select envelope points in razor edit area
-- @version 1.5
-- @author Alu
-- @about
--   Selects envelope points that fall within razor edit areas.
--   Track-wide razor areas select take envelopes on items AND the items themselves.
--   Envelope-lane razor areas select only that specific envelope lane and focus it.
--   Replaces any existing selection.

function StripQuotes(str)
  if string.sub(str, 1, 1) == '"' and string.sub(str, -1) == '"' then
    return string.sub(str, 2, -2)
  end
  return str
end

function GetRazorEditAreas()
  local areas = {}
  local trackCount = reaper.CountTracks(0)

  for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)

    if razorStr and razorStr ~= "" then
      local t = {}
      for token in string.gmatch(razorStr, '%S+') do
        table.insert(t, token)
      end

      local j = 1
      while j <= #t do
        if j + 2 <= #t then
          local startTime = tonumber(t[j])
          local endTime = tonumber(t[j+1])
          local envGuid = StripQuotes(t[j+2])

          local area = {
            track = track,
            startTime = startTime,
            endTime = endTime,
            envGuid = envGuid,
            isEnvelope = (envGuid ~= "")
          }
          table.insert(areas, area)
        end
        j = j + 3
      end
    end
  end

  return areas
end

function FindEnvelopeByGuid(track, guid)
  local envCount = reaper.CountTrackEnvelopes(track)
  for i = 0, envCount - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    local retval, envGuid = reaper.GetSetEnvelopeInfo_String(env, "GUID", "", false)
    if envGuid == guid then
      return env, i
    end
  end
  return nil, -1
end

function DeselectAllItems()
  local itemCount = reaper.CountMediaItems(0)
  for i = 0, itemCount - 1 do
    local item = reaper.GetMediaItem(0, i)
    reaper.SetMediaItemSelected(item, false)
  end
end

function DeselectAllEnvelopePoints()
  local trackCount = reaper.CountTracks(0)
  for t = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, t)
    local envCount = reaper.CountTrackEnvelopes(track)
    for e = 0, envCount - 1 do
      local envelope = reaper.GetTrackEnvelope(track, e)
      local pointCount = reaper.CountEnvelopePoints(envelope)
      for p = 0, pointCount - 1 do
        local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, p)
        if selected then
          reaper.SetEnvelopePoint(envelope, p, time, value, shape, tension, false, true)
        end
      end
      reaper.Envelope_SortPoints(envelope)
    end
  end

  for t = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, t)
    local itemCount = reaper.CountTrackMediaItems(track)
    for i = 0, itemCount - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local takeCount = reaper.CountTakes(item)
      for tk = 0, takeCount - 1 do
        local take = reaper.GetTake(item, tk)
        if take then
          local envCount = reaper.CountTakeEnvelopes(take)
          for e = 0, envCount - 1 do
            local envelope = reaper.GetTakeEnvelope(take, e)
            local pointCount = reaper.CountEnvelopePoints(envelope)
            for p = 0, pointCount - 1 do
              local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, p)
              if selected then
                reaper.SetEnvelopePoint(envelope, p, time, value, shape, tension, false, true)
              end
            end
            reaper.Envelope_SortPoints(envelope)
          end
        end
      end
    end
  end
end

function SelectPointsInEnvelope(envelope, areaStart, areaEnd, timeOffset)
  if not envelope then return end
  timeOffset = timeOffset or 0

  local pointCount = reaper.CountEnvelopePoints(envelope)

  for p = 0, pointCount - 1 do
    local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, p)
    local absoluteTime = time + timeOffset

    if absoluteTime >= areaStart and absoluteTime <= areaEnd then
      reaper.SetEnvelopePoint(envelope, p, time, value, shape, tension, true, true)
    end
  end

  reaper.Envelope_SortPoints(envelope)
end

function SelectItemsInArea(track, area)
  local itemCount = reaper.CountTrackMediaItems(track)
  for i = 0, itemCount - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if itemEnd > area.startTime and itemStart < area.endTime then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

function SelectTakeEnvelopePoints(track, area)
  local lastTakeEnvelope = nil
  local itemCount = reaper.CountTrackMediaItems(track)
  for i = 0, itemCount - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if itemEnd > area.startTime and itemStart < area.endTime then
      local take = reaper.GetActiveTake(item)
      if take then
        local envCount = reaper.CountTakeEnvelopes(take)
        for e = 0, envCount - 1 do
          local envelope = reaper.GetTakeEnvelope(take, e)
          SelectPointsInEnvelope(envelope, area.startTime, area.endTime, itemStart)
          lastTakeEnvelope = envelope
        end
      end
    end
  end
  return lastTakeEnvelope
end

function Main()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local areas = GetRazorEditAreas()

  if #areas == 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Select envelope points in razor edit (no areas found)", -1)
    return
  end

  -- Clear all previous selections
  DeselectAllItems()
  DeselectAllEnvelopePoints()

  -- First pass: select all items from track-wide areas
  for _, area in ipairs(areas) do
    if not area.isEnvelope then
      SelectItemsInArea(area.track, area)
    end
  end

  -- Second pass: select all envelope points and track last envelopes for focus
  local lastTrackEnvelope = nil
  local lastTakeEnvelope = nil

  for _, area in ipairs(areas) do
    if area.isEnvelope then
      local envelope, envIdx = FindEnvelopeByGuid(area.track, area.envGuid)
      if envelope then
        SelectPointsInEnvelope(envelope, area.startTime, area.endTime, 0)
        lastTrackEnvelope = envelope
      end
    else
      local takeEnv = SelectTakeEnvelopePoints(area.track, area)
      if takeEnv then
        lastTakeEnvelope = takeEnv
      end
    end
  end

  -- Set cursor context: envelope lanes take precedence, then take envelopes, then track/items
  if lastTrackEnvelope then
    reaper.SetCursorContext(2, lastTrackEnvelope)
  elseif lastTakeEnvelope then
    reaper.SetCursorContext(2, lastTakeEnvelope)
  else
    reaper.SetCursorContext(1)
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Select envelope points in razor edit area", -1)
  reaper.UpdateArrange()
end

Main()

