-- @author Alejandro (Alu) 

-- Import ReaImGui
local imgui = reaper.ImGui_CreateContext('Item Counter')
local open = true -- Variable to control if the window is open

-- Function to get the current item count
function get_item_count()
    local itemCount = reaper.CountMediaItems(0)
    return itemCount
end

-- Function to create the GUI
function show_gui()
    if open then
        local itemCount = get_item_count()

        local visible
        -- NoTitleBar: hides the title bar
        -- NoResize: removes the resize handle
        -- AlwaysAutoResize: window shrinks/wraps tightly around its contents
        visible, open = reaper.ImGui_Begin(imgui, 'Item Counter', true, reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_AlwaysAutoResize())

        -- Check if ESC key is pressed to close the window
        if reaper.ImGui_IsKeyPressed(imgui, reaper.ImGui_Key_Escape()) then
            open = false
        end

        if visible then
            -- Set text color to green
            reaper.ImGui_PushStyleColor(imgui, reaper.ImGui_Col_Text(), 0x00FF00FF)
            reaper.ImGui_Text(imgui, "Total items: " .. itemCount)
            reaper.ImGui_PopStyleColor(imgui)

            reaper.ImGui_End(imgui)
        end

        -- Defer the function to refresh periodically
        if open then
            reaper.defer(show_gui)
        end
    end
end

-- Main script to select items
function select_all_items()
    -- Unselect all items first
    reaper.SelectAllMediaItems(0, false)

    -- Get total number of items in the project
    local itemCount = reaper.CountMediaItems(0)

    -- Loop through each item and select it
    for i = 0, itemCount - 1 do
        local item = reaper.GetMediaItem(0, i)
        reaper.SetMediaItemSelected(item, true)
    end

    -- Update the arrange view to reflect the changes
    reaper.UpdateArrange()
end

-- Start the GUI and select items periodically
function main()
    select_all_items()
    reaper.defer(show_gui)
end

-- Run the main script
main()
