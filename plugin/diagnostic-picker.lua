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

-- Saving .clangd-user.yaml re-imports it into the generated .clangd and
-- restarts clangd, so hand edits take effect without opening the picker.
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = ".clangd-user.yaml",
  group = vim.api.nvim_create_augroup("DiagnosticPickerUserConfig", { clear = true }),
  callback = function(ev)
    local clangd = provider.get_for_filetype("cpp")
    if not (clangd and clangd.reimport_user_config) then return end
    -- ev.match is the full path; ev.file can be relative to cwd and would
    -- resolve the project root to the wrong directory.
    local root = vim.fs.dirname(ev.match)
    if clangd:reimport_user_config(root) then
      vim.notify("diagnostic-picker: merged " .. ev.match .. " into .clangd", vim.log.levels.INFO)
    else
      vim.notify("diagnostic-picker: no generated .clangd in " .. root
        .. " — apply once from the picker to start managing it", vim.log.levels.WARN)
    end
  end,
})
