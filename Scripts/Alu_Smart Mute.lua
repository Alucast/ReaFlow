--[[
@description Smart Mute
@version 1.10
@about
  # Smart Mute
  Mutes based on mouse context. Razor Edit support, no external dependencies.
  - Toggle mute for items, tracks, razor edits, and time selections
  - Envelope razor edits are zeroed with small ramps at edges (respects envelope type)
  - Envelope bypass toggle when hovering over an envelope lane with no razor edit
  - Respects per-item lock state
@changelog
  - Razor edits on track take priority over envelope bypass (even with lanes open)
  - Razor edits on any envelope lane now take priority over bypass toggle
  - Fixed pan zero value to center (0.0 in REAPER's internal -1 to 1 range)
  - Fixed width zero value to 1.0 (100%)
  - Removed FX parameter envelope support (too unpredictable)
  - Respects per-item lock state (locked items are skipped during razor splits)
  - Added envelope bypass toggle when no razor edit on hovered envelope lane
  - Removed external library dependency
  - Added Razor Edit split-and-mute with toggle support
  - Added MCP context support
  - Added time selection fallback
  - Added envelope razor edit support with ramped edges
  - Improved undo strings
--]]

-- @author Alejandro (Alu) 

---------------------------------------------------------------
-- Debug toggle (set to true only for troubleshooting)
---------------------------------------------------------------
local DEBUG = false

local function dbg(...)
  if not DEBUG then return end
  local args = {...}
  local msg = ""
  for i = 1, #args do
    msg = msg .. tostring(args[i]) .. "  "
  end
  reaper.ShowConsoleMsg(msg .. "\n")
end

---------------------------------------------------------------
-- Inlined library functions
---------------------------------------------------------------

local function initMouseCaseTables()
  local mouse = {}
  mouse.ruler = {}
  mouse.tcp = {}
  mouse.mcp = {}
  mouse.arrange = {}
  mouse.arrange.track = {}
  mouse.arrange.envelope = {}
  mouse.midi_editor = {}
  mouse.midi_editor.cc_lane = {}
  return mouse
end

local function executeMouseContextFunction(mouse)
  local mouseWindow, mouseContext, mouseDetails = reaper.BR_GetMouseCursorContext()
  dbg("CONTEXT:", "window=" .. tostring(mouseWindow), "segment=" .. tostring(mouseContext), "details=" .. tostring(mouseDetails))

  if mouseWindow ~= "" then
    if mouseContext ~= "" then
      if mouseDetails ~= "" then
        if mouse[mouseWindow] and mouse[mouseWindow][mouseContext] and mouse[mouseWindow][mouseContext][mouseDetails] then
          dbg("MATCHED:", mouseWindow .. "." .. mouseContext .. "." .. mouseDetails)
          mouse[mouseWindow][mouseContext][mouseDetails][1](table.unpack(mouse[mouseWindow][mouseContext][mouseDetails], 2))
          return true
        end
      else
        if mouse[mouseWindow] and mouse[mouseWindow][mouseContext] then
          dbg("MATCHED:", mouseWindow .. "." .. mouseContext)
          mouse[mouseWindow][mouseContext][1](table.unpack(mouse[mouseWindow][mouseContext], 2))
          return true
        end
      end
    else
      if mouse[mouseWindow] then
        dbg("MATCHED:", mouseWindow)
        mouse[mouseWindow][1](table.unpack(mouse[mouseWindow], 2))
        return true
      end
    end
  end
  if mouse.default then
    dbg("DEFAULT")
    mouse.default[1](table.unpack(mouse.default, 2))
    return true
  end
  return false
end

---------------------------------------------------------------
-- State management
---------------------------------------------------------------

function saveOriginalState()
  local originalState = {}
  originalState.editCur = reaper.GetCursorPositionEx(0)
  originalState.timeSelStart, originalState.timeSelEnd = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)

  originalState.selTracks = {}
  for i = 1, reaper.CountSelectedTracks2(0, true), 1 do
    originalState.selTracks[#originalState.selTracks + 1] = reaper.GetSelectedTrack2(0, i - 1, true)
  end

  originalState.selItems = {}
  for i = 1, reaper.CountSelectedMediaItems(0), 1 do
    originalState.selItems[i] = reaper.GetSelectedMediaItem(0, i - 1)
  end

  originalState.lockWasEnabled = reaper.GetToggleCommandStateEx(0, 1135)
  reaper.Main_OnCommand(40570, 0) -- disable locking

  originalState.autoFadeWasEnabled = reaper.GetToggleCommandStateEx(0, 40041)
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_XFDOFF"), 0) -- turn off auto-crossfade

  dbg("STATE SAVED:", "#tracks=" .. #originalState.selTracks, "#items=" .. #originalState.selItems)
  return originalState
end

function restoreOriginalState(originalState)
  reaper.SetEditCurPos2(0, originalState.editCur, false, false)
  reaper.GetSet_LoopTimeRange2(0, true, true, originalState.timeSelStart, originalState.timeSelEnd, false)

  reaper.Main_OnCommand(40297, 0) -- unselect all tracks
  for i = 1, #originalState.selTracks, 1 do
    reaper.SetTrackSelected(originalState.selTracks[i], true)
  end

  reaper.SelectAllMediaItems(0, false)
  for i = 1, #originalState.selItems, 1 do
    reaper.SetMediaItemSelected(originalState.selItems[i], true)
  end

  if originalState.lockWasEnabled == 1 then reaper.Main_OnCommand(40569, 0) end
  if originalState.autoFadeWasEnabled == 1 then reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_XFDON"), 0) end
  dbg("STATE RESTORED")
end

---------------------------------------------------------------
-- Core mute functions
---------------------------------------------------------------

function muteItems()
  local mouseItem = reaper.BR_GetMouseCursorContext_Item()
  dbg("muteItems() called, mouseItem=", tostring(mouseItem))

  if not mouseItem then
    dbg("ERROR: mouseItem is nil")
    return
  end

  for i = 1, #originalState.selItems, 1 do
    if mouseItem == originalState.selItems[i] then
      dbg("Item was already selected, muting selection")
      reaper.Main_OnCommand(40175, 0) -- mute items
      return
    end
  end

  dbg("Item not in selection, selecting and muting")
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(mouseItem, true)
  reaper.Main_OnCommand(40175, 0) -- mute Items
end

function muteTracks()
  local mouseTrack = reaper.BR_GetMouseCursorContext_Track()
  dbg("muteTracks() called, mouseTrack=", tostring(mouseTrack))

  if not mouseTrack then
    dbg("ERROR: mouseTrack is nil")
    return
  end

  for i = 1, #originalState.selTracks, 1 do
    if mouseTrack == originalState.selTracks[i] then
      dbg("Track was already selected, muting selection")
      reaper.Main_OnCommand(6, 0) -- mute tracks
      return
    end
  end

  dbg("Track not in selection, selecting and muting")
  reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
  reaper.SetTrackSelected(mouseTrack, true)
  reaper.Main_OnCommand(6, 0) -- mute tracks
end

---------------------------------------------------------------
-- Razor Edit functions
---------------------------------------------------------------

function parseRazorEdits(razorStr)
  local mediaEdits = {}
  local envEdits = {}
  local pos = 1

  while pos <= #razorStr do
    -- Parse start time
    local s, e, startStr = string.find(razorStr, "^%s*([%d%.]+)", pos)
    if not startStr then break end
    local startTime = tonumber(startStr)
    pos = e + 1

    -- Parse end time
    s, e, endStr = string.find(razorStr, "^%s*([%d%.]+)", pos)
    if not endStr then break end
    local endTime = tonumber(endStr)
    pos = e + 1

    -- Parse env index: quoted string, number, or unquoted identifier
    local envIdx
    s, e, envIdx = string.find(razorStr, "^%s*\"([^\"]*)\"", pos)
    if envIdx then
      pos = e + 1
      -- Empty quotes mean media items in some REAPER builds
      if envIdx == "" then envIdx = -1 end
    else
      s, e, envIdx = string.find(razorStr, "^%s*(-?%d+)", pos)
      if envIdx then
        envIdx = tonumber(envIdx)
        pos = e + 1
      else
        -- Try unquoted word/identifier (like <VOLENV or GUIDs without quotes)
        s, e, envIdx = string.find(razorStr, "^%s*([%w_<>{}%-]+)", pos)
        if envIdx then
          pos = e + 1
        else
          break
        end
      end
    end

    if envIdx == -1 then
      table.insert(mediaEdits, {start = startTime, ending = endTime})
    else
      table.insert(envEdits, {start = startTime, ending = endTime, env = tostring(envIdx)})
    end
  end

  return mediaEdits, envEdits
end

function getAllRazorEditsInProject()
  local allMediaEdits = {}
  local allEnvEdits = {}
  local trackCount = reaper.CountTracks(0)

  for t = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, t)
    local retval, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    if retval and razorStr ~= "" then
      local mediaEdits, envEdits = parseRazorEdits(razorStr)
      if #mediaEdits > 0 then
        allMediaEdits[track] = mediaEdits
      end
      if #envEdits > 0 then
        allEnvEdits[track] = envEdits
      end
    end
  end

  return allMediaEdits, allEnvEdits
end

function countRazorEdits(allMediaEdits, allEnvEdits)
  local mediaCount = 0
  for _, edits in pairs(allMediaEdits) do
    mediaCount = mediaCount + #edits
  end
  local envCount = 0
  for _, edits in pairs(allEnvEdits) do
    envCount = envCount + #edits
  end
  return mediaCount, envCount
end

-- Get the envelope config string from its chunk (e.g. "<VOLENV", "<PANENV", "<FXPARM")
function getEnvelopeConfigString(env)
  local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not retval then return nil end
  return chunk:match("^%s*(<[^%s>]+)")
end

-- Get the EGUID from the envelope chunk
function getEnvelopeGUIDFromChunk(env)
  local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not retval then return nil end
  return chunk:match("EGUID%s+(%b{})")
end

function getEnvelopeRazorId(env)
  local guid = getEnvelopeGUIDFromChunk(env)
  if guid then return guid end
  local config = getEnvelopeConfigString(env)
  if config then return config end
  local retval, name = reaper.GetEnvelopeName(env)
  return name
end

function getTrackEnvelopeByIdentifier(track, envId)
  envId = tostring(envId)
  dbg("Looking for envelope:", envId)

  -- 1. Try matching by EGUID first (FX parameter envelopes use GUIDs)
  for i = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    local guid = getEnvelopeGUIDFromChunk(env)
    if guid and guid == envId then
      dbg("Found by EGUID")
      return env
    end
  end

  -- 2. Try matching by chunk config string (built-in envelopes like <VOLENV)
  for i = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    local configStr = getEnvelopeConfigString(env)
    if configStr and configStr == envId then
      dbg("Found by config string")
      return env
    end
  end

  -- 3. Fallback: try matching by display name
  for i = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    local retval, name = reaper.GetEnvelopeName(env)
    if name == envId then
      dbg("Found by display name")
      return env
    end
  end

  dbg("ENVELOPE NOT FOUND")
  return nil
end

function getEnvelopeRazorEdits(track, env)
  local edits = {}
  local envId = getEnvelopeRazorId(env)
  local retval, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  if not retval or razorStr == "" then return edits end

  local _, envEdits = parseRazorEdits(razorStr)
  for _, edit in ipairs(envEdits) do
    if edit.env == envId then
      table.insert(edits, edit)
    end
  end
  return edits
end

-- Get ALL razor edits for a specific track (both media and envelope)
function getTrackRazorEdits(track)
  local retval, razorStr = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  if not retval or razorStr == "" then return {}, {} end

  return parseRazorEdits(razorStr)
end

-- Check if track has ANY razor edits (media or envelope)
function trackHasRazorEdits(track)
  local mediaEdits, envEdits = getTrackRazorEdits(track)
  return (#mediaEdits > 0) or (#envEdits > 0)
end

-- Returns the proper "zero" / neutral value for an envelope type
-- Returns nil if the envelope type should be skipped (FX parameters)
function getEnvelopeNeutralValue(env)
  local configStr = getEnvelopeConfigString(env)
  if not configStr then return nil end

  -- Volume envelopes: 0 = -inf dB
  if configStr:match("VOLENV") and not configStr:match("SENDVOLENV") then
    return 0
  end

  -- Pan envelopes: REAPER internal range is -1 to 1, 0 = center
  if configStr:match("PANENV") then
    return 0
  end

  -- Width envelopes: REAPER internal range is -1 to 1, 1 = 100% width
  if configStr:match("WIDTHENV") then
    return 1
  end

  -- Send volume: same as track volume
  if configStr:match("SENDVOLENV") then
    return 0
  end

  -- Send pan: same as track pan, 0 = center
  if configStr:match("SENDPANENV") then
    return 0
  end

  -- Mute envelopes: 1 = muted
  if configStr:match("MUTEENV") then
    return 1
  end

  -- Skip FX parameter envelopes entirely (too unpredictable)
  if configStr:match("FXPARM") or configStr:match("PARMENV") then
    return nil
  end

  -- Unknown envelope type: skip to be safe
  return nil
end

function isItemLocked(item)
  local lockState = reaper.GetMediaItemInfo_Value(item, "C_LOCK")
  return lockState ~= 0
end

function toggleRazorEdit(track, startTime, endTime)
  local itemsToProcess = {}
  local allMuted = true

  -- First pass: collect overlapping items and determine target state (skip locked items)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)

    -- Skip locked items entirely
    if isItemLocked(item) then
      dbg("SKIPPING LOCKED ITEM:", i)
      goto continue
    end

    local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local itemEnd = itemStart + itemLength

    if itemStart < endTime and itemEnd > startTime then
      table.insert(itemsToProcess, item)
      if reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
        allMuted = false
      end
    end

    ::continue::
  end

  if #itemsToProcess == 0 then return end

  local targetMute = allMuted and 0 or 1
  dbg("RAZOR TOGGLE:", allMuted and "UNMUTING" or "MUTING", "#items=" .. #itemsToProcess)

  -- Second pass: split and apply target state
  for _, item in ipairs(itemsToProcess) do
    local currentItem = item
    local itemStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")

    if itemStart < startTime then
      local newItem = reaper.SplitMediaItem(currentItem, startTime)
      if newItem then
        currentItem = newItem
      end
    end

    local currentStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")
    local currentLength = reaper.GetMediaItemInfo_Value(currentItem, "D_LENGTH")
    local currentEnd = currentStart + currentLength

    if currentEnd > endTime then
      reaper.SplitMediaItem(currentItem, endTime)
    end

    local finalStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")
    local finalLength = reaper.GetMediaItemInfo_Value(currentItem, "D_LENGTH")
    local finalEnd = finalStart + finalLength

    if finalStart >= startTime - 0.0001 and finalEnd <= endTime + 0.0001 then
      reaper.SetMediaItemInfo_Value(currentItem, "B_MUTE", targetMute)
    end
  end
end

function muteEnvelopeRazorEdit(track, startTime, endTime, envId)
  local env = getTrackEnvelopeByIdentifier(track, envId)
  if not env then
    dbg("ENVELOPE NOT FOUND:", envId)
    return
  end

  -- Check if this envelope type is supported
  local muteVal = getEnvelopeNeutralValue(env)
  if muteVal == nil then
    dbg("SKIPPING UNSUPPORTED ENVELOPE TYPE:", getEnvelopeConfigString(env))
    return
  end

  dbg("MUTING ENVELOPE:", envId, startTime, endTime, "neutral=", muteVal)

  -- Evaluate values at edges to preserve outside behavior
  local _, valAtStart = reaper.Envelope_Evaluate(env, startTime, 0, 0)
  local _, valAtEnd = reaper.Envelope_Evaluate(env, endTime, 0, 0)

  -- Delete existing points in the razor region
  reaper.DeleteEnvelopePointRange(env, startTime, endTime)

  local width = endTime - startTime
  local rampSize = width * 0.05  -- 5% ramp on each side

  -- Clamp minimum ramp to avoid overlapping points on tiny selections
  local minRamp = math.min(0.001, width * 0.025)
  if rampSize < minRamp then rampSize = minRamp end

  local innerStart = startTime + rampSize
  local innerEnd = endTime - rampSize

  -- Ensure inner points don't cross
  if innerStart >= innerEnd then
    local mid = (startTime + endTime) / 2
    innerStart = mid - 0.0005
    innerEnd = mid + 0.0005
  end

  -- Four points: edge -> inner (ramp down) -> inner (flat) -> edge (ramp up)
  reaper.InsertEnvelopePoint(env, startTime, valAtStart, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, innerStart, muteVal, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, innerEnd, muteVal, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, endTime, valAtEnd, 0, 0, false, true)

  reaper.Envelope_SortPoints(env)
end

function toggleEnvelopeBypass(env)
  local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not retval then return end

  local currentState = chunk:match("ACT%s+(%d)")
  if not currentState then return end

  local newState = (tonumber(currentState) == 1) and "0" or "1"
  local newChunk = chunk:gsub("(ACT%s+)%d", "%1" .. newState)

  reaper.SetEnvelopeStateChunk(env, newChunk, false)
end

---------------------------------------------------------------
-- Time Selection fallback
---------------------------------------------------------------

function toggleTimeSelection(startTime, endTime)
  local itemsToProcess = {}
  local allMuted = true

  -- Collect all items overlapping the time selection across all tracks (skip locked)
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)

      -- Skip locked items
      if isItemLocked(item) then
        goto continue
      end

      local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local itemEnd = itemStart + itemLength

      if itemStart < endTime and itemEnd > startTime then
        table.insert(itemsToProcess, item)
        if reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
          allMuted = false
        end
      end

      ::continue::
    end
  end

  if #itemsToProcess == 0 then return end

  local targetMute = allMuted and 0 or 1

  for _, item in ipairs(itemsToProcess) do
    local currentItem = item
    local itemStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")

    if itemStart < startTime then
      local newItem = reaper.SplitMediaItem(currentItem, startTime)
      if newItem then currentItem = newItem end
    end

    local currentStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")
    local currentLength = reaper.GetMediaItemInfo_Value(currentItem, "D_LENGTH")
    local currentEnd = currentStart + currentLength

    if currentEnd > endTime then
      reaper.SplitMediaItem(currentItem, endTime)
    end

    local finalStart = reaper.GetMediaItemInfo_Value(currentItem, "D_POSITION")
    local finalEnd = finalStart + reaper.GetMediaItemInfo_Value(currentItem, "D_LENGTH")

    if finalStart >= startTime - 0.0001 and finalEnd <= endTime + 0.0001 then
      reaper.SetMediaItemInfo_Value(currentItem, "B_MUTE", targetMute)
    end
  end
end

---------------------------------------------------------------
-- Main
---------------------------------------------------------------

local function main()
  dbg("=== SCRIPT START ===")
  originalState = saveOriginalState()

  local mouseWindow, mouseContext, mouseDetails = reaper.BR_GetMouseCursorContext()
  local mouseTrack = reaper.BR_GetMouseCursorContext_Track()
  local mouseEnv = reaper.BR_GetMouseCursorContext_Envelope()
  dbg("MOUSE WINDOW:", tostring(mouseWindow), tostring(mouseContext), tostring(mouseDetails))
  dbg("MOUSE ENV:", tostring(mouseEnv))

  local undoDesc = "Smart Mute"

  -- ARRANGE VIEW: Check track under mouse first, then project-wide
  if mouseWindow == "arrange" and mouseTrack then
    local trackMediaEdits, trackEnvEdits = getTrackRazorEdits(mouseTrack)
    local hasTrackMediaRazors = #trackMediaEdits > 0
    local hasTrackEnvRazors = #trackEnvEdits > 0

    -- 1. Any envelope razor edits on THIS track → process all of them
    if hasTrackEnvRazors then
      dbg("PROCESSING ENVELOPE RAZOR EDITS ON TRACK:", #trackEnvEdits)
      for _, edit in ipairs(trackEnvEdits) do
        muteEnvelopeRazorEdit(mouseTrack, edit.start, edit.ending, edit.env)
      end
      restoreOriginalState(originalState)
      dbg("=== SCRIPT END (Track Env Razors) ===\n")
      return "Smart Mute: Track envelope razor(s)"
    end

    -- 2. Any media-item razor edits on THIS track → process all of them
    if hasTrackMediaRazors then
      dbg("PROCESSING MEDIA RAZOR EDITS ON TRACK:", #trackMediaEdits)
      for _, edit in ipairs(trackMediaEdits) do
        toggleRazorEdit(mouseTrack, edit.start, edit.ending)
      end
      restoreOriginalState(originalState)
      dbg("=== SCRIPT END (Track Media Razors) ===\n")
      return "Smart Mute: Track razor area(s)"
    end

    -- 3. No razors on this track, but mouse is over envelope lane → toggle bypass
    if mouseEnv then
      dbg("TOGGLING ENVELOPE BYPASS")
      toggleEnvelopeBypass(mouseEnv)
      restoreOriginalState(originalState)
      dbg("=== SCRIPT END (Env Bypass) ===\n")
      return "Smart Mute: Toggle envelope bypass"
    end
  end

  -- 4. Project-wide razor edits (when not on a track with razors, or no track under mouse)
  if mouseWindow == "arrange" then
    local allMediaEdits, allEnvEdits = getAllRazorEditsInProject()
    local mediaCount, envCount = countRazorEdits(allMediaEdits, allEnvEdits)

    if mediaCount > 0 or envCount > 0 then
      -- Build descriptive undo string
      if mediaCount > 0 and envCount > 0 then
        undoDesc = string.format("Smart Mute: %d razor area(s), %d env razor(s)", mediaCount, envCount)
      elseif mediaCount > 0 then
        undoDesc = string.format("Smart Mute: %d razor area(s)", mediaCount)
      else
        undoDesc = string.format("Smart Mute: %d env razor(s)", envCount)
      end

      dbg("PROCESSING ALL RAZOR EDITS:", undoDesc)

      -- Process media item razors
      for track, edits in pairs(allMediaEdits) do
        for _, edit in ipairs(edits) do
          toggleRazorEdit(track, edit.start, edit.ending)
        end
      end

      -- Process envelope razors
      for track, edits in pairs(allEnvEdits) do
        for _, edit in ipairs(edits) do
          muteEnvelopeRazorEdit(track, edit.start, edit.ending, edit.env)
        end
      end

      restoreOriginalState(originalState)
      dbg("=== SCRIPT END (Razor) ===\n")
      return undoDesc
    end
    dbg("No razor edits found, falling through to contextual")
  end

  -- 5. Try specific mouse contexts (items, TCP, MCP)
  local mouse = initMouseCaseTables()
  mouse.arrange.track.item = {muteItems}
  mouse.arrange.track.item_stretch_marker = {muteItems}
  mouse.arrange.track.empty = {muteTracks}
  mouse.tcp.track = {muteTracks}
  mouse.mcp.track = {muteTracks}

  local executed = executeMouseContextFunction(mouse)

  if executed then
    -- Build undo string based on what was matched
    if mouseWindow == "arrange" then
      if mouseDetails == "item" or mouseDetails == "item_stretch_marker" then
        undoDesc = "Smart Mute: Item"
      elseif mouseDetails == "empty" then
        undoDesc = "Smart Mute: Track"
      else
        undoDesc = "Smart Mute: Arrange"
      end
    elseif mouseWindow == "tcp" then
      undoDesc = "Smart Mute: TCP Track"
    elseif mouseWindow == "mcp" then
      undoDesc = "Smart Mute: MCP Track"
    end
  else
    -- 6. Time selection fallback (arrange view only)
    if mouseWindow == "arrange" then
      local tsStart, tsEnd = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
      if tsStart ~= tsEnd then
        dbg("TIME SELECTION FALLBACK:", tsStart, tsEnd)
        toggleTimeSelection(tsStart, tsEnd)
        undoDesc = "Smart Mute: Time selection"
      end
    end
  end

  restoreOriginalState(originalState)
  dbg("=== SCRIPT END ===\n")
  return undoDesc
end

---------------------------------------------------------------
local reaper = reaper

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

local undoDescription = main()

reaper.Undo_EndBlock2(0, undoDescription, 0)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
