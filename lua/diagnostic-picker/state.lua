-- State management for diagnostic picker

local M = {}

-- Global state
M.state = {
  severities = {
    ERROR = true,
    WARN = true,
    INFO = true,
    HINT = true,
  },
  expanded = {}, -- Track which categories are expanded
}

-- Initialize category state for a filetype
M.init_category_state = function(ft, categories)
  if not M.state[ft] then
    M.state[ft] = {}
    for _, cat in ipairs(categories or {}) do
      -- Default to enabled
      M.state[ft][cat.name] = true
    end
  end
end

-- Get state for current filetype
M.get_filetype_state = function(ft)
  return M.state[ft] or {}
end

-- Toggle severity
M.toggle_severity = function(severity_name)
  M.state.severities[severity_name] = not M.state.severities[severity_name]
end

-- Toggle category
M.toggle_category = function(ft, category_name)
  if not M.state[ft] then
    M.state[ft] = {}
  end
  local current = M.state[ft][category_name]
  if current == nil then current = true end
  M.state[ft][category_name] = not current
end

-- Toggle individual check
M.toggle_check = function(ft, check_name)
  if not M.state[ft] then
    M.state[ft] = {}
  end
  -- nil means enabled (default), so treat nil as true before negating
  local current = M.state[ft][check_name]
  if current == nil then current = true end
  M.state[ft][check_name] = not current
end

-- Toggle expansion state
M.toggle_expanded = function(category_name)
  M.state.expanded[category_name] = not M.state.expanded[category_name]
end

-- Check if category is expanded
M.is_expanded = function(category_name)
  return M.state.expanded[category_name] or false
end

-- Get enabled state for a category/check
M.is_enabled = function(ft, name)
  if not M.state[ft] then
    return true -- Default enabled
  end
  local enabled = M.state[ft][name]
  if enabled == nil then
    return true -- Default enabled
  end
  return enabled
end

return M
