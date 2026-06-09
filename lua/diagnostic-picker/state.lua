-- State management for diagnostic picker

local M = {}

-- Global state — severities populated from config on first access via init_severities()
M.state = {
  severities = {},
  expanded = {},
}

M.init_severities = function()
  if next(M.state.severities) then return end
  local sev = vim.diagnostic.severity
  local diag_cfg = vim.diagnostic.config()
  local signs = diag_cfg and diag_cfg.signs
  local active = type(signs) == "table" and signs.severity

  -- Prefer existing vim diagnostic filter; fall back to plugin setup() config.
  -- active is a list of enabled severity enum values, e.g. { sev.ERROR, sev.WARN }
  local function is_on(s)
    if active then
      for _, v in ipairs(active) do if v == s then return true end end
      return false
    end
    local name = vim.diagnostic.severity[s]  -- integer → "ERROR", "WARN", etc.
    return require("diagnostic-picker.config").get().severities[name] == true
  end

  M.state.severities = {
    ERROR = is_on(sev.ERROR),
    WARN  = is_on(sev.WARN),
    INFO  = is_on(sev.INFO),
    HINT  = is_on(sev.HINT),
  }
end

-- Initialize state for a buffer from provider sections (respects JSON defaults).
-- No-op if state already exists for this bufnr.
M.init_buf_state = function(bufnr, provider)
  if M.state[bufnr] then return end
  M.state[bufnr] = {}
  if not provider then return end
  for _, section in ipairs(provider.sections or {}) do
    local items = section.items or {}
    if #items == 0 and section.kind == "category" then
      -- Flat category section: the section itself is the toggle, keyed by section.id
      M.state[bufnr][section.id] = section.default ~= false
    else
      for _, item in ipairs(items) do
        if section.kind == "radio" then
          -- Radio defaults are tracked per-section via __<section_id>, not per-item
        else
          M.state[bufnr][item.name] = item.default ~= false
        end
      end
    end
  end
end

-- Backward-compatible shim: init_ft_state now delegates to init_buf_state.
-- The key used is the ft string so existing callers (tests, etc.) still work
-- when they pass a string key. In production, ui.lua passes a bufnr (integer).
M.init_ft_state = function(key, provider)
  M.init_buf_state(key, provider)
end

-- Kept for callers that haven't been updated yet; delegates to init_buf_state.
M.init_category_state = function(key, categories)
  if M.state[key] then return end
  M.state[key] = {}
  for _, cat in ipairs(categories or {}) do
    M.state[key][cat.name] = cat.default ~= false
  end
end

-- Get state for a buffer (or ft key)
M.get_buf_state = function(bufnr)
  return M.state[bufnr] or {}
end

-- Backward-compatible alias
M.get_filetype_state = M.get_buf_state

-- Toggle severity
M.toggle_severity = function(severity_name)
  M.state.severities[severity_name] = not M.state.severities[severity_name]
end

-- Toggle category (key is bufnr in production, ft string in tests)
M.toggle_category = function(key, category_name)
  if not M.state[key] then
    M.state[key] = {}
  end
  local current = M.state[key][category_name]
  if current == nil then current = true end
  M.state[key][category_name] = not current
end

-- Toggle individual check (key is bufnr in production, ft string in tests)
M.toggle_check = function(key, check_name)
  if not M.state[key] then
    M.state[key] = {}
  end
  -- nil means enabled (default), so treat nil as true before negating
  local current = M.state[key][check_name]
  if current == nil then current = true end
  M.state[key][check_name] = not current
end

-- Toggle expansion state
M.toggle_expanded = function(category_name)
  M.state.expanded[category_name] = not M.state.expanded[category_name]
end

-- Check if category is expanded
M.is_expanded = function(category_name)
  return M.state.expanded[category_name] or false
end

-- Get enabled state for a category/check (key is bufnr in production, ft string in tests)
M.is_enabled = function(key, name)
  if not M.state[key] then
    return true -- Default enabled
  end
  local enabled = M.state[key][name]
  if enabled == nil then
    return true -- Default enabled
  end
  return enabled
end

return M
