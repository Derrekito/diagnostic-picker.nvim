-- Main entry point for diagnostic-picker plugin

local M = {}

local config = require("diagnostic-picker.config")
local provider_registry = require("diagnostic-picker.provider")
local state = require("diagnostic-picker.state")

-- Setup function (called by user in config)
M.setup = function(opts)
  config.setup(opts or {})
end

-- Show the diagnostic picker
M.show = function(opts)
  -- Lazy-load UI module
  local ui = require("diagnostic-picker.ui")
  ui.show(opts)
end

-- Apply configuration changes
M.apply_config = function()
  -- Apply severity configuration (universal)
  local enabled = {}
  local sev = vim.diagnostic.severity

  if state.state.severities.ERROR then table.insert(enabled, sev.ERROR) end
  if state.state.severities.WARN then table.insert(enabled, sev.WARN) end
  if state.state.severities.INFO then table.insert(enabled, sev.INFO) end
  if state.state.severities.HINT then table.insert(enabled, sev.HINT) end

  if #enabled > 0 then
    vim.diagnostic.config({
      signs = {
        text = {
          [sev.ERROR] = "✘",
          [sev.WARN] = "⚠",
          [sev.HINT] = "💡",
          [sev.INFO] = "ℹ",
        },
        severity = enabled
      },
      underline = { severity = enabled },
    })
    print("Diagnostics updated: " .. table.concat(vim.tbl_keys(state.state.severities), ", "))
  else
    vim.diagnostic.config({
      signs = false,
      underline = false,
    })
    print("All diagnostics disabled")
  end

  -- Apply language-specific configuration via provider
  local ft = vim.bo.filetype
  local provider = provider_registry.get_for_filetype(ft)

  if provider and provider.apply_config then
    local result = provider.apply_config(state.state)
    if result and result.message then
      print(result.message)
    end
  end
end

return M
