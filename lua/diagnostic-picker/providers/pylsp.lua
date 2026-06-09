-- Pylsp provider for Python

local M = {}

-- Provider metadata
M.name = "pylsp"
M.filetypes = { "python" }

-- Check if pylsp is installed
M.is_installed = function()
  return vim.fn.executable("pylsp") == 1
end

-- Get categories
M.get_categories = function()
  return {
    { name = "pycodestyle", desc = "PEP 8 style", plugin = "pycodestyle" },
    { name = "pyflakes", desc = "Logic errors", plugin = "pyflakes" },
    { name = "mccabe", desc = "Complexity", plugin = "mccabe" },
    { name = "pylint", desc = "Pylint checks", plugin = "pylint" },
    { name = "rope", desc = "Refactoring", plugin = "rope" },
  }
end

-- Apply configuration
M.apply_config = function(state)
  if not state.python then
    return {
      success = true,
      message = "No Python configuration changes"
    }
  end

  -- Build pylsp plugin configuration
  local plugins_config = {}
  local categories = M.get_categories()

  for _, cat in ipairs(categories) do
    if cat.plugin then
      plugins_config[cat.plugin] = {
        enabled = state.python[cat.name] or false
      }
    end
  end

  -- Update LSP client settings
  local clients = vim.lsp.get_clients({ bufnr = 0, name = "pylsp" })
  if #clients > 0 then
    for _, client in ipairs(clients) do
      client.config.settings = vim.tbl_deep_extend("force", client.config.settings or {}, {
        pylsp = {
          plugins = plugins_config
        }
      })
      client.notify("workspace/didChangeConfiguration", { settings = client.config.settings })
    end

    return {
      success = true,
      message = "Updated pylsp config - diagnostics will refresh"
    }
  else
    return {
      success = true,
      message = "pylsp not running - settings will apply on next file open"
    }
  end
end

-- Restart LSP (pylsp doesn't need restart, uses live config updates)
M.restart_lsp = function()
  -- Pylsp uses workspace/didChangeConfiguration, no restart needed
end

return M
