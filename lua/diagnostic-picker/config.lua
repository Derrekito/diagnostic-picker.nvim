-- Plugin configuration and setup

local M = {}

-- Default configuration
M.defaults = {
  debug = false,
  debug_file = "/tmp/diagnostic-picker-debug.log",

  -- Which severities are enabled on startup. All off by default; override in setup().
  -- Which severities to show on startup. Keys match vim.diagnostic.severity names.
  severities = { ERROR = false, WARN = false, INFO = false, HINT = false },

  -- UI configuration
  icons = {
    global_config = "🌍",
    local_config = "📁",
    disabled = "❌",
  },
}

-- Current configuration (merged with user options)
M.options = {}

-- Setup function called by user
M.setup = function(user_config)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_config or {})
  return M.options
end

-- Get current configuration
M.get = function()
  if vim.tbl_isempty(M.options) then
    M.options = M.defaults
  end
  return M.options
end

return M
