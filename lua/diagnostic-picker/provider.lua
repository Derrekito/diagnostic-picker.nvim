-- Provider interface definition and registry

local M = {}

-- Provider registry (filetype -> provider)
M.registry = {}

-- Register a provider
M.register = function(provider)
  -- Validate provider has required fields
  if not provider.name then
    error("Provider must have a 'name' field")
  end
  if not provider.filetypes or type(provider.filetypes) ~= "table" then
    error("Provider '" .. provider.name .. "' must have a 'filetypes' table")
  end
  if not provider.is_installed or type(provider.is_installed) ~= "function" then
    error("Provider '" .. provider.name .. "' must implement is_installed()")
  end
  if not provider.get_categories or type(provider.get_categories) ~= "function" then
    error("Provider '" .. provider.name .. "' must implement get_categories()")
  end
  if not provider.apply_config or type(provider.apply_config) ~= "function" then
    error("Provider '" .. provider.name .. "' must implement apply_config()")
  end

  -- Register for all filetypes
  for _, ft in ipairs(provider.filetypes) do
    M.registry[ft] = provider
  end
end

-- Get provider for filetype
M.get_for_filetype = function(ft)
  return M.registry[ft]
end

-- Check if provider exists for filetype
M.has_provider = function(ft)
  return M.registry[ft] ~= nil
end

-- Auto-discover and load providers
M.load_providers = function()
  local providers_dir = "diagnostic-picker.providers"

  -- Try to load clangd provider
  local ok, clangd = pcall(require, providers_dir .. ".clangd")
  if ok then
    M.register(clangd)
  end

  -- Try to load pylsp provider
  ok, pylsp = pcall(require, providers_dir .. ".pylsp")
  if ok then
    M.register(pylsp)
  end
end

return M
