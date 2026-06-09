-- Base Provider class
-- Handles JSON config loading, section/item state, and generic UI data.
-- Subclasses override apply_config() and optionally expand_category().

local state = require("diagnostic-picker.state")

local Provider = {}
Provider.__index = Provider

-- Construct a Provider from a parsed JSON config table.
-- Subclasses call this via Provider.new(config) then set their own __index.
function Provider.new(config)
  local self = setmetatable({}, Provider)
  self.name      = config.provider
  self.lsp_name  = config.lsp_name
  self.filetypes = config.filetypes
  self.sections  = config.sections or {}

  -- Build fast lookup: section_id -> section, item_name -> {section, item}
  self._section_by_id   = {}
  self._item_by_name    = {}

  for _, section in ipairs(self.sections) do
    self._section_by_id[section.id] = section
    for _, item in ipairs(section.items or {}) do
      self._item_by_name[item.name] = { section = section, item = item }
    end
  end

  return self
end

-- Return initial enabled state for all items (used by state.lua on first open)
function Provider:get_initial_state()
  local result = {}
  for _, section in ipairs(self.sections) do
    for _, item in ipairs(section.items or {}) do
      if section.kind == "radio" then
        result[item.name] = item.default == true
      else
        result[item.name] = item.default ~= false  -- default true unless explicitly false
      end
    end
  end
  return result
end

-- Return sections formatted for the UI builder.
-- Each section has: id, title, kind, expandable, items[]
function Provider:get_sections()
  return self.sections
end

-- Return all items in a section by id (for expand_category fallback)
function Provider:get_section_items(section_id)
  local section = self._section_by_id[section_id]
  if not section then return {} end
  return section.items or {}
end

-- Look up which section an item belongs to
function Provider:get_item_section(item_name)
  local entry = self._item_by_name[item_name]
  return entry and entry.section or nil
end

-- Default expand_category: return items from the matching category section.
-- Providers with dynamic expansion (e.g. clangd shelling out to clang-tidy) override this.
function Provider:expand_category(category_name)
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        if item.name == category_name then
          -- Static items have no children; dynamic providers override this method
          return {}
        end
      end
    end
  end
  return {}
end

-- Default apply_config: subclasses must override this.
function Provider:apply_config(current_state, bufnr)
  error("Provider '" .. self.name .. "' must implement apply_config()")
end

-- Default sync_state_from_files: no-op.
-- Override in subclasses that write config files (e.g. clangd writes .clangd).
-- Providers that only push lsp_settings don't persist state to disk, so there's
-- nothing to read back — the LSP's current settings are the source of truth.
function Provider:sync_state_from_files(buf_state, bufnr)
end

-- Default is_installed: check lsp_name executable.
-- Subclasses can override for more specific checks.
function Provider:is_installed()
  return self.lsp_name and vim.fn.executable(self.lsp_name) == 1 or false
end

-- Restart the LSP client, scoped to the given buffer if provided.
function Provider:restart_lsp(bufnr)
  if not self.lsp_name then return end
  local opts = { name = self.lsp_name }
  if bufnr then opts.bufnr = bufnr end
  local clients = vim.lsp.get_clients(opts)
  for _, client in ipairs(clients) do
    -- false = graceful shutdown (sends LSP shutdown request before exit).
    -- true would send SIGKILL immediately, causing clangd to log exit code 1.
    vim.lsp.stop_client(client.id, false)
  end
  -- Delay restart to give the client time to finish shutting down.
  -- LspStart is provided by nvim-lspconfig; fall back to :edit which
  -- triggers FileType autocmds and causes lspconfig to re-attach.
  vim.defer_fn(function()
    if vim.fn.exists(":LspStart") == 2 then
      vim.cmd("LspStart " .. self.lsp_name)
    else
      vim.cmd("edit")
    end
  end, 500)
end

-- Generic LSP settings apply: push settings_path key/value pairs via
-- workspace/didChangeConfiguration. Scoped to bufnr if provided.
function Provider:apply_lsp_settings(settings, bufnr)
  local opts = { name = self.lsp_name }
  if bufnr then opts.bufnr = bufnr end
  local clients = vim.lsp.get_clients(opts)
  if #clients == 0 then
    return { success = true, message = self.lsp_name .. " not running — settings apply on next open" }
  end
  for _, client in ipairs(clients) do
    client.config.settings = vim.tbl_deep_extend("force", client.config.settings or {}, settings)
    client.notify("workspace/didChangeConfiguration", { settings = client.config.settings })
  end
  return { success = true, message = "Updated " .. self.lsp_name .. " settings" }
end

return Provider
