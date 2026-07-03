-- Paste all copied take envelopes from ExtState to selected items
-- @author Alejandro (Alu) 

-- Get stored data (correct!)
local data = reaper.GetExtState("TakeEnvelopeCopy", "Data")
if data == "" or data == nil then
  reaper.ShowMessageBox("No copied data found! Run the copy script first.", "Error", 0)
  return
end

-- Helper: split string by separator
local function split(s, sep)
  local t = {}
  for str in string.gmatch(s, "([^"..sep.."]+)") do
    table.insert(t, str)
  end
  return t
end

-- Helper: parse stored string
local function deserialize(data)
  local lines = {}
  for line in data:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local result = {}
  for _, line in ipairs(lines) do
    local parts = split(line, "|")
    local take_guid = parts[1]
    local env_name = parts[2]
    local points = {}

    for i = 3, #parts do
      local nums = split(parts[i], ",")
      table.insert(points, {
        time = tonumber(nums[1]),
        value = tonumber(nums[2]),
        shape = tonumber(nums[3]),
        tension = tonumber(nums[4])
      })
    end

    table.insert(result, {take_guid = take_guid, env_name = env_name, points = points})
  end
  return result
end

local copied = deserialize(data)

-- Make sure there are selected items to paste to
local num_sel_items = reaper.CountSelectedMediaItems(0)
if num_sel_items == 0 then
  reaper.ShowMessageBox("No selected items to paste to!", "Error", 0)
  return
end

reaper.Undo_BeginBlock()

for i = 0, num_sel_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take and reaper.ValidatePtr(take, "MediaItem_Take*") then
    for _, env_data in ipairs(copied) do
      -- Find existing take envelope by name
      local env = nil
      local env_idx = 0
      while true do
        env = reaper.GetTakeEnvelope(take, env_idx)
        if not env then break end
        local retval, env_name = reaper.GetEnvelopeName(env, "")
        if env_name == env_data.env_name then
          break
        end
        env = nil
        env_idx = env_idx + 1
      end

      -- If not found, try to create it (standard only)
      if not env then
        if env_data.env_name == "Volume" then
          reaper.Main_OnCommand(40693, 0) -- Take volume envelope
        elseif env_data.env_name == "Pan" then
          reaper.Main_OnCommand(40694, 0) -- Take pan envelope
        elseif env_data.env_name == "Pitch" then
          reaper.Main_OnCommand(40695, 0) -- Take pitch envelope
        elseif env_data.env_name == "Mute" then
          reaper.Main_OnCommand(40696, 0) -- Take mute envelope
        end

        -- Try to get again
        env_idx = 0
        while true do
          env = reaper.GetTakeEnvelope(take, env_idx)
          if not env then break end
          local retval, env_name = reaper.GetEnvelopeName(env, "")
          if env_name == env_data.env_name then
            break
          end
          env = nil
          env_idx = env_idx + 1
        end
      end

      -- Paste points if envelope found/created
      if env then
        for _, pt in ipairs(env_data.points) do
          reaper.InsertEnvelopePoint(env, pt.time, pt.value, pt.shape, pt.tension, false, true)
        end
        reaper.Envelope_SortPoints(env)
      end
    end
  end
end

reaper.Undo_EndBlock("Paste take envelopes", -1)

