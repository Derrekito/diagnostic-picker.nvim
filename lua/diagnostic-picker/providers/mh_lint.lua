-- mh_lint provider (MATLAB/Octave)
-- Manages miss_hit.cfg for MISS_HIT style rules, lint checks, and metrics.

local Provider = require("diagnostic-picker.provider_base")

local MhLintProvider = setmetatable({}, { __index = Provider })
MhLintProvider.__index = MhLintProvider

function MhLintProvider.new(config)
  return setmetatable(Provider.new(config), MhLintProvider)
end

-- Metric items use a different name than the miss_hit.cfg directive.
-- Map picker item names to miss_hit.cfg metric names.
local METRIC_MAP = {
  file_length_metric = "file_length",
  function_length    = "function_length",
  npath              = "npath",
  cnest              = "cnest",
}

local METRIC_ITEMS = {}
for k in pairs(METRIC_MAP) do METRIC_ITEMS[k] = true end

-- All style/lint rule names from the JSON config (non-metric toggle items).
local function is_rule_item(name)
  return not METRIC_ITEMS[name]
end

-- ── Project root resolution ─────────────────────────────────────────────────

-- Resolve the directory that holds (or should hold) miss_hit.cfg by walking up
-- from the buffer's file, not from nvim's cwd. miss_hit.cfg commonly lives at a
-- project root above the .m files (e.g. ports/kalman/miss_hit.cfg with sources
-- in matlab/), so a cwd-based lookup misses it unless nvim happens to be
-- launched from exactly the right directory.
local function get_project_root(bufnr)
  local fname = bufnr and vim.api.nvim_buf_get_name(bufnr) or vim.api.nvim_buf_get_name(0)
  if fname ~= "" then
    -- Prefer the nearest existing miss_hit.cfg; fall back to a VCS/project root.
    local root = vim.fs.root(fname, { "miss_hit.cfg", ".git" })
    if root then
      return root
    end
    -- No marker found: use the file's own directory rather than cwd.
    return vim.fs.dirname(fname)
  end
  return vim.fn.getcwd()
end

-- ── miss_hit.cfg parsing ────────────────────────────────────────────────────

local function parse_cfg(filepath)
  local result = {
    dialect = nil,
    suppressed_rules = {},
    enabled_rules = {},
    disabled_metrics = {},
    other_lines = {},
  }
  local f = io.open(filepath, "r")
  if not f then return nil end

  for line in f:lines() do
    local rule = line:match('^%s*suppress_rule%s*:%s*"([^"]+)"')
    if rule then
      result.suppressed_rules[rule] = true
      goto continue
    end

    rule = line:match('^%s*enable_rule%s*:%s*"([^"]+)"')
    if rule then
      result.enabled_rules[rule] = true
      goto continue
    end

    local metric = line:match('^%s*metric%s*:%s*"([^"]+)"%s+disable')
    if metric then
      result.disabled_metrics[metric] = true
      goto continue
    end

    -- metric: "X" report — explicitly enabled, skip (default behavior)
    if line:match('^%s*metric%s*:%s*"[^"]+"%s+report') then
      goto continue
    end

    -- metric: "X" limit N — treat as enabled, preserve as other_line
    if line:match('^%s*metric%s*:%s*"[^"]+"%s+limit') then
      table.insert(result.other_lines, line)
      goto continue
    end

    local dialect = line:match("^%s*(matlab)%s*:")
    if not dialect then dialect = line:match("^%s*(octave)%s*:") end
    if dialect then
      result.dialect = dialect
      goto continue
    end

    -- Preserve lines we don't manage (project_root, custom settings, comments)
    if line:match("%S") then
      table.insert(result.other_lines, line)
    end

    ::continue::
  end
  f:close()
  return result
end

-- ── miss_hit.cfg generation ─────────────────────────────────────────────────

function MhLintProvider:build_cfg_lines(current_state, bufnr)
  local project_root = get_project_root(bufnr)
  local cfg_path = project_root .. "/miss_hit.cfg"
  local buf_state = (bufnr and current_state[bufnr]) or {}

  -- Read existing config to preserve unmanaged lines
  local existing = parse_cfg(cfg_path)
  local other_lines = existing and existing.other_lines or {}

  -- Dialect
  local dialect = buf_state["__dialect"] or "matlab"

  -- Collect suppressed rules and disabled metrics
  local suppressed = {}
  local disabled_metrics = {}

  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" then
      for _, item in ipairs(section.items or {}) do
        local val = buf_state[item.name]
        if val == nil then val = item.default ~= false end

        if METRIC_ITEMS[item.name] then
          if not val then
            disabled_metrics[METRIC_MAP[item.name]] = true
          end
        else
          if not val then
            table.insert(suppressed, item.name)
          end
        end
      end
    end
  end

  table.sort(suppressed)

  -- Build output lines
  local lines = {}

  -- Preserved lines first (project_root, custom settings, etc.)
  for _, line in ipairs(other_lines) do
    table.insert(lines, line)
  end

  -- Dialect
  table.insert(lines, dialect .. ': "latest"')

  -- Suppressed rules
  for _, rule in ipairs(suppressed) do
    table.insert(lines, 'suppress_rule: "' .. rule .. '"')
  end

  -- Disabled metrics
  local sorted_metrics = {}
  for m in pairs(disabled_metrics) do table.insert(sorted_metrics, m) end
  table.sort(sorted_metrics)
  for _, m in ipairs(sorted_metrics) do
    table.insert(lines, 'metric: "' .. m .. '" disable')
  end

  return {
    lines = lines,
    project_root = project_root,
    cfg_path = cfg_path,
    dialect = dialect,
    suppressed_count = #suppressed,
    disabled_metric_count = #sorted_metrics,
  }
end

-- ── Provider interface ──────────────────────────────────────────────────────

function MhLintProvider:sync_state_from_files(buf_state, bufnr)
  local project_root = get_project_root(bufnr)
  local cfg_path = project_root .. "/miss_hit.cfg"

  if vim.fn.filereadable(cfg_path) ~= 1 then return end

  local cfg = parse_cfg(cfg_path)
  if not cfg then return end

  -- Dialect
  if cfg.dialect then
    buf_state["__dialect"] = cfg.dialect
  end

  -- Rules: start all enabled, then suppress what the config suppresses
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" then
      for _, item in ipairs(section.items or {}) do
        if is_rule_item(item.name) then
          if cfg.suppressed_rules[item.name] then
            buf_state[item.name] = false
          elseif cfg.enabled_rules[item.name] then
            buf_state[item.name] = true
          end
        elseif METRIC_ITEMS[item.name] then
          local metric_name = METRIC_MAP[item.name]
          if cfg.disabled_metrics[metric_name] then
            buf_state[item.name] = false
          end
        end
      end
    end
  end
end

function MhLintProvider:set_language_option(option_data, value, key)
  if key == nil then key = vim.bo.filetype end
  local st = require("diagnostic-picker.state").state
  if not st[key] then st[key] = {} end

  if option_data.kind == "radio" then
    for _, section in ipairs(self.sections) do
      if section.kind == "radio" then
        for _, item in ipairs(section.items or {}) do
          if item.name == value then
            st[key]["__" .. section.id] = value
            return
          end
        end
      end
    end
  elseif option_data.kind == "toggle" then
    local cur = st[key][value]
    st[key][value] = not (cur == nil and true or cur)
  end
end

local function relint()
  local ok, lint = pcall(require, "lint")
  if ok then lint.try_lint() end
end

function MhLintProvider:apply_config(current_state, bufnr)
  local result = self:build_cfg_lines(current_state, bufnr)

  local f = io.open(result.cfg_path, "w")
  if not f then
    return { success = false, message = "Could not write " .. result.cfg_path }
  end
  for _, line in ipairs(result.lines) do f:write(line .. "\n") end
  f:close()

  vim.schedule(relint)

  return {
    success = true,
    message = "Wrote " .. result.cfg_path
      .. "\nDialect: " .. result.dialect
      .. "\nSuppressed rules: " .. result.suppressed_count
      .. "\nDisabled metrics: " .. result.disabled_metric_count,
  }
end

function MhLintProvider:apply_session(current_state, bufnr)
  local result = self:build_cfg_lines(current_state, bufnr)

  -- Back up existing miss_hit.cfg if present
  local backup_path = result.cfg_path .. ".diagnostic-picker.bak"
  local has_existing = vim.fn.filereadable(result.cfg_path) == 1

  if has_existing then
    local src = io.open(result.cfg_path, "r")
    if src then
      local dst = io.open(backup_path, "w")
      if dst then
        dst:write(src:read("*a"))
        dst:close()
      end
      src:close()
    end
  end

  -- Write temp config
  local f = io.open(result.cfg_path, "w")
  if not f then
    return { success = false, message = "Could not write temp " .. result.cfg_path }
  end
  for _, line in ipairs(result.lines) do f:write(line .. "\n") end
  f:close()

  -- Restore on exit
  local restore_group = vim.api.nvim_create_augroup("mh_lint_session_restore", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = restore_group,
    once = true,
    callback = function()
      if vim.fn.filereadable(backup_path) == 1 then
        os.rename(backup_path, result.cfg_path)
      elseif not has_existing then
        os.remove(result.cfg_path)
      end
    end,
  })

  vim.schedule(relint)

  return {
    success = true,
    message = "Session config applied (temp miss_hit.cfg)"
      .. "\nDialect: " .. result.dialect
      .. "\nSuppressed rules: " .. result.suppressed_count
      .. "\nDisabled metrics: " .. result.disabled_metric_count,
  }
end

function MhLintProvider:get_config_info(bufnr)
  local project_root = get_project_root(bufnr)
  local cfg_path = project_root .. "/miss_hit.cfg"
  if vim.fn.filereadable(cfg_path) == 1 then
    return "miss_hit.cfg found"
  end
  return "No miss_hit.cfg (using defaults)"
end

function MhLintProvider:is_installed()
  return vim.fn.executable("mh_lint") == 1 and vim.fn.executable("mh_style") == 1
end

-- MISS_HIT rules are already organised into groups (Whitespace, Style, Naming,
-- Lint Checks, Metrics). Surface each toggle group as an expandable category
-- under the "Linter Categories" header so individual rules can be toggled on
-- expand — mirroring how the clangd provider presents clang-tidy categories.
-- The base expand_category() already lists a section's items by matching
-- section.title, so no expand override is needed.
function MhLintProvider:get_categories(bufnr)
  local categories = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" then
      table.insert(categories, {
        name       = section.title,
        desc       = section.desc,
        expandable = true,
      })
    end
  end
  return categories
end

-- List a category's rules on expand. The base expand_category only matches
-- sections of kind "category"; our rule groups are kind "toggle", so match by
-- title here instead.
function MhLintProvider:expand_category(category_name)
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.title == category_name then
      local result = {}
      for _, item in ipairs(section.items or {}) do
        table.insert(result, { name = item.name, config_source = "" })
      end
      return result
    end
  end
  return {}
end

-- The Dialect radio (matlab/octave) is a genuine either/or setting, not a rule
-- category, so it stays a top-level language option. The toggle groups are now
-- rendered as categories (above), so exclude them here to avoid showing twice.
function MhLintProvider:get_language_options(bufnr)
  local all = Provider.get_language_options(self, bufnr)
  local radio_only = {}
  for _, opt in ipairs(all) do
    if opt.kind == "radio" then
      table.insert(radio_only, opt)
    end
  end
  return radio_only
end

return MhLintProvider
