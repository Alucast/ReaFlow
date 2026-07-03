-- @description Add 4-frame crossfades between selected items (dialogue editing)
-- @author Alu
-- @version 1.5
-- @about
--   Adds 4-frame fade in/out to selected items and extends them so fades 
--   overlap for smooth dialogue crossfades across tracks. Uses native REAPER 
--   actions for edge extension (no manual offset math).
--   Preserves existing fades — only adds fades where none exist.
--
--   SETUP: Select items in chronological order across tracks, then run.

-- ============================================================
-- CONFIGURATION - Change these values to tweak behavior
-- ============================================================
local EXTEND_ITEMS = true        -- Set to false to skip item extension
local FADE_FRAMES = 4            -- Number of frames for fades
local FADE_SHAPE = 0             -- 0=linear, 1=equal gain, 2=equal power, 3=fast start, 4=slow start, 5=bezier
local CROSSFADE_ONLY_DIFF_TRACKS = true  -- Only crossfade items on different tracks
-- ============================================================

function frameToTime(frames)
    local fps = reaper.TimeMap_curFrameRate(0)
    return frames / fps
end

function getItemInfo(item)
    local track = reaper.GetMediaItem_Track(item)
    local trackIdx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local endPos = pos + len
    local fadeInLen = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    local fadeOutLen = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
    return {
        item = item,
        track = track,
        trackIdx = trackIdx,
        pos = pos,
        len = len,
        endPos = endPos,
        fadeInLen = fadeInLen,
        fadeOutLen = fadeOutLen,
        take = reaper.GetActiveTake(item)
    }
end

function sortItemsByTime(items)
    table.sort(items, function(a, b)
        if math.abs(a.pos - b.pos) < 0.0001 then
            return a.trackIdx < b.trackIdx
        end
        return a.pos < b.pos
    end)
    return items
end

function applyFades(item, fadeIn, fadeOut)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fadeIn)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fadeOut)
    reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", FADE_SHAPE)
    reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", FADE_SHAPE)
end

function extendItemRightEdge(item, newEndPos)
    reaper.Main_OnCommand(40289, 0)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetEditCurPos(newEndPos, false, false)
    reaper.Main_OnCommand(41311, 0)
end

function extendItemLeftEdge(item, newStartPos)
    reaper.Main_OnCommand(40289, 0)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetEditCurPos(newStartPos, false, false)
    reaper.Main_OnCommand(41305, 0)
end

function main()
    local count = reaper.CountSelectedMediaItems(0)
    if count < 1 then
        reaper.ShowMessageBox("Please select at least 1 item.", "Crossfade Tool", 0)
        return
    end

    -- Collect selected items
    local items = {}
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        table.insert(items, getItemInfo(item))
    end

    items = sortItemsByTime(items)

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Save current selection state
    local origSelection = {}
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        origSelection[item] = true
    end

    local fadeTime = frameToTime(FADE_FRAMES)

    -- ============================================================
    -- FIRST PASS: Apply fades to ALL items based on their position
    -- Only add fades where they don't already exist
    -- ============================================================
    for i, itemInfo in ipairs(items) do
        local fadeIn = itemInfo.fadeInLen  -- Keep existing
        local fadeOut = itemInfo.fadeOutLen  -- Keep existing

        if i == 1 then
            -- First item: add fade-out if none exists
            if fadeOut == 0 then fadeOut = fadeTime end
        elseif i == #items then
            -- Last item: add fade-in if none exists
            if fadeIn == 0 then fadeIn = fadeTime end
        else
            -- Middle items: add both if none exist
            if fadeIn == 0 then fadeIn = fadeTime end
            if fadeOut == 0 then fadeOut = fadeTime end
        end

        applyFades(itemInfo.item, fadeIn, fadeOut)
    end

    -- ============================================================
    -- SECOND PASS: Extend edges for adjacent pairs
    -- ============================================================
    for i = 1, #items - 1 do
        local curr = items[i]
        local nextItem = items[i + 1]

        local shouldProcess = true
        if CROSSFADE_ONLY_DIFF_TRACKS and curr.trackIdx == nextItem.trackIdx then
            shouldProcess = false
        end

        if shouldProcess and EXTEND_ITEMS then
            local midPoint = (curr.endPos + nextItem.pos) / 2
            local newCurrEnd = midPoint + fadeTime / 2
            local newNextStart = midPoint - fadeTime / 2

            extendItemRightEdge(curr.item, newCurrEnd)
            extendItemLeftEdge(nextItem.item, newNextStart)

            curr.endPos = reaper.GetMediaItemInfo_Value(curr.item, "D_POSITION") + 
                          reaper.GetMediaItemInfo_Value(curr.item, "D_LENGTH")
            nextItem.pos = reaper.GetMediaItemInfo_Value(nextItem.item, "D_POSITION")
        end
    end

    -- Restore original selection
    reaper.Main_OnCommand(40289, 0)
    for item, _ in pairs(origSelection) do
        reaper.SetMediaItemSelected(item, true)
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Add 4-frame crossfades (extend=" .. tostring(EXTEND_ITEMS) .. ")", -1)
end

main()

