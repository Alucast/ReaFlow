-- Move Selected MIDI Notes to Specific Pitch
-- Moves all selected notes to C1 (pitch 24)
-- You can change TARGET_PITCH to any MIDI note number (0-127)
-- @author Alejandro (Alu) 

-- Target pitch: C1 = 24 (C0=0, C#0=1, D0=2... C1=24, C2=36, etc.)
local TARGET_PITCH = 24

-- Get the active MIDI editor
local editor = reaper.MIDIEditor_GetActive()
if not editor then
  reaper.ShowMessageBox("No active MIDI editor found", "Error", 0)
  return
end

-- Get the active take in the MIDI editor
local take = reaper.MIDIEditor_GetTake(editor)
if not take then
  reaper.ShowMessageBox("No active MIDI take found", "Error", 0)
  return
end

-- Begin undo block
reaper.Undo_BeginBlock()

-- Get the number of notes in the take
local _, notecount = reaper.MIDI_CountEvts(take)

local moved_count = 0

-- Loop through all notes
for i = 0, notecount - 1 do
  local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
  
  -- If the note is selected, move it to target pitch
  if selected then
    reaper.MIDI_SetNote(take, i, selected, muted, startppq, endppq, chan, TARGET_PITCH, vel, false)
    moved_count = moved_count + 1
  end
end

-- Sort the MIDI to ensure proper order
reaper.MIDI_Sort(take)

-- End undo block
reaper.Undo_EndBlock("Move selected notes to pitch " .. TARGET_PITCH, -1)

-- Update the MIDI editor
reaper.UpdateArrange()


