
-- @author Alejandro (Alu) 

function Main()
  retval, BPM_input = reaper.GetUserInputs("Change BPM", 1, "Enter new BPM:", "")
  if retval == false then
    return
  end

  new_BPM = tonumber(BPM_input)
  if new_BPM == nil then
    reaper.ShowMessageBox("Invalid input. Please enter a number.", "Error", 0)
    return
  end

  reaper.SetCurrentBPM(0, new_BPM, false)
end

Main()

