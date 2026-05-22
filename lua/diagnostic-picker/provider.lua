-- Provider registry
-- Loads JSON configs from bundled configs/ dir and user override dir,
-- instantiates the matching provider class, and maps filetypes to providers.

local M = {}

-- filetype -> Provider instance
M.registry = {}

-- Load and decode a JSON config file. Returns table or nil.
local function load_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  return ok and decoded or nil
end

-- Resolve the directory where bundled configs live (sibling of this file's plugin root)
local function bundled_configs_dir()
  -- __FILE__ resolves to .../lua/diagnostic-picker/provider.lua
  -- Go up three levels to plugin root, then into configs/
  local this_file = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(this_file, ":h:h:h")
  return plugin_root .. "/configs"
end

-- Resolve user override dir: ~/.config/nvim/diagnostic-picker/
local function user_configs_dir()
  return vim.fn.stdpath("config") .. "/diagnostic-picker"
end

-- Load a provider class by name. Returns the class table or nil.
-- Provider classes live in lua/diagnostic-picker/providers/<name>.lua
local function load_provider_class(provider_name)
  local mod_name = "diagnostic-picker.providers." .. provider_name:gsub("-", "_")
  local ok, cls = pcall(require, mod_name)
  return ok and cls or nil
end

-- Instantiate a provider from a JSON config, using its named class if available,
-- falling back to a generic LSP-settings provider.
local function instantiate(config)
  local cls = load_provider_class(config.provider)
  if cls then
    return cls.new(config)
  end
  -- Fallback: use base provider directly — its default apply_config handles lsp_settings
  local Provider = require("diagnostic-picker.provider_base")
  return Provider.new(config)
end

-- Register a provider instance for all its filetypes.
local function register(instance)
  for _, ft in ipairs(instance.filetypes or {}) do
    -- User configs (loaded second) win over bundled ones
    M.registry[ft] = instance
  end
end

-- Load all JSON configs from a directory.
local function load_dir(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return end
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if type == "file" and name:match("%.json$") then
      local config = load_json(dir .. "/" .. name)
      if config and config.provider and config.filetypes then
        local ok, instance = pcall(instantiate, config)
        if ok and instance then
          register(instance)
        else
          vim.notify("diagnostic-picker: failed to load " .. name .. ": " .. tostring(instance),
            vim.log.levels.WARN)
        end
      end
    end
  end
end

-- Load all providers: bundled first, user overrides second.
M.load_providers = function()
  load_dir(bundled_configs_dir())
  load_dir(user_configs_dir())
end

-- Get provider for a filetype. Returns nil if none registered.
M.get_for_filetype = function(ft)
  return M.registry[ft]
end

M.has_provider = function(ft)
  return M.registry[ft] ~= nil
end

return M
