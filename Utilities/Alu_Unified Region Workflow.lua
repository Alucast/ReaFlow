-- AI Unified Region Workflow - ReaImGui
-- Combines: Region Workflow, Color Regions, Snap In-Out SFX, Snap Items to Regions

-- ============================================================
-- DEPENDENCIES
-- ============================================================
if not reaper.ImGui_CreateContext then
  reaper.MB("Missing dependency: ReaImGui extension.\nDownload it via ReaPack (ReaTeam Extensions repository).", "Error", 0)
  return
end

local imgui_shim = reaper.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua'
if reaper.file_exists(imgui_shim) then
  dofile(imgui_shim)('0.8.6')
end

-- ============================================================
-- GLOBALS
-- ============================================================
local ctx
local font
local input_title = "Unified Region Workflow"

-- Status message
local status_msg = ""
local status_time = 0

-- --------------------------------------------------
-- Region Workflow Settings
-- --------------------------------------------------
local rw_min_gap = 5.0
local rw_extensions = ".mp4,.wav,.mov,.mp3,.mkv"
local rw_quantize = true

-- --------------------------------------------------
-- Snap Items Settings
-- --------------------------------------------------
local si_align_mode = 0      -- 0=LEFT, 1=CENTER, 2=RIGHT
local si_fallback_mode = 0   -- 0=OFF, 1=NEXT, 2=CLOSEST
local si_ignore_aligned = true
local si_prevent_multiple = true
local si_enable_norm = true
local si_enable_fuzzy = true
local si_fuzzy_threshold = 0.72

-- ============================================================
-- UTILITIES
-- ============================================================
local function SetStatus(msg)
  status_msg = msg
  status_time = reaper.time_precise()
end

local function DrawStatus()
  if status_msg ~= "" then
    local age = reaper.time_precise() - status_time
    if age < 5 then
      reaper.ImGui_Text(ctx, status_msg)
    else
      status_msg = ""
    end
  end
end

-- ============================================================
-- MODULE 1: REGION WORKFLOW
-- ============================================================
local function rw_remove_extensions(name, ext_list)
  local changed = true
  while changed do
    changed = false
    for _, ext in ipairs(ext_list) do
      if name:lower():sub(-#ext) == ext then
        name = name:sub(1, -(#ext + 1))
        changed = true
      end
    end
  end
  return name
end

local function rw_get_project_fps()
  local fps = reaper.TimeMap_curFrameRate(0)
  if not fps or fps <= 0 then fps = 24.0 end
  return fps
end

local function rw_quantize_to_frame(time, fps)
  local frames = math.floor((time * fps) + 0.5)
  return frames / fps
end

local function rw_ceil_to_frame(time, fps)
  local frames = math.ceil((time * fps) - 1e-9)
  return frames / fps
end

function Run_RegionWorkflow()
  -- Parse extensions
  local ext_list = {}
  for ext in rw_extensions:gmatch("[^,]+") do
    ext = ext:match("^%s*(.-)%s*$")
    if ext ~= "" then table.insert(ext_list, ext) end
  end

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

  if #items == 0 then
    SetStatus("Region Workflow: No items found!")
    return
  end

  local data = {}
  for _, item in ipairs(items) do
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take = reaper.GetActiveTake(item)
    local name = take and reaper.GetTakeName(take) or "Region"
    table.insert(data, {item=item, pos=pos, length=length, name=name})
  end

  table.sort(data, function(a,b) return a.pos < b.pos end)

  local fps = rw_get_project_fps()
  local frame = 1.0 / fps

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local last_end = -math.huge
  for _, d in ipairs(data) do
    local new_name = rw_remove_extensions(d.name, ext_list)
    local new_pos = d.pos
    if rw_quantize then
      new_pos = rw_quantize_to_frame(d.pos, fps)
    end

    if new_pos < last_end + rw_min_gap then
      new_pos = rw_ceil_to_frame(last_end + rw_min_gap, fps)
    end

    local item_length = d.length
    local new_end = new_pos + item_length
    if new_end <= new_pos then
      new_end = new_pos + frame
    end
    last_end = new_end

    reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", new_pos)
    reaper.AddProjectMarker2(0, true, new_pos, new_end, new_name, -1, 0)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("AI: Quantize items and create regions", -1)
  SetStatus("Region Workflow: Created " .. #data .. " regions")
end

-- ============================================================
-- MODULE 2: COLOR REGIONS
-- ============================================================
local function cr_extract_track_number(track_name)
  if not track_name then return nil end
  local num = track_name:match("^%s*(%d+)%s*$")
  if num then return tonumber(num) end
  return nil
end

local function cr_extract_region_part_number(region_name)
  if not region_name then return nil end
  local lower_name = region_name:lower()
  local num = lower_name:match("part%s*(%d+)")
  if num then return tonumber(num) end
  return nil
end

local function cr_build_track_color_map()
  local map = {}
  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local _, track_name = reaper.GetTrackName(track, "")
    local track_num = cr_extract_track_number(track_name)
    if track_num then
      local color = reaper.GetTrackColor(track)
      if color ~= 0 then
        map[track_num] = color
      end
    end
  end
  return map
end

function Run_ColorRegions()
  local color_map = cr_build_track_color_map()
  local retval, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions

  if total == 0 then
    SetStatus("Color Regions: No markers/regions found!")
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local changed = 0
  for i = 0, total - 1 do
    local retval2, isrgn, pos, rgnend, name, markrgnindexnumber, current_color =
      reaper.EnumProjectMarkers3(0, i)
    if isrgn then
      local part_num = cr_extract_region_part_number(name)
      if part_num then
        local track_color = color_map[part_num]
        if track_color and track_color ~= 0 then
          reaper.SetProjectMarkerByIndex2(0, i, true, pos, rgnend, markrgnindexnumber, name, track_color, 0)
          changed = changed + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("AI: Color regions from track colors", -1)
  SetStatus("Color Regions: Colored " .. changed .. " regions")
end

-- ============================================================
-- MODULE 3: SNAP IN-OUT SFX
-- ============================================================
local function sio_normalize_name(s)
  if not s then return "" end
  s = s:lower()
  s = s:gsub("\\", "/")
  s = s:match("([^/]+)$") or s
  s = s:gsub("%.[^.]+$", "")
  s = s:match("^%s*(.-)%s*$") or s
  return s
end

local function sio_get_take_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return name or ""
end

local function sio_get_source_filename(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then return "" end
  local retval, buf = reaper.GetMediaSourceFileName(source, "")
  if retval then return buf or "" end
  return ""
end

local function sio_classify_item(item)
  local take_name = sio_normalize_name(sio_get_take_name(item))
  local src_name = sio_normalize_name(sio_get_source_filename(item))

  local function is_match(target)
    return take_name == target or src_name == target
  end

  if is_match("entrada") then return "entrada"
  elseif is_match("salida a") then return "salida_a"
  elseif is_match("salida b") then return "salida_b"
  end
  return nil
end

local function sio_get_containing_region(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len

  local retval, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions

  for i = 0, total - 1 do
    local ok, isrgn, rgnstart, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      if item_end > rgnstart and item_pos < rgnend then
        return rgnstart, rgnend, name, idx
      end
    end
  end
  return nil
end

function Run_SnapInOut()
  local sel_count = reaper.CountSelectedMediaItems(0)
  if sel_count == 0 then
    SetStatus("Snap In-Out: No items selected!")
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local changed = 0
  for i = 0, sel_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local kind = sio_classify_item(item)
    if kind then
      local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local rgnstart, rgnend = sio_get_containing_region(item)
      if rgnstart then
        if kind == "entrada" then
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", rgnstart)
          reaper.UpdateItemInProject(item)
          changed = changed + 1
        elseif kind == "salida_a" or kind == "salida_b" then
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", rgnend - item_len)
          reaper.UpdateItemInProject(item)
          changed = changed + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("AI: Snap Entrada/Salida to regions", -1)
  SetStatus("Snap In-Out: Processed " .. changed .. " items")
end

-- ============================================================
-- MODULE 4: SNAP ITEMS TO REGIONS
-- ============================================================
local SI_EPSILON = 0.000001

local function si_nearly_equal(a, b)
  return math.abs(a - b) <= SI_EPSILON
end

local function si_lower(s)
  return string.lower(s or "")
end

local function si_trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function si_extract_part_number(name)
  local s = si_lower(name)
  local n = s:match("part[%s%-%_]*(%d+)") or
            s:match("pt[%s%-%_]*(%d+)") or
            s:match("p[%s%-%_]*(%d+)") or
            s:match("(%d+)%D*$")
  return n and tonumber(n) or nil
end

local function si_normalize_name(name)
  local s = si_lower(name or "")
  s = s:gsub("pt[%s%-%_]*(%d+)", "part%1")
  s = s:gsub("p[%s%-%_]*(%d+)", "part%1")
  s = s:gsub("part[%s%-%_]*(%d+)", function(num)
    return string.format("part%03d", tonumber(num))
  end)
  s = s:gsub("[_%-%./]", " ")
  s = s:gsub("%s+", " ")
  return si_trim(s)
end

local function si_tokenize(s)
  local t = {}
  for token in s:gmatch("%S+") do t[token] = true end
  return t
end

local function si_jaccard(a, b)
  local ta = si_tokenize(si_normalize_name(a))
  local tb = si_tokenize(si_normalize_name(b))

  local inter, union = 0, 0
  local seen = {}

  for k in pairs(ta) do
    union = union + 1
    seen[k] = true
    if tb[k] then inter = inter + 1 end
  end

  for k in pairs(tb) do
    if not seen[k] then union = union + 1 end
  end

  return union == 0 and 0 or (inter / union)
end

local function si_get_item_name(item)
  local take = reaper.GetActiveTake(item)
  if take then
    local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if name ~= "" then return name end
  end
  return ""
end

local function si_get_ref_point(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if si_align_mode == 1 then return pos + len * 0.5 end
  if si_align_mode == 2 then return pos + len end
  return pos
end

local function si_get_new_pos(item, regionPos)
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if si_align_mode == 1 then return regionPos - len * 0.5 end
  if si_align_mode == 2 then return regionPos - len end
  return regionPos
end

local function si_get_regions()
  local regions = {}
  local _, m, r = reaper.CountProjectMarkers(0)
  local total = m + r

  for i = 0, total - 1 do
    local _, isrgn, pos, _, name = reaper.EnumProjectMarkers3(0, i)
    if isrgn then
      regions[#regions+1] = {
        pos = pos,
        name = name or "",
        norm = si_normalize_name(name),
        part = si_extract_part_number(name),
        used = false
      }
    end
  end

  table.sort(regions, function(a,b) return a.pos < b.pos end)
  return regions
end

local function si_region_available(r)
  return not si_prevent_multiple or not r.used
end

local function si_match_region(itemName, regions)
  local part = si_extract_part_number(itemName)

  if part then
    for _, r in ipairs(regions) do
      if r.part == part and si_region_available(r) then
        return r
      end
    end
  end

  if si_enable_norm then
    local norm = si_normalize_name(itemName)
    for _, r in ipairs(regions) do
      if r.norm == norm and si_region_available(r) then
        return r
      end
    end
  end

  if si_enable_fuzzy then
    local best, bestScore = nil, 0
    for _, r in ipairs(regions) do
      if si_region_available(r) then
        local score = si_jaccard(itemName, r.name)
        if score > bestScore then
          bestScore = score
          best = r
        end
      end
    end
    if best and bestScore >= si_fuzzy_threshold then
      return best
    end
  end

  return nil
end

local function si_fallback(item, regions)
  local ref = si_get_ref_point(item)

  if si_fallback_mode == 1 then -- NEXT
    for _, r in ipairs(regions) do
      if si_region_available(r) and (r.pos >= ref) then
        return r
      end
    end
  elseif si_fallback_mode == 2 then -- CLOSEST
    local best, dist = nil, nil
    for _, r in ipairs(regions) do
      if si_region_available(r) then
        local d = math.abs(r.pos - ref)
        if not dist or d < dist then
          dist = d
          best = r
        end
      end
    end
    return best
  end

  return nil
end

function Run_SnapItems()
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    SetStatus("Snap Items: No items selected!")
    return
  end

  local regions = si_get_regions()
  if #regions == 0 then
    SetStatus("Snap Items: No regions found!")
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local moved = 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local name = si_get_item_name(item)

    local region = si_match_region(name, regions)
    if not region then
      region = si_fallback(item, regions)
    end

    if region then
      local ref = si_get_ref_point(item)
      if not (si_ignore_aligned and si_nearly_equal(ref, region.pos)) then
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", si_get_new_pos(item, region.pos))
        region.used = true
        moved = moved + 1
      end
    end
  end

  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("AI: Snap items to regions by name", -1)
  SetStatus("Snap Items: Moved " .. moved .. " items")
end

-- ============================================================
-- FULL WORKFLOW
-- ============================================================
function Run_FullWorkflow()
  Run_RegionWorkflow()
  Run_ColorRegions()
  Run_SnapInOut()
  Run_SnapItems()
  SetStatus("Full Workflow Complete!")
end

-- ============================================================
-- REAIMGUI UI
-- ============================================================
function Tab_RegionWorkflow()
  reaper.ImGui_Text(ctx, "Quantize item positions and create matching regions.")
  reaper.ImGui_Separator(ctx)

  local changed
  changed, rw_min_gap = reaper.ImGui_SliderDouble(ctx, "Min Gap (seconds)", rw_min_gap, 0.0, 30.0, "%.1f")
  changed, rw_extensions = reaper.ImGui_InputText(ctx, "Extensions (comma separated)", rw_extensions)
  changed, rw_quantize = reaper.ImGui_Checkbox(ctx, "Quantize to project frame rate", rw_quantize)

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, "Run Region Workflow", 200, 30) then
    Run_RegionWorkflow()
  end
  reaper.ImGui_Text(ctx, "Tip: Select items first, or it will process ALL items.")
end

function Tab_ColorRegions()
  reaper.ImGui_Text(ctx, "Color regions based on track colors by numeric name matching.")
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Tracks named '1', '2', etc. will color regions named 'part 1', 'part 2', etc.")

  if reaper.ImGui_Button(ctx, "Color Regions from Tracks", 200, 30) then
    Run_ColorRegions()
  end
end

function Tab_SnapInOut()
  reaper.ImGui_Text(ctx, "Snap Entrada/Salida items to containing region edges.")
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "- 'Entrada'  -> snaps LEFT edge to region start")
  reaper.ImGui_Text(ctx, "- 'Salida A' -> snaps RIGHT edge to region end")
  reaper.ImGui_Text(ctx, "- 'Salida B' -> snaps RIGHT edge to region end")

  if reaper.ImGui_Button(ctx, "Snap In-Out SFX", 200, 30) then
    Run_SnapInOut()
  end
  reaper.ImGui_Text(ctx, "Tip: Select the Entrada/Salida items first.")
end

function Tab_SnapItems()
  reaper.ImGui_Text(ctx, "Snap selected items to matching region starts by name.")
  reaper.ImGui_Separator(ctx)

  local align_items = "LEFT\0CENTER\0RIGHT\0"
  local fallback_items = "OFF\0NEXT\0CLOSEST\0"

  local changed
  changed, si_align_mode = reaper.ImGui_Combo(ctx, "Align Mode", si_align_mode, align_items)
  changed, si_fallback_mode = reaper.ImGui_Combo(ctx, "Fallback Mode", si_fallback_mode, fallback_items)

  reaper.ImGui_Spacing(ctx)
  changed, si_ignore_aligned = reaper.ImGui_Checkbox(ctx, "Ignore if already aligned", si_ignore_aligned)
  changed, si_prevent_multiple = reaper.ImGui_Checkbox(ctx, "Prevent multiple items per region", si_prevent_multiple)
  changed, si_enable_norm = reaper.ImGui_Checkbox(ctx, "Enable normalized text match", si_enable_norm)
  changed, si_enable_fuzzy = reaper.ImGui_Checkbox(ctx, "Enable fuzzy match", si_enable_fuzzy)

  if si_enable_fuzzy then
    changed, si_fuzzy_threshold = reaper.ImGui_SliderDouble(ctx, "Fuzzy Threshold", si_fuzzy_threshold, 0.0, 1.0, "%.2f")
  end

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, "Snap Items to Regions", 200, 30) then
    Run_SnapItems()
  end
end

function Tab_FullWorkflow()
  reaper.ImGui_Text(ctx, "Run the complete workflow in sequence:")
  reaper.ImGui_BulletText(ctx, "1. Region Workflow")
  reaper.ImGui_BulletText(ctx, "2. Color Regions")
  reaper.ImGui_BulletText(ctx, "3. Snap In-Out SFX")
  reaper.ImGui_BulletText(ctx, "4. Snap Items to Regions")

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Current Settings Summary:")
  reaper.ImGui_Text(ctx, string.format("  Min Gap: %.1fs | Quantize: %s", rw_min_gap, tostring(rw_quantize)))
  reaper.ImGui_Text(ctx, string.format("  Align: %s | Fallback: %s",
    ({"LEFT","CENTER","RIGHT"})[si_align_mode+1],
    ({"OFF","NEXT","CLOSEST"})[si_fallback_mode+1]))

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, "RUN FULL WORKFLOW", 250, 40) then
    Run_FullWorkflow()
  end
end

function Main()
  if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then

    if reaper.ImGui_BeginTabItem(ctx, "Region Workflow") then
      Tab_RegionWorkflow()
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, "Color Regions") then
      Tab_ColorRegions()
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, "Snap In-Out") then
      Tab_SnapInOut()
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, "Snap Items") then
      Tab_SnapItems()
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, "Full Workflow") then
      Tab_FullWorkflow()
      reaper.ImGui_EndTabItem(ctx)
    end

    reaper.ImGui_EndTabBar(ctx)
  end

  reaper.ImGui_Separator(ctx)
  DrawStatus()
end

-- ============================================================
-- INIT & LOOP
-- ============================================================
function SetButtonState(set)
  local is_new_value, filename, sec, cmd, mode, resolution, val = reaper.get_action_context()
  if is_new_value then
    reaper.SetToggleCommandState(sec, cmd, set or 0)
    reaper.RefreshToolbar2(sec, cmd)
  end
end

function Exit()
  SetButtonState(0)
end

function Run()
  reaper.ImGui_SetNextWindowBgAlpha(ctx, 1)
  reaper.ImGui_PushFont(ctx, font)
  reaper.ImGui_SetNextWindowSize(ctx, 520, 420, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, input_title, true, reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
    Main()
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)

  if open and not reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    reaper.defer(Run)
  end
end

function Init()
  SetButtonState(1)
  reaper.atexit(Exit)

  ctx = reaper.ImGui_CreateContext(input_title)
  font = reaper.ImGui_CreateFont('sans-serif', 14)
  reaper.ImGui_Attach(ctx, font)

  reaper.defer(Run)
end

Init()
