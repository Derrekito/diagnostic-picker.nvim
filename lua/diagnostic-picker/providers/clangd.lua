-- Clangd provider (C/C++)
-- Subclasses Provider; handles .clangd file generation and clang-tidy expansion.

local Provider = require("diagnostic-picker.provider_base")

local ClangdProvider = setmetatable({}, { __index = Provider })
ClangdProvider.__index = ClangdProvider

-- ── User config import ───────────────────────────────────────────────────────
-- The generated .clangd is fully picker-owned and rewritten on every apply.
-- Manual settings live in .clangd-user.yaml, which the picker NEVER writes
-- (except a one-time migration of a pre-existing hand-written .clangd). On
-- apply, the user file is parsed and MERGED into the single generated YAML
-- document: user CompileFlags.Add/Remove and ClangTidy Add/Remove entries are
-- folded into the managed lists, other keys are carried over verbatim. No
-- '---' document separators are ever emitted. Managed -W/-std flags remain
-- picker-authoritative: user copies of them are filtered out on merge.

local USER_FILE = ".clangd-user.yaml"

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do table.insert(lines, line) end
  f:close()
  return lines
end

local function write_lines(path, lines)
  local f = io.open(path, "w")
  if not f then return false end
  for _, line in ipairs(lines) do f:write(line .. "\n") end
  f:close()
  return true
end

-- Parse .clangd-user.yaml into mergeable pieces. Add/Remove lists under
-- CompileFlags and Diagnostics.ClangTidy are extracted as items; everything
-- else is kept as verbatim lines so it can be re-emitted in place inside the
-- single generated document. '---' lines in the user file are ignored (the
-- whole file is treated as one config). Returns nil if the file is absent.
local function parse_user_config(project_root)
  local lines = read_lines(project_root .. "/" .. USER_FILE)
  if not lines or #lines == 0 then return nil end

  local out = {
    cf_add = {}, cf_remove = {}, cf_other = {},      -- CompileFlags
    tidy_add = {}, tidy_remove = {}, tidy_other = {}, -- Diagnostics.ClangTidy
    diag_other = {},                                  -- Diagnostics, non-ClangTidy
    other = {},                                       -- all other top-level blocks
  }

  local section, list, verbatim = nil, nil, nil
  local in_tidy, tidy_indent = false, 0

  local function push_item(dest, raw)
    local item = raw:match("^%s*(.-)%s*$")
    item = item:match('^"(.+)"$') or item:match("^'(.+)'$") or item
    if item ~= "" then table.insert(dest, item) end
  end

  -- Handle 'Add:'/'Remove:' child keys: flow form fills dest now, block form
  -- arms `list` for the '- item' lines that follow. Returns the armed list.
  local function open_list(dest, rest)
    local flow = rest:match("^%[(.*)%]%s*$")
    if flow then
      for entry in flow:gmatch("([^,]+)") do push_item(dest, entry) end
      return nil
    end
    return dest
  end

  for _, line in ipairs(lines) do
    if line:match("^%-%-%-%s*$") then
      section, list, verbatim, in_tidy = nil, nil, nil, false
    elseif line:match("^%s*$") then
      if verbatim then table.insert(verbatim, line) end
    elseif line:match("^%S") then
      list, verbatim, in_tidy = nil, nil, false
      local key = line:match("^([%w_%-]+):")
      if key == "CompileFlags" then
        section = "cf"
      elseif key == "Diagnostics" then
        section = "diag"
      elseif key then
        section = "other"
        verbatim = out.other
        table.insert(verbatim, line)
      else
        section = nil -- top-level comment or stray text: dropped
      end
    elseif section == "cf" then
      local key, rest = line:match("^%s+([%w_%-]+):%s*(.*)$")
      if key then
        list, verbatim = nil, nil
        if key == "Add" then
          list = open_list(out.cf_add, rest)
        elseif key == "Remove" then
          list = open_list(out.cf_remove, rest)
        else
          verbatim = out.cf_other
          table.insert(verbatim, line)
        end
      elseif list and line:match("^%s+%-") then
        push_item(list, line:match("^%s+%-%s*(.+)$"))
      elseif verbatim then
        table.insert(verbatim, line)
      end
    elseif section == "diag" then
      local indent, key, rest = line:match("^(%s+)([%w_%-]+):%s*(.*)$")
      if key == "ClangTidy" then
        in_tidy, tidy_indent = true, #indent
        list, verbatim = nil, nil
      elseif key and in_tidy and #indent > tidy_indent then
        list, verbatim = nil, nil
        if key == "Add" then
          list = open_list(out.tidy_add, rest)
        elseif key == "Remove" then
          list = open_list(out.tidy_remove, rest)
        else
          verbatim = out.tidy_other
          table.insert(verbatim, line)
        end
      elseif key then
        -- direct child of Diagnostics other than ClangTidy
        in_tidy, list = false, nil
        verbatim = out.diag_other
        table.insert(verbatim, line)
      elseif list and line:match("^%s+%-") then
        push_item(list, line:match("^%s+%-%s*(.+)$"))
      elseif verbatim then
        table.insert(verbatim, line)
      end
    elseif verbatim then
      table.insert(verbatim, line)
    end
  end
  return out
end

function ClangdProvider.new(config)
  local self = Provider.new(config)
  return setmetatable(self, ClangdProvider)
end

-- ── Project root resolution ──────────────────────────────────────────────────

-- Get the project root for the LSP client attached to bufnr.
-- Falls back to vim.fn.getcwd() if no clangd client is attached.
local function get_project_root(bufnr)
  -- Search upward from the buffer's own file for a project marker first. This is
  -- authoritative and doesn't depend on a clangd client being attached (which it
  -- isn't, e.g. on first read) or on clangd's root_dir (which can be wrong, e.g.
  -- rooting at $HOME). Falls back to clangd's root_dir, then getcwd().
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local fname = vim.api.nvim_buf_get_name(bufnr)
    if fname and fname ~= "" then
      local found = vim.fs.find(
        { "compile_commands.json", ".clangd", "compile_flags.txt", ".git" },
        { path = vim.fs.dirname(fname), upward = true }
      )[1]
      if found then return vim.fs.dirname(found) end
    end
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

-- Expose internals for diagnostics (log.report_config_source uses these).
function ClangdProvider:get_project_root(bufnr)
  return get_project_root(bufnr)
end

function ClangdProvider:get_configured_checks(project_root)
  return get_configured_checks(project_root)
end

-- Read current state from existing config files so the picker reflects reality on open.
-- Populate buf_state from existing config files so the picker reflects reality.
-- Priority: local .clangd > global config.yaml > JSON defaults.
-- Applied in order (global first, local second) so local values win.
-- Called once on first open; if neither file exists buf_state keeps JSON defaults.
function ClangdProvider:sync_state_from_files(buf_state, bufnr)
  local log = require("diagnostic-picker.log")
  local project_root = get_project_root(bufnr)
  local global_path = vim.fn.expand("~/.config/clangd/config.yaml")
  local local_path  = project_root .. "/.clangd"
  local has_global  = vim.fn.filereadable(global_path) == 1
  local has_local   = vim.fn.filereadable(local_path) == 1

  log.debug("sync_state_from_files: root=" .. project_root
    .. " local.clangd=" .. (has_local and "FOUND" or "missing")
    .. " global=" .. (has_global and "FOUND" or "missing"))

  -- Warn if the resolved root looks wrong (e.g. $HOME) — a common failure that
  -- makes the picker read the wrong/no .clangd and silently show defaults.
  if project_root == vim.fn.expand("~") or project_root == "/" then
    log.warn("project root resolved to '" .. project_root
      .. "' — likely wrong; .clangd may not be found. Check for a stray .git/marker above your project.")
  end

  if not has_global and not has_local then
    log.info("no .clangd or global config found under " .. project_root
      .. " — using JSON defaults (not reading any file).")
    return  -- no config files; keep JSON defaults
  end

  local parsed = parse_clangd_config(local_path)
  log.debug("parsed local .clangd: " .. #parsed.add_checks .. " Add, "
    .. #parsed.remove_checks .. " Remove checks")

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
        -- category glob (e.g. modernize-*)
        buf_state[check] = info.enabled
      else
        -- individual child check (e.g. modernize-use-trailing-return-type). Record
        -- its state too so a child explicitly disabled via Remove: round-trips and
        -- shows as off in the picker even though its parent category is enabled.
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
  -- Build the match pattern from the category glob. NOTE: in gsub's REPLACEMENT
  -- string, '%' is special (capture refs), so "[^%s]+" would be mangled to
  -- "[^s]+" — which stops matching at the first 's' and silently dropped most
  -- checks (e.g. modernize-use-trailing-return-type). Use a function replacement
  -- so the '%' is preserved literally.
  local glob = category_name:gsub("%*", function() return "[^%s]+" end)
  local pattern    = "^%s*(" .. glob .. ")%s*$"

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

  -- Build the set of clang-tidy category names this provider manages.
  local managed_categories = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        managed_categories[item.name] = true
      end
    end
  end

  -- Single source of truth: buf_state over the managed categories.
  -- enabled -> Add:, disabled -> Remove:. This is what makes toggles round-trip:
  -- the reader (get_configured_checks/sync) decides enabled-ness from Add:, so the
  -- writer MUST record enabled categories in Add:. (The old code derived Add only
  -- from a global config.yaml, which doesn't exist here, so every enabled category
  -- was dropped on save and reappeared as disabled on reopen.)
  local add_checks, remove_checks = {}, {}
  for cat, _ in pairs(managed_categories) do
    local enabled = buf_state[cat]
    if enabled == nil then
      -- not in state yet: fall back to the item's JSON default
      enabled = (self._item_by_name[cat] and self._item_by_name[cat].item.default ~= false)
    end
    if enabled then
      table.insert(add_checks, cat)
    else
      table.insert(remove_checks, cat)
    end
  end

  -- Individual child checks the user disabled (e.g. modernize-use-trailing-return-type).
  -- These are keys in buf_state that look like specific clang-tidy checks (contain a
  -- '-', not a managed category glob, not a -W flag or __internal key) and are false.
  -- clang-tidy's Remove: accepts specific check names, so emitting them disables just
  -- that check even though its parent category (e.g. modernize-*) is in Add:.
  for name, val in pairs(buf_state) do
    if val == false
      and type(name) == "string"
      and name:find("-", 1, true)            -- looks like a check (has a hyphen)
      and not name:match("%*$")              -- not a category glob (handled above)
      and not managed_categories[name]
      and not name:match("^%-")              -- not a -W compile flag
      and not name:match("^__")              -- not an internal key
    then
      table.insert(remove_checks, name)
    end
  end

  table.sort(add_checks)
  table.sort(remove_checks)

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

  -- Migration: a pre-existing .clangd that we didn't generate is hand-written.
  -- Preserve it by moving its content into .clangd-user.yaml (only if that file
  -- doesn't exist yet) before we overwrite — it then round-trips via the import.
  local user_path = project_root .. "/" .. USER_FILE
  local existing_lines = read_lines(clangd_path)
  local is_generated = existing_lines and (existing_lines[1] or ""):match("diagnostic%-picker")
  local migrated = false
  if existing_lines and #existing_lines > 0 and not is_generated
    and vim.fn.filereadable(user_path) == 0 then
    if not write_lines(user_path, existing_lines) then
      return { success = false, message = "Could not migrate hand-written .clangd to " .. user_path }
    end
    migrated = true
  end

  local lines = self:_compose_clangd(project_root, compile_flags, add_checks, remove_checks, managed_w_flags)

  local existing = existing_lines ~= nil
  if not write_lines(clangd_path, lines) then
    return { success = false, message = "Could not write " .. clangd_path }
  end

  self:restart_lsp(bufnr)

  local message = (existing and "Updated" or "Created") .. " " .. clangd_path
    .. "\nC++ standard: " .. cpp_std
    .. "\nDisabled checks: " .. #remove_checks
  if migrated then
    message = message .. "\nMigrated hand-written .clangd to " .. user_path
  end
  return { success = true, message = message }
end

-- Compose the full .clangd contents as ONE YAML document: managed sections
-- from the picker with the user's .clangd-user.yaml merged in. No '---'
-- separators are emitted — user Add/Remove entries are folded into the
-- managed lists and other user keys are carried over verbatim.
-- CompileFlags.Remove strips flags inherited from the global config.yaml
-- before we add ours, preventing duplicates in the compile command.
function ClangdProvider:_compose_clangd(project_root, compile_flags, add_checks, remove_checks, managed_w_flags)
  local user = parse_user_config(project_root)
  local managed_set = {}
  for _, f in ipairs(managed_w_flags) do managed_set[f] = true end

  -- Merge user compile flags. Picker-wins: -std= and the managed -W toggles
  -- are controlled by the UI, so user copies of those are filtered out.
  compile_flags = vim.list_slice(compile_flags)
  local present = {}
  for _, f in ipairs(compile_flags) do present[f] = true end
  if user then
    for _, f in ipairs(user.cf_add) do
      if not f:match("^%-std=") and not managed_set[f] and not present[f] then
        table.insert(compile_flags, f)
        present[f] = true
      end
    end
  end

  -- Merge user clang-tidy entries. A check the picker disabled stays in
  -- Remove even if the user file Adds it (picker-wins for managed state).
  add_checks = vim.list_slice(add_checks)
  remove_checks = vim.list_slice(remove_checks)
  local in_add, in_remove = {}, {}
  for _, c in ipairs(add_checks) do in_add[c] = true end
  for _, c in ipairs(remove_checks) do in_remove[c] = true end
  if user then
    for _, c in ipairs(user.tidy_add) do
      if not in_add[c] and not in_remove[c] then
        table.insert(add_checks, c); in_add[c] = true
      end
    end
    for _, c in ipairs(user.tidy_remove) do
      if not in_remove[c] and not in_add[c] then
        table.insert(remove_checks, c); in_remove[c] = true
      end
    end
  end
  table.sort(add_checks)
  table.sort(remove_checks)

  local lines = {
    "# Generated by diagnostic-picker.nvim — DO NOT EDIT.",
    "# Manual settings belong in " .. USER_FILE .. "; they are merged in on every apply.",
    "",
    "CompileFlags:",
    "  Remove:",
    '    - "-std=*"',  -- strip any global -std= so our selection is the only one
  }
  for _, flag in ipairs(managed_w_flags) do
    -- strip all -W flags we manage so only the user's current selection survives
    table.insert(lines, '    - "' .. flag .. '"')
  end
  if user then
    for _, flag in ipairs(user.cf_remove) do
      if flag ~= "-std=*" and not managed_set[flag] then
        table.insert(lines, '    - "' .. flag .. '"')
      end
    end
  end
  table.insert(lines, "  Add:")
  for _, flag in ipairs(compile_flags) do
    table.insert(lines, '    - "' .. flag .. '"')
  end
  if user then vim.list_extend(lines, user.cf_other) end
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
  if user then
    vim.list_extend(lines, user.tidy_other)
    vim.list_extend(lines, user.diag_other)
    if #user.other > 0 then
      table.insert(lines, "")
      table.insert(lines, "# Merged from " .. USER_FILE .. " — edit that file, not this one.")
      vim.list_extend(lines, user.other)
    end
  end
  return lines
end

-- Re-merge .clangd-user.yaml into the generated .clangd without needing picker
-- state: the picker-owned pieces (-std, managed -W flags, clang-tidy lists)
-- are reconstructed by parsing the current file, then the (possibly edited)
-- user file is merged fresh. Used by the BufWritePost autocmd so hand edits
-- take effect immediately. Returns true on success; refuses to touch a
-- .clangd it didn't generate.
-- Caveat: clang-tidy entries previously merged from the user file can't be
-- told apart from picker-owned ones here, so DELETING a tidy entry from the
-- user file takes effect on the next picker apply, not on save.
function ClangdProvider:reimport_user_config(project_root)
  local clangd_path = project_root .. "/.clangd"
  local lines = read_lines(clangd_path)
  if not lines or not (lines[1] or ""):match("diagnostic%-picker") then
    return false
  end

  local parsed = parse_clangd_config(clangd_path)

  local managed_w_flags, managed_set = {}, {}
  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.apply_to == "compile_flags" then
      for _, item in ipairs(section.items or {}) do
        table.insert(managed_w_flags, item.name)
        managed_set[item.name] = true
      end
    end
  end

  -- Picker-owned compile flags = parsed Add entries that are -std= or managed
  -- -W toggles; everything else re-derives from the user file in compose.
  local compile_flags = {}
  for _, f in ipairs(parsed.compile_flags) do
    if f:match("^%-std=") or managed_set[f] then table.insert(compile_flags, f) end
  end

  local out = self:_compose_clangd(project_root, compile_flags, parsed.add_checks, parsed.remove_checks, managed_w_flags)
  if not write_lines(clangd_path, out) then return false end
  self:restart_lsp()
  return true
end

function ClangdProvider:is_installed()
  return vim.fn.executable("clangd") == 1
end

return ClangdProvider
