-- Main entry point for diagnostic-picker plugin

local M = {}

local config = require("diagnostic-picker.config")
local provider_registry = require("diagnostic-picker.provider")
local state = require("diagnostic-picker.state")

-- Setup function (called by user in config)
M.setup = function(opts)
  config.setup(opts or {})
  local log = require("diagnostic-picker.log")

  local ok, err = pcall(provider_registry.load_providers)
  if not ok then
    log.error("failed to load providers: " .. tostring(err))
  else
    log.debug("providers loaded")
  end

  -- Apply severity defaults immediately so diagnostics reflect config on startup
  state.init_severities()
  require("diagnostic-picker").apply_config()

  -- :DiagnosticPickerDebug — print where the current buffer's state comes from
  -- (resolved root, .clangd vs JSON defaults, per-category source). Works whether
  -- or not file logging (config.debug) is enabled.
  vim.api.nvim_create_user_command("DiagnosticPickerDebug", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local provider = provider_registry.get_for_filetype(vim.bo[bufnr].filetype)
    local lines = log.report_config_source(provider, bufnr)
    vim.api.nvim_echo(vim.tbl_map(function(l) return { l .. "\n" } end, lines), true, {})
  end, { desc = "diagnostic-picker: report config source (file vs defaults) for current buffer" })
end

-- Show the diagnostic picker
M.show = function(opts)
  -- Lazy-load UI module
  local ui = require("diagnostic-picker.ui")
  ui.show(opts)
end

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

  -- vim.diagnostic.config's 2nd arg is a NAMESPACE id, not a buffer. Passing a
  -- bufnr errors on Neovim 0.12 ("namespace does not exist"), which crashed
  -- save_config before it could write .clangd. These opts are global; no 2nd arg.
  vim.diagnostic.config(diag_opts)
end

-- Enter in picker: apply severity filter for this session only.
-- Language-specific settings (compile flags, clang-tidy checks) are kept
-- in memory and reflected in the picker but NOT written to disk.
-- bufnr: the buffer that was active when the picker opened (nil = current buf)
M.apply_config = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  apply_severities(bufnr)
  print("Diagnostic filter applied (session only — use save_config() to persist)")
end

-- Write provider config to disk and restart the LSP.
-- bufnr: the buffer that was active when the picker opened. nil = resolve like
-- the picker does (current buffer, falling back past sidebar windows).
-- Bind to a key of your choice, e.g.:
--   vim.keymap.set("n", "<leader>dG", require("diagnostic-picker").save_config)
M.save_config = function(bufnr)
  local ft
  if bufnr then
    ft = vim.bo[bufnr].filetype
  else
    bufnr, ft = provider_registry.resolve_target_buf()
  end
  apply_severities(bufnr)

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
