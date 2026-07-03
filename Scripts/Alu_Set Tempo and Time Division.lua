-- @author Alejandro (Alu) 

function Main()
  retval, BPM_input = reaper.GetUserInputs("Change BPM", 1, "Enter new BPM:", "")
  if retval == false then
    return
  end

  new_BPM = tonumber(BPM_input)
  if new_BPM == nil then
    reaper.ShowMessageBox("Invalid input. Please enter a number for BPM.", "Error", 0)
    return
  end

  retval, time_division_input = reaper.GetUserInputs("Change Time Signature", 1, "Enter new time signature (e.g. 4/4):", "")
  if retval == false then
    return
  end

  new_time_division = time_division_input
  if new_time_division == nil then
    reaper.ShowMessageBox("Invalid input. Please enter a time signature (e.g. 4/4).", "Error", 0)
    return
  end

  -- Parse the new time signature
  local numerator, denominator = string.match(new_time_division, "(%d+)/(%d+)")
  numerator = tonumber(numerator)
  denominator = tonumber(denominator)
  if numerator == nil or denominator == nil then
    reaper.ShowMessageBox("Invalid time signature. Please enter a time signature in the format 'n/m' (e.g. 4/4)", "Error", 0)
    return
  end

  -- Set the new BPM
  reaper.SetCurrentBPM(0, new_BPM, false)

  -- Set the new time signature
  reaper.SetProjectTimeSignature2(0, numerator, denominator, 0)
end

Main()

