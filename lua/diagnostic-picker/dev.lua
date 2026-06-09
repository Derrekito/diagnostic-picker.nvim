-- Development helpers for rapid iteration

local M = {}

-- Reload all diagnostic-picker modules
M.reload = function()
  -- Unload all diagnostic-picker modules
  for k in pairs(package.loaded) do
    if k:match("^diagnostic%-picker") then
      package.loaded[k] = nil
    end
  end

  -- Reload providers
  local provider = require("diagnostic-picker.provider")
  provider.load_providers()

  print("Reloaded diagnostic-picker modules")
  return require("diagnostic-picker")
end

-- Quick test function
M.test = function()
  print("Testing diagnostic-picker...")

  -- Test modules load
  local ok, picker = pcall(require, "diagnostic-picker")
  if not ok then
    print("ERROR: Failed to load main module:", picker)
    return false
  end

  ok, _ = pcall(require, "diagnostic-picker.config")
  if not ok then
    print("ERROR: Failed to load config module")
    return false
  end

  ok, _ = pcall(require, "diagnostic-picker.state")
  if not ok then
    print("ERROR: Failed to load state module")
    return false
  end

  ok, _ = pcall(require, "diagnostic-picker.provider")
  if not ok then
    print("ERROR: Failed to load provider module")
    return false
  end

  ok, _ = pcall(require, "diagnostic-picker.ui")
  if not ok then
    print("ERROR: Failed to load ui module")
    return false
  end

  print("All modules loaded successfully!")
  return true
end

return M
