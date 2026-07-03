-- Move Selected MIDI Notes to Specific Pitch
-- Prompts for target pitch and moves all selected notes to that pitch
-- @author Alejandro (Alu) 

-- Function to convert note name to MIDI number
local function noteNameToMidi(note_name)
  -- Remove spaces and convert to uppercase
  note_name = note_name:gsub("%s+", ""):upper()
  
  -- Note names to semitone offset
  local notes = {
    C = 0, ["C#"] = 1, DB = 1,
    D = 2, ["D#"] = 3, EB = 3,
    E = 4,
    F = 5, ["F#"] = 6, GB = 6,
    G = 7, ["G#"] = 8, AB = 8,
    A = 9, ["A#"] = 10, BB = 10,
    B = 11
  }
  
  -- Try to match note name and octave
  local note_part, octave = note_name:match("^([A-G][#B]?)(-?%d+)$")
  
  if note_part and octave then
    local semitone = notes[note_part]
    local oct = tonumber(octave)
    
    if semitone and oct then
      local midi_num = (oct + 1) * 12 + semitone
      if midi_num >= 0 and midi_num <= 127 then
        return midi_num
      end
    end
  end
  
  return nil
end

-- Prompt user for target pitch
local retval, user_input = reaper.GetUserInputs("Move Notes to Pitch", 1, "Target Note (e.g. C1, F#3, or 0-127):", "C1")

if not retval then
  return -- User cancelled
end

-- Try to parse as note name first, then as number
local TARGET_PITCH = noteNameToMidi(user_input)

if not TARGET_PITCH then
  -- Try parsing as a direct MIDI number
  TARGET_PITCH = tonumber(user_input)
end

if not TARGET_PITCH or TARGET_PITCH < 0 or TARGET_PITCH > 127 then
  reaper.ShowMessageBox("Invalid input. Please enter a note name (C1, F#3, etc.) or MIDI number (0-127).", "Error", 0)
  return
end

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
