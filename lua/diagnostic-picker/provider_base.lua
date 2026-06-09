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

-- Default get_categories: return each category section as a single expandable row.
-- The section title is the category name; its items appear on expand.
-- Providers with dynamic availability checks (e.g. clangd) override this.
function Provider:get_categories(bufnr)
  local categories = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      table.insert(categories, {
        name        = section.title,
        desc        = section.desc,
        expandable  = section.expandable ~= false,
        auto_expand = section.auto_expand == true,
      })
    end
  end
  return categories
end

-- Default get_language_options: return radio + toggle sections for the UI.
function Provider:get_language_options(bufnr)
  local state = require("diagnostic-picker.state")
  local buf_state = (bufnr and state.state[bufnr]) or {}
  local opts = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "radio" or section.kind == "toggle" then
      for _, item in ipairs(section.items or {}) do
        local is_selected
        if section.kind == "radio" then
          is_selected = item.name == self:get_radio_selection(buf_state, section)
        else
          local val = buf_state[item.name]
          is_selected = val == nil and item.default ~= false or val == true
        end
        table.insert(opts, {
          kind        = section.kind,
          group       = section.title,
          name        = item.name,
          desc        = item.desc,
          is_selected = is_selected,
        })
      end
    end
  end
  return opts
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

-- Default expand_category: for a section whose title matches category_name,
-- return all its items as expandable checks. Providers with dynamic expansion
-- (e.g. clangd shelling out to clang-tidy) override this.
function Provider:expand_category(category_name)
  for _, section in ipairs(self.sections) do
    if section.kind == "category" and section.title == category_name then
      local result = {}
      for _, item in ipairs(section.items or {}) do
        table.insert(result, { name = item.name, config_source = "" })
      end
      return result
    end
  end
  return {}
end

-- ── Shared helpers ───────────────────────────────────────────────────────────

-- Return the selected item name for a radio section.
function Provider:get_radio_selection(buf_state, section)
  local selected = buf_state["__" .. section.id]
  if not selected then
    for _, i in ipairs(section.items or {}) do
      if i.default then selected = i.name; break end
    end
    selected = selected or (section.items[1] and section.items[1].name)
  end
  return selected
end

-- Return names of items in a section that are currently disabled.
function Provider:collect_disabled(buf_state, section_id)
  local section = self._section_by_id[section_id]
  if not section then return {} end
  local result = {}
  for _, item in ipairs(section.items or {}) do
    local val = buf_state[item.name]
    if val == nil then val = item.default ~= false end
    if not val then table.insert(result, item.name) end
  end
  return result
end

-- Return names of items in a section that are currently enabled.
function Provider:collect_enabled(buf_state, section_id)
  local section = self._section_by_id[section_id]
  if not section then return {} end
  local result = {}
  for _, item in ipairs(section.items or {}) do
    local val = buf_state[item.name]
    if val == nil then val = item.default ~= false end
    if val then table.insert(result, item.name) end
  end
  return result
end

-- Default apply_config: builds LSP settings from all lsp_settings sections and
-- pushes them via workspace/didChangeConfiguration. Works for any provider whose
-- JSON sections all use apply_to=lsp_settings. Subclasses that write config files
-- (e.g. clangd) override this.
function Provider:apply_config(current_state, bufnr)
  local buf_state = (bufnr and current_state[bufnr]) or {}
  local settings = {}

  for _, section in ipairs(self.sections) do
    if section.apply_to == "lsp_settings" and section.settings_path then
      local node = settings
      -- Walk/create nested tables from dot-separated settings_path
      for part in section.settings_path:gmatch("[^.]+") do
        node[part] = node[part] or {}
        node = node[part]
      end
      if section.kind == "toggle" then
        for _, item in ipairs(section.items or {}) do
          local val = buf_state[item.name]
          if val == nil then val = item.default ~= false end
          node[item.name] = val
        end
      elseif section.kind == "radio" then
        local selected = self:get_radio_selection(buf_state, section)
        local parent_path, key = section.settings_path:match("^(.+)%.([^.]+)$")
        if parent_path and key then
          local p = settings
          for part in parent_path:gmatch("[^.]+") do
            p[part] = p[part] or {}
            p = p[part]
          end
          p[key] = selected
        end
      end
    end
  end

  return self:apply_lsp_settings(settings, bufnr)
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
