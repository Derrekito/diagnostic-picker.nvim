-- Main entry point for diagnostic-picker plugin

local M = {}

local config = require("diagnostic-picker.config")
local provider_registry = require("diagnostic-picker.provider")
local state = require("diagnostic-picker.state")

-- Apply severity filter to vim diagnostics (session-only, no file I/O).
-- bufnr: the buffer to scope the config to (nil = global/all buffers)
local function apply_severities(bufnr)
  local enabled = {}
  local sev = vim.diagnostic.severity

  if state.state.severities.ERROR then table.insert(enabled, sev.ERROR) end
  if state.state.severities.WARN  then table.insert(enabled, sev.WARN)  end
  if state.state.severities.INFO  then table.insert(enabled, sev.INFO)  end
  if state.state.severities.HINT  then table.insert(enabled, sev.HINT)  end

  local diag_opts
  if #enabled > 0 then
    diag_opts = {
      signs = {
        text = {
          [sev.ERROR] = "✘",
          [sev.WARN]  = "⚠",
          [sev.HINT]  = "💡",
          [sev.INFO]  = "ℹ",
        },
        severity = enabled,
      },
      underline = { severity = enabled },
    }
  else
    diag_opts = { signs = false, underline = false }
  end

  if bufnr then
    vim.diagnostic.config(diag_opts, bufnr)
  else
    vim.diagnostic.config(diag_opts)
  end
end

M.setup = function(opts)
  config.setup(opts or {})
  provider_registry.load_providers()
  state.init_severities()
  apply_severities()
end

M.show = function(opts)
  local ui = require("diagnostic-picker.ui")
  ui.show(opts)
end

-- Enter in picker: apply severity filter for this session only.
-- Language-specific settings (compile flags, clang-tidy checks) are kept
-- in memory and reflected in the picker but NOT written to disk.
-- bufnr: the buffer that was active when the picker opened (nil = current buf)
M.apply_config = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  apply_severities(bufnr)

  local ft = vim.bo[bufnr].filetype
  local provider = provider_registry.get_for_filetype(ft)

  if provider and provider.apply_session then
    local result = provider:apply_session(state.state, bufnr)
    if result and result.message then
      print(result.message)
    end
  else
    print("Diagnostic filter applied (session only)")
  end
end

-- Write provider config to disk and restart the LSP.
-- bufnr: the buffer that was active when the picker opened (nil = current buf)
-- Bind to a key of your choice, e.g.:
--   vim.keymap.set("n", "<leader>dG", require("diagnostic-picker").save_config)
M.save_config = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  apply_severities(bufnr)

  local ft = vim.bo[bufnr].filetype
  local provider = provider_registry.get_for_filetype(ft)

  if provider and provider.apply_config then
    local result = provider:apply_config(state.state, bufnr)
    if result and result.message then
      print(result.message)
    end
  else
    print("No provider for filetype: " .. ft)
  end
end

return M
