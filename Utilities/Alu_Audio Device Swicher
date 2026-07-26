-- @description Switch Audio Device (macOS)
-- @author Alu
-- @version 2.1
-- @about Click device to switch and close. • or right-click to refresh. ESC to close.

dofile(reaper.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8.7')

local ctx = reaper.ImGui_CreateContext('Audio Device Switcher')

local devices = {}
local current_device = ""

local PATHS = "/opt/homebrew/bin:/usr/local/bin:" .. (os.getenv("HOME") .. "/.brew/bin")

function Run(args)
    local cmd = 'export PATH="' .. PATHS .. ':$PATH" && SwitchAudioSource ' .. args .. ' 2>&1'
    local handle = io.popen(cmd, 'r')
    if not handle then return nil end
    local result = handle:read('*a')
    handle:close()
    result = result:gsub('\r\n', '\n'):gsub('\r', '\n')
    result = result:gsub('^%s*', ''):gsub('%s*$', '')
    return result ~= "" and result or nil
end

function RefreshDevices()
    devices = {}
    
    local cur = Run('-c -t output')
    current_device = cur or "Unknown"
    
    local list = Run('-a -t output')
    if not list then return end
    
    for line in list:gmatch('[^\n]+') do
        line = line:gsub('^%s*', ''):gsub('%s*$', '')
        if line ~= "" and line ~= "output" then
            table.insert(devices, {
                name = line,
                is_current = (line == current_device)
            })
        end
    end
end

function SwitchDevice(name)
    Run('-s "' .. name:gsub('"', '\\"') .. '" -t output')
    
    reaper.Audio_Quit()
    local t = reaper.time_precise()
    while reaper.time_precise() - t < 0.8 do end
    reaper.Audio_Init()
end

RefreshDevices()

function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 280, 250, reaper.ImGui_Cond_FirstUseEver())
    local flags = reaper.ImGui_WindowFlags_NoTitleBar() 
                | reaper.ImGui_WindowFlags_NoResize() 
                | reaper.ImGui_WindowFlags_AlwaysAutoResize()
                | reaper.ImGui_WindowFlags_NoCollapse()
    
    local visible, open = reaper.ImGui_Begin(ctx, 'Audio Device Switcher', true, flags)
    
    if visible then
        -- ESC to close
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
            open = false
        end
        
        -- Right-click to refresh
        if reaper.ImGui_IsMouseClicked(ctx, reaper.ImGui_MouseButton_Right()) 
           and reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_RootAndChildWindows()) then
            RefreshDevices()
        end
        
        -- • refresh text aligned to right edge
        local window_width = reaper.ImGui_GetWindowWidth(ctx)
        local text_width = reaper.ImGui_CalcTextSize(ctx, "•")
        reaper.ImGui_SameLine(ctx, window_width - text_width - 10)
        
        reaper.ImGui_Text(ctx, "•")
        if reaper.ImGui_IsItemClicked(ctx) then
            RefreshDevices()
        end
        if reaper.ImGui_IsItemHovered(ctx, 3.0) then
            reaper.ImGui_SetTooltip(ctx, "Refresh")
        end
        
        for _, dev in ipairs(devices) do
            local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
            reaper.ImGui_PushItemWidth(ctx, avail_width - 20)
            
            if reaper.ImGui_Selectable(ctx, dev.name, dev.is_current) and not dev.is_current then
                SwitchDevice(dev.name)
                open = false
            end
            
            reaper.ImGui_PopItemWidth(ctx)
            
            if dev.is_current then
                local x, y = reaper.ImGui_GetItemRectMin(ctx)
                local w, h = reaper.ImGui_GetItemRectSize(ctx)
                local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
                local cx = x + w - 8
                local cy = y + h / 2
                
                reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 3, 0x00FF00FF, 12)
            end
        end
        
        if reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_RootAndChildWindows()) 
           and not reaper.ImGui_IsAnyItemHovered(ctx) then
            if reaper.ImGui_IsWindowHovered(ctx, 3.0) then
                reaper.ImGui_SetTooltip(ctx, "Right-click to refresh\nESC to close")
            end
        end
        
        reaper.ImGui_End(ctx)
    end
    
    if open then
        reaper.defer(loop)
    end
end

reaper.defer(loop)
