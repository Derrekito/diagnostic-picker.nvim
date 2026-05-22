-- Clangd provider (C/C++)
-- Subclasses Provider; handles .clangd file generation and clang-tidy expansion.

local Provider = require("diagnostic-picker.provider_base")

local ClangdProvider = setmetatable({}, { __index = Provider })
ClangdProvider.__index = ClangdProvider

function ClangdProvider.new(config)
  local self = Provider.new(config)
  return setmetatable(self, ClangdProvider)
end

-- ── Project root resolution ──────────────────────────────────────────────────

-- Get the project root for the LSP client attached to bufnr.
-- Falls back to vim.fn.getcwd() if no clangd client is attached.
local function get_project_root(bufnr)
  if bufnr then
    local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })
    if clients and #clients > 0 then
      local root = clients[1].config and clients[1].config.root_dir
      if root then return root end
    end
  end
  return vim.fn.getcwd()
end

-- ── Config file parsing ──────────────────────────────────────────────────────

local function parse_clangd_config(filepath)
  local result = { add_checks = {}, remove_checks = {}, compile_flags = {}, source = filepath }
  local f = io.open(filepath, "r")
  if not f then return result end

  local in_diagnostics, in_clang_tidy, in_add, in_remove = false, false, false, false
  local in_compile_flags, in_compile_add = false, false
  local in_flow_seq = false  -- inside a multi-line [...] flow sequence

  local function push(dest, raw)
    local item = raw:match("^%s*(.-)%s*$")
    item = item:match('^"(.+)"$') or item
    if item ~= "" then table.insert(dest, item) end
  end

  -- dest for the current flow sequence (set when [ is opened, cleared on ])
  local flow_dest = nil

  for line in f:lines() do
    -- Flow-sequence continuation: items between [ and ] with no '-' prefix
    if flow_dest then
      if line:match("%]") then flow_dest = nil end
      for entry in line:gmatch("([^%[%],%s]+)") do
        push(flow_dest, entry)
      end
      goto continue
    end

    -- Section headers (order matters: check Add: before generic ^%S reset)
    if     line:match("^Diagnostics:")                     then in_diagnostics = true;  in_compile_flags = false
    elseif line:match("^CompileFlags:")                    then in_compile_flags = true; in_diagnostics = false
    elseif in_diagnostics and line:match("^%s+ClangTidy:") then in_clang_tidy = true
    elseif in_clang_tidy  and line:match("^%s+Add:")      then in_add = true;  in_remove = false
    elseif in_clang_tidy  and line:match("^%s+Remove:")   then in_remove = true; in_add = false
    elseif in_compile_flags and line:match("^%s+Add:")    then in_compile_add = true
    elseif line:match("^%S")                               then in_add = false; in_remove = false; in_compile_add = false
    end

    -- Flow sequence on this line: Add: [a, b] or Add: [  (opening only)
    local flow = line:match("%[(.*)$")
    if flow and (in_add or in_remove) then
      local dest = in_add and result.add_checks or result.remove_checks
      local inner = flow:match("^(.-)%]") or flow  -- up to ] if present
      for entry in inner:gmatch("([^,%s]+)") do push(dest, entry) end
      if not flow:match("%]") then flow_dest = dest end  -- multi-line: keep reading
      in_add = false; in_remove = false
      goto continue
    end

    -- Block list: - item
    local item = line:match("^%s+%-%s*(.+)$")
    if item then
      if in_add         then table.insert(result.add_checks, item)
      elseif in_remove  then table.insert(result.remove_checks, item)
      elseif in_compile_add then
        table.insert(result.compile_flags, item:match('^"(.+)"$') or item)
      end
    end

    ::continue::
  end
  f:close()
  return result
end

local function get_clangd_configs(project_root)
  project_root = project_root or vim.fn.getcwd()
  return {
    global     = parse_clangd_config(vim.fn.expand("~/.config/clangd/config.yaml")),
    local_file = parse_clangd_config(project_root .. "/.clangd"),
  }
end

local function get_configured_checks(project_root)
  local all = {}
  local configs = get_clangd_configs(project_root)
  for _, cfg in pairs(configs) do
    for _, check in ipairs(cfg.add_checks) do
      all[check] = { enabled = true, source = cfg.source, type = "add" }
    end
  end
  for _, cfg in pairs(configs) do
    for _, check in ipairs(cfg.remove_checks) do
      if all[check] then
        all[check].enabled = false
        all[check].removed_by = cfg.source
      else
        all[check] = { enabled = false, source = cfg.source, type = "remove" }
      end
    end
  end
  return all
end

-- ── Available-category cache ─────────────────────────────────────────────────

local _available_categories = nil

local function available_categories()
  if _available_categories then return _available_categories end
  _available_categories = {}
  local h = io.popen("clang-tidy --list-checks -checks='*' 2>/dev/null")
  if not h then return _available_categories end
  for line in h:lines() do
    local check = line:match("^%s+(%S+)")
    if check then
      local prefix = check:match("^([^-]+-)")
      if prefix then _available_categories[prefix .. "*"] = true end
    end
  end
  h:close()
  return _available_categories
end

-- ── Provider interface ───────────────────────────────────────────────────────

-- Read current state from existing config files so the picker reflects reality on open.
-- Populate buf_state from existing config files so the picker reflects reality.
-- Priority: local .clangd > global config.yaml > JSON defaults.
-- Applied in order (global first, local second) so local values win.
-- Called once on first open; if neither file exists buf_state keeps JSON defaults.
function ClangdProvider:sync_state_from_files(buf_state, bufnr)
  local project_root = get_project_root(bufnr)
  local global_path = vim.fn.expand("~/.config/clangd/config.yaml")
  local local_path  = project_root .. "/.clangd"
  local has_global  = vim.fn.filereadable(global_path) == 1
  local has_local   = vim.fn.filereadable(local_path) == 1

  if not has_global and not has_local then
    return  -- no config files; keep JSON defaults
  end

  -- Build lookup of all -W flags we manage so we can recognise them in config
  local managed_flags = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.apply_to == "compile_flags" then
      for _, item in ipairs(section.items or {}) do
        managed_flags[item.name] = true
      end
    end
  end

  -- Start with all managed flags off; config files enable only what they list
  for flag, _ in pairs(managed_flags) do
    buf_state[flag] = false
  end

  -- Apply configs in priority order: global first, local second (local wins)
  local ordered = {}
  if has_global then table.insert(ordered, parse_clangd_config(global_path)) end
  if has_local  then table.insert(ordered, parse_clangd_config(local_path)) end

  for _, cfg in ipairs(ordered) do
    for _, flag in ipairs(cfg.compile_flags) do
      local std = flag:match("^-std=(.+)")
      if std then
        buf_state["__cpp_standard"] = std
      elseif managed_flags[flag] then
        buf_state[flag] = true
      end
    end
  end

  -- Sync clang-tidy category state from config files.
  -- When config files exist, only explicitly Added categories are on; everything
  -- else is off. This prevents categories absent from the config from defaulting
  -- to enabled (which would cause them to be written into the local .clangd on apply).
  local configured = get_configured_checks(project_root)
  local any_config = has_global or has_local

  -- Collect all category names managed by this provider
  local managed_categories = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        managed_categories[item.name] = true
      end
    end
  end

  if any_config then
    -- Start all categories off; only explicitly Added ones get turned on
    for cat, _ in pairs(managed_categories) do
      buf_state[cat] = false
    end
    for check, info in pairs(configured) do
      if managed_categories[check] then
        buf_state[check] = info.enabled
      end
    end
  end
end

-- get_categories: annotate items with availability and config-source info.
function ClangdProvider:get_categories(bufnr)
  local project_root = get_project_root(bufnr)
  local avail   = available_categories()
  local configured = get_configured_checks(project_root)
  local plugin_opts = require("diagnostic-picker.config").get()
  local categories = {}

  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        local cat = vim.tbl_extend("keep", {}, item)
        cat.expandable   = section.expandable
        cat.not_installed = not avail[item.name]

        if not cat.not_installed then
          local src = ""
          if configured[item.name] then
            local info = configured[item.name]
            local icon = info.source:match("config.yaml")
              and plugin_opts.icons.global_config
              or  plugin_opts.icons.local_config
            src = " " .. icon
            if info.type == "remove" then src = src .. plugin_opts.icons.disabled end
          end
          cat.config_source = src
        end

        table.insert(categories, cat)
      end
    end
  end
  return categories
end

-- get_language_options: return radio + toggle sections for the UI.
-- bufnr must be the buffer captured before the picker opened (vim.bo.filetype
-- is unreliable inside Telescope because focus moves to the prompt buffer).
function ClangdProvider:get_language_options(bufnr)
  local opts = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "radio" or (section.kind == "toggle" and section.apply_to == "compile_flags") then
      for _, item in ipairs(section.items or {}) do
        table.insert(opts, {
          kind     = section.kind,
          group    = section.title,
          name     = item.name,
          desc     = item.desc,
          is_selected = self:_item_is_selected(section, item, bufnr),
        })
      end
    end
  end
  return opts
end

-- _item_is_selected: check current in-memory state for this item.
-- key is bufnr (integer) in production; may be an ft string when called from tests.
function ClangdProvider:_item_is_selected(section, item, key)
  -- key can be a bufnr (integer) or ft string (from tests/legacy callers)
  local lookup_key = key
  if lookup_key == nil then
    lookup_key = vim.bo.filetype
  end
  local buf_state = require("diagnostic-picker.state").state[lookup_key] or {}
  if section.kind == "radio" then
    -- Radio: compare against the stored selected value
    local selected = buf_state["__" .. section.id] or self:_default_radio(section)
    return item.name == selected
  else
    local val = buf_state[item.name]
    if val == nil then return item.default ~= false end
    return val
  end
end

function ClangdProvider:_default_radio(section)
  for _, item in ipairs(section.items or {}) do
    if item.default then return item.name end
  end
  return section.items[1] and section.items[1].name or ""
end

-- set_language_option: called when user presses Space on a radio/toggle item.
-- key must be passed explicitly; vim.bo.filetype is wrong inside Telescope callbacks.
-- key is bufnr (integer) in production; may be ft string in tests/legacy callers.
function ClangdProvider:set_language_option(option_data, value, key)
  if key == nil then key = vim.bo.filetype end
  local state  = require("diagnostic-picker.state").state
  if not state[key] then state[key] = {} end

  if option_data.kind == "radio" then
    -- Find which section this item belongs to and store selected name
    for _, section in ipairs(self.sections) do
      if section.kind == "radio" then
        for _, item in ipairs(section.items or {}) do
          if item.name == value then
            state[key]["__" .. section.id] = value
            return
          end
        end
      end
    end
  elseif option_data.kind == "toggle" then
    state[key][value] = not (state[key][value] ~= false and state[key][value] ~= nil and state[key][value] or false)
  end
end

-- get_config_info: summary string for the picker header.
function ClangdProvider:get_config_info(bufnr)
  local project_root = get_project_root(bufnr)
  local has_global = vim.fn.filereadable(vim.fn.expand("~/.config/clangd/config.yaml")) == 1
  local has_local  = vim.fn.filereadable(project_root .. "/.clangd") == 1
  if has_global and has_local then return "Global + Local .clangd"
  elseif has_global            then return "Global only"
  elseif has_local             then return "Local .clangd only"
  else                              return "No config found"
  end
end

-- expand_category: shell out to clang-tidy to list individual checks.
function ClangdProvider:expand_category(category_name)
  local handle = io.popen("clang-tidy --list-checks -checks='" .. category_name .. "' 2>/dev/null")
  if not handle then return {} end

  local checks     = {}
  local configured = get_configured_checks()
  local icons      = require("diagnostic-picker.config").get().icons
  local pattern    = "^%s*(" .. category_name:gsub("%*", "[^%s]+") .. ")%s*$"

  for line in handle:lines() do
    local check = line:match(pattern)
    if check then
      local src = ""
      if configured[check] then
        local info = configured[check]
        src = " " .. (info.source:match("config.yaml") and icons.global_config or icons.local_config)
        if info.type == "remove" then src = src .. icons.disabled end
      end
      table.insert(checks, { name = check, config_source = src })
    end
  end
  handle:close()
  return checks
end

-- apply_config: write .clangd file from current state.
-- current_state is the full state table (keyed by bufnr or ft string).
-- bufnr: the buffer that was active when the picker opened.
function ClangdProvider:apply_config(current_state, bufnr)
  local project_root = get_project_root(bufnr)
  local ft           = bufnr and vim.bo[bufnr].filetype or vim.bo.filetype
  local clangd_path  = project_root .. "/.clangd"
  local buf_state    = current_state[bufnr] or current_state[ft] or {}

  -- Resolve C++ standard (radio)
  local cpp_std = buf_state["__cpp_standard"]
  if not cpp_std then
    for _, section in ipairs(self.sections) do
      if section.kind == "radio" then
        cpp_std = self:_default_radio(section)
        break
      end
    end
  end

  -- Collect enabled compile flags (toggles with apply_to=compile_flags)
  local compile_flags = { ("-std=" .. cpp_std) }
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.apply_to == "compile_flags" then
      for _, item in ipairs(section.items or {}) do
        local enabled = buf_state[item.name]
        if enabled == nil then enabled = item.default ~= false end
        if enabled then table.insert(compile_flags, item.name) end
      end
    end
  end

  -- Collect disabled clang-tidy checks
  local remove_checks = {}
  for name, enabled in pairs(buf_state) do
    if not enabled and type(name) == "string" and not name:match("^__") and not name:match("^%-") then
      table.insert(remove_checks, name)
    end
  end
  table.sort(remove_checks)

  -- Preserve enabled checks from global config
  local add_checks = {}
  for check, info in pairs(get_configured_checks(project_root)) do
    if info.enabled and info.source:match("config.yaml") then
      table.insert(add_checks, check)
    end
  end

  -- Build the set of -W flags we're managing so we can remove them first,
  -- preventing duplication with whatever the global config already adds.
  local managed_w_flags = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.apply_to == "compile_flags" then
      for _, item in ipairs(section.items or {}) do
        table.insert(managed_w_flags, item.name)
      end
    end
  end

  -- Write .clangd
  -- CompileFlags.Remove strips flags inherited from the global config.yaml before
  -- we add ours, preventing duplicates like "-std=c++17 ... -std=c++17" in the
  -- compile command. clangd merges local and global configs additively, so without
  -- Remove the global flags survive alongside our local ones.
  local lines = {
    "# Local clangd overrides — generated by diagnostic-picker.nvim",
    "",
    "CompileFlags:",
    "  Remove:",
    '    - "-std=*"',  -- strip any global -std= so our selection is the only one
  }
  for _, flag in ipairs(managed_w_flags) do
    -- strip all -W flags we manage so only the user's current selection survives
    table.insert(lines, '    - "' .. flag .. '"')
  end
  table.insert(lines, "  Add:")
  for _, flag in ipairs(compile_flags) do
    table.insert(lines, '    - "' .. flag .. '"')
  end
  table.insert(lines, "")
  table.insert(lines, "Diagnostics:")
  table.insert(lines, "  ClangTidy:")
  if #add_checks > 0 then
    table.insert(lines, "    Add:")
    for _, c in ipairs(add_checks) do table.insert(lines, "      - " .. c) end
  end
  if #remove_checks > 0 then
    table.insert(lines, "    Remove:")
    for _, c in ipairs(remove_checks) do table.insert(lines, "      - " .. c) end
  else
    table.insert(lines, "    Remove: []")
  end

  local existing = vim.fn.filereadable(clangd_path) == 1
  local f = io.open(clangd_path, "w")
  if not f then
    return { success = false, message = "Could not write " .. clangd_path }
  end
  for _, line in ipairs(lines) do f:write(line .. "\n") end
  f:close()

  self:restart_lsp(bufnr)

  return {
    success = true,
    message = (existing and "Updated" or "Created") .. " " .. clangd_path
      .. "\nC++ standard: " .. cpp_std
      .. "\nDisabled checks: " .. #remove_checks,
  }
end

function ClangdProvider:is_installed()
  return vim.fn.executable("clangd") == 1
end

return ClangdProvider
