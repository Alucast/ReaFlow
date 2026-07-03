-- Copy all active take envelopes from selected items
-- Stores in project extstate
-- @author Alejandro (Alu) 

local copied = {}

local num_sel_items = reaper.CountSelectedMediaItems(0)
if num_sel_items == 0 then return end

for i = 0, num_sel_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take and reaper.ValidatePtr(take, "MediaItem_Take*") then
    local env_idx = 0
    while true do
      local env = reaper.GetTakeEnvelope(take, env_idx)
      if not env then break end

      local retval, env_name = reaper.GetEnvelopeName(env, "")
      local num_points = reaper.CountEnvelopePoints(env)
      local points = {}

      for pt = 0, num_points - 1 do
        local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, pt)
        points[#points+1] = {time=time, value=value, shape=shape, tension=tension}
      end

      table.insert(copied, {take_guid = reaper.GetMediaItemTakeInfo_Value(take, "GUID"), env_name = env_name, points = points})
      env_idx = env_idx + 1
    end
  end
end

-- Serialize to ExtState (as JSON-ish string)
local function serialize(tbl)
  local json = ""
  for _, env in ipairs(tbl) do
    json = json .. env.take_guid .. "|" .. env.env_name
    for _, pt in ipairs(env.points) do
      json = json .. "|" .. pt.time .. "," .. pt.value .. "," .. pt.shape .. "," .. pt.tension
    end
    json = json .. "\n"
  end
  return json
end

local data = serialize(copied)
reaper.SetExtState("TakeEnvelopeCopy", "Data", data, false)

