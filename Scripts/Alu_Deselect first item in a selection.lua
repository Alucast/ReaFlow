--[[]]
-- Script: Deselect Leftmost Selected Item
-- Description: Finds the leftmost of the currently selected media items in the arrange view and deselects it.
-- Usage: Add to your REAPER Scripts, then bind to a shortcut. Trigger to deselect the single leftmost item.
-- @author Alejandro (Alu) 

function main()
  local ctx = 0  -- current project
  local count = reaper.CountSelectedMediaItems(ctx)
  if count == 0 then return end
  
  -- Initialize with first item
  local leftItem = reaper.GetSelectedMediaItem(ctx, 0)
  local leftPos = reaper.GetMediaItemInfo_Value(leftItem, "D_POSITION")

  -- Iterate through selected items
  for i = 1, count-1 do
    local item = reaper.GetSelectedMediaItem(ctx, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if pos < leftPos then
      leftPos = pos
      leftItem = item
    end
  end

  -- Deselect the leftmost item
  reaper.SetMediaItemSelected(leftItem, false)
  reaper.UpdateArrange()
end

-- Prevent UI refreshing until end
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Deselect Leftmost Selected Item", -1)

