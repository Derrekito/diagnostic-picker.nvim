-- Plugin entry point
-- This file is loaded by Neovim automatically

-- Prevent loading twice
if vim.g.loaded_diagnostic_picker then
  return
end
vim.g.loaded_diagnostic_picker = 1

-- Load providers when plugin loads
local provider = require("diagnostic-picker.provider")
provider.load_providers()
