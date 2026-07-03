-- AI_Region Workflow - frame-rate aware
-- Quantizes item positions and region bounds to the current project frame rate.
-- Keeps item lengths unchanged.
-- @author Alejandro (Alu) 

-- CONFIG =========================================
local min_gap = 5 -- seconds between items/regions after collision handling

local extensions = {
    ".mp4",
    ".wav",
    ".mov",
    ".mp3",
    ".mkv"
}
-- =================================================

local function remove_extensions(name)
    local changed = true

    while changed do
        changed = false
        for _, ext in ipairs(extensions) do
            if name:lower():sub(-#ext) == ext then
                name = name:sub(1, -(#ext + 1))
                changed = true
            end
        end
    end

    return name
end

local function get_project_fps()
    local fps = reaper.TimeMap_curFrameRate(0)
    if not fps or fps <= 0 then
        fps = 24.0
    end
    return fps
end

local FPS = get_project_fps()
local FRAME = 1.0 / FPS

local function quantize_to_frame(time)
    local frames = math.floor((time * FPS) + 0.5)
    return frames / FPS
end

local function ceil_to_frame(time)
    local frames = math.ceil((time * FPS) - 1e-9)
    return frames / FPS
end

-- =========================================
-- STEP 1: GET ITEMS
-- =========================================

local items = {}
local sel_count = reaper.CountSelectedMediaItems(0)

if sel_count > 0 then
    for i = 0, sel_count - 1 do
        table.insert(items, reaper.GetSelectedMediaItem(0, i))
    end
else
    local total = reaper.CountMediaItems(0)
    for i = 0, total - 1 do
        table.insert(items, reaper.GetMediaItem(0, i))
    end
end

-- =========================================
-- STEP 2: PREP DATA
-- =========================================

local data = {}

for _, item in ipairs(items) do
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local take = reaper.GetActiveTake(item)
    local name = take and reaper.GetTakeName(take) or "Region"

    table.insert(data, {
        item = item,
        pos = pos,
        length = length,
        name = name
    })
end

table.sort(data, function(a, b) return a.pos < b.pos end)

-- =========================================
-- STEP 3: MOVE ITEMS + CREATE REGIONS
-- =========================================

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local last_end = -math.huge

for _, d in ipairs(data) do
    local new_name = remove_extensions(d.name)

    -- Quantize ONLY the start position
    local new_pos = quantize_to_frame(d.pos)

    -- Collision avoidance
    if new_pos < last_end + min_gap then
        new_pos = ceil_to_frame(last_end + min_gap)
    end

    -- Keep original item length unchanged
    local item_length = d.length
    local new_end = new_pos + item_length

    -- Safety: ensure at least 1 frame long
    if new_end <= new_pos then
        new_end = new_pos + FRAME
    end

    last_end = new_end

    -- Move item only, do NOT change its length
    reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", new_pos)

    -- Create region exactly matching the item length
    reaper.AddProjectMarker2(0, true, new_pos, new_end, new_name, -1, 0)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Quantize item positions and create matching regions", -1)
