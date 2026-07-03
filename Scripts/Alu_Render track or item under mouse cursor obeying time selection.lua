-- @version 0.1.3
-- @changelog
--    + select track under mouse if no track is selected
--    + if no item selected, render from time selection bounds instead

local os_separator = package.config:sub(1,1)
function dofile_all(path)
    local i = 0
    while true do 
        local file = reaper.EnumerateFiles( path, i )
        i = i + 1
        if not file  then break end 
        dofile(path..os_separator..file)
    end
end

local info = debug.getinfo(1,'S')
local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]] -- this script folder
local folder_name = 'Functions'
dofile_all(script_path..os_separator..folder_name)

-------------------------------
-------   SCRIPT     ----------
-------------------------------
local proj = 0 -- define before use

-- MOD: Select track under mouse if no track selected
if reaper.CountSelectedTracks(0) == 0 then
    local track = reaper.GetTrackFromPoint(reaper.GetMousePosition())
    if track then
        reaper.SetOnlyTrackSelected(track)
    end
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local render = reaper.NamedCommandLookup( '_SWS_AWRENDERSTEREOSMART' )
local sel_items = CreateSelectedItemsTable(proj)

if #sel_items == 0 then
    -- MOD: If no items selected, render time selection on selected track
    local start_time, end_time = reaper.GetSet_LoopTimeRange2(proj, false, true, 0, 0, false)
    if start_time == end_time then
        reaper.ShowMessageBox("No items selected and no time selection set.", "Nothing to Render", 0)
        return
    end

    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
        reaper.ShowMessageBox("No track selected under mouse and no selected items.", "Error", 0)
        return
    end

    reaper.Main_OnCommand(render, 0) -- renders selected track(s) using time selection
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock2(proj, 'Render Time Selection on Selected Track', -1)
    reaper.UpdateArrange()
    reaper.UpdateTimeline()
    return
end

for k, item in ipairs(sel_items) do
    local track = reaper.GetMediaItem_Track(item)
    reaper.SetOnlyTrackSelected(track)

    local item_table_mute = {}
    for item_track in enumTrackItems(track) do
        local mute = reaper.GetMediaItemInfo_Value(item_track, 'B_MUTE')
        item_table_mute[item_track] = mute
        if item_track ~= item then
            reaper.SetMediaItemInfo_Value(item_track, 'B_MUTE', 1)
        end
    end

    local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local fim = pos + len
    local mute = reaper.GetMediaTrackInfo_Value(track, 'B_MUTE')

    reaper.GetSet_LoopTimeRange2(proj, true, true, pos, fim, false)
    reaper.Main_OnCommand(render, 0)

    reaper.SetMediaTrackInfo_Value(track, 'B_MUTE', mute)

    local take = reaper.GetActiveTake(item)
    local retval, name = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)

    local new_track = reaper.GetSelectedTrack(proj, 0)
    local new_item = reaper.GetTrackMediaItem(new_track,0)
    local new_take = reaper.GetActiveTake(new_item)

    reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME', name, true)
    reaper.GetSetMediaTrackInfo_String(new_track, 'P_NAME', name, true)

    for restore_item, mute_val in pairs(item_table_mute) do
        reaper.SetMediaItemInfo_Value(restore_item, 'B_MUTE', mute_val)
    end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.UpdateTimeline()
reaper.Undo_EndBlock2(proj, 'Render Selected Items in New Tracks', -1)

