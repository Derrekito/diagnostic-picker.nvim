-- Clangd provider for C/C++

local M = {}

-- Provider metadata
M.name = "clangd"
M.filetypes = { "c", "cpp" }

-- Internal state for C++ standard
local cpp_standard = "c++17" -- Default

-- Boolean compiler flags state (ordered for display)
local compiler_flag_order = {
  -- Broad sets
  "-Wall",
  "-Wextra",
  "-Wpedantic",
  "-Weverything",
  -- Specific useful flags not in -Wall/-Wextra
  "-Wshadow",
  "-Wnon-virtual-dtor",
  "-Wold-style-cast",
  "-Wcast-align",
  "-Wunused",
  "-Woverloaded-virtual",
  "-Wconversion",
  "-Wsign-conversion",
  "-Wmisleading-indentation",
  "-Wnull-dereference",
  "-Wdouble-promotion",
  "-Wformat=2",
  "-Wimplicit-fallthrough",
  "-Wlifetime",
}

local compiler_flags = {}
for _, flag in ipairs(compiler_flag_order) do
  compiler_flags[flag] = false
end

-- C++ standard options
local cpp_standards = {
  "c++98", "c++03", "c++11", "c++14", "c++17", "c++20", "c++23", "c++26"
}

-- Parse YAML-like clangd config file
local function parse_clangd_config(filepath)
  local config = {
    add_checks = {},
    remove_checks = {},
    compile_flags = {},
    source = filepath
  }

  local file = io.open(filepath, "r")
  if not file then return config end

  local in_diagnostics = false
  local in_clang_tidy = false
  local in_add = false
  local in_remove = false
  local in_compile_flags = false
  local in_compile_add = false

  for line in file:lines() do
    -- Track sections
    if line:match("^Diagnostics:") then
      in_diagnostics = true
      in_compile_flags = false
    elseif line:match("^CompileFlags:") then
      in_compile_flags = true
      in_diagnostics = false
    elseif in_diagnostics and line:match("^%s+ClangTidy:") then
      in_clang_tidy = true
    elseif in_clang_tidy and line:match("^%s+Add:") then
      in_add = true
      in_remove = false
    elseif in_clang_tidy and line:match("^%s+Remove:") then
      in_remove = true
      in_add = false
    elseif in_compile_flags and line:match("^%s+Add:") then
      in_compile_add = true
    elseif line:match("^%S") then
      -- Reset when we hit a new top-level section
      in_add = false
      in_remove = false
      in_compile_add = false
    end

    -- Parse entries
    if in_add and line:match("^%s+%-") then
      local check = line:match("^%s+%-%s*(.+)$")
      if check then
        table.insert(config.add_checks, check)
      end
    elseif in_remove and line:match("^%s+%-") then
      local check = line:match("^%s+%-%s*(.+)$")
      if check then
        table.insert(config.remove_checks, check)
      end
    elseif in_compile_add and line:match("^%s+%-") then
      local flag = line:match("^%s+%-%s*\"(.+)\"$")
      if flag then
        table.insert(config.compile_flags, flag)
      end
    end
  end

  file:close()
  return config
end

-- Get the active clangd configs (global + local merged)
local function get_clangd_configs()
  local global_config_path = vim.fn.expand("~/.config/clangd/config.yaml")
  local local_config_path = vim.fn.getcwd() .. "/.clangd"

  local configs = {
    global = parse_clangd_config(global_config_path),
    local_file = parse_clangd_config(local_config_path),
  }

  -- Determine current C++ standard and boolean flags from configs
  for _, config in pairs(configs) do
    for _, flag in ipairs(config.compile_flags) do
      local std = flag:match("^-std=(.+)")
      if std then
        cpp_standard = std
      elseif compiler_flags[flag] ~= nil then
        compiler_flags[flag] = true
      end
    end
  end

  return configs
end

-- Get all configured checks (merged from configs)
local function get_all_configured_checks()
  local configs = get_clangd_configs()
  local all_checks = {}

  -- Merge Add checks from both configs
  for _, config in pairs(configs) do
    for _, check in ipairs(config.add_checks) do
      all_checks[check] = {
        enabled = true,
        source = config.source,
        type = "add"
      }
    end
  end

  -- Apply Remove checks
  for _, config in pairs(configs) do
    for _, check in ipairs(config.remove_checks) do
      if all_checks[check] then
        all_checks[check].enabled = false
        all_checks[check].removed_by = config.source
      else
        all_checks[check] = {
          enabled = false,
          source = config.source,
          type = "remove"
        }
      end
    end
  end

  return all_checks
end

-- Get config info string
M.get_config_info = function()
  local global_path = vim.fn.expand("~/.config/clangd/config.yaml")
  local local_path = vim.fn.getcwd() .. "/.clangd"
  local has_global = vim.fn.filereadable(global_path) == 1
  local has_local = vim.fn.filereadable(local_path) == 1

  if has_global and has_local then
    return "Global + Local .clangd"
  elseif has_global then
    return "Global only"
  elseif has_local then
    return "Local .clangd only"
  else
    return "No config found"
  end
end

-- Check if clangd is installed
M.is_installed = function()
  return vim.fn.executable("clangd") == 1
end

-- Cache of available category prefixes (e.g. "modernize-*" -> true)
local available_categories = nil

local function get_available_categories()
  if available_categories then return available_categories end
  available_categories = {}
  local handle = io.popen("clang-tidy --list-checks -checks='*' 2>/dev/null")
  if not handle then return available_categories end
  for line in handle:lines() do
    local check = line:match("^%s+(%S+)")
    if check then
      local prefix = check:match("^([^-]+-)")
      if prefix then
        available_categories[prefix .. "*"] = true
      end
    end
  end
  handle:close()
  return available_categories
end

-- Get language options (C++ standards + boolean compiler flags)
M.get_language_options = function()
  local options = {}

  -- C++ standard (radio: only one selected at a time)
  for _, std in ipairs(cpp_standards) do
    table.insert(options, {
      kind = "radio",
      group = "C++ Standard",
      name = std,
      is_selected = (std == cpp_standard),
    })
  end

  -- Boolean compiler flags (toggle: independent on/off)
  for _, flag in ipairs(compiler_flag_order) do
    table.insert(options, {
      kind = "toggle",
      group = "Compiler Flags",
      name = flag,
      is_selected = compiler_flags[flag],
    })
  end

  return options
end

-- Set language option
M.set_language_option = function(option_data, value)
  if option_data.kind == "radio" then
    cpp_standard = value
  elseif option_data.kind == "toggle" then
    compiler_flags[value] = not compiler_flags[value]
  end
end

-- Get categories
M.get_categories = function()
  local configured_checks = get_all_configured_checks()
  local opts = require("diagnostic-picker.config").get()

  local categories = {
    { name = "modernize-*",          desc = "Modern C++",        expandable = true },
    { name = "readability-*",        desc = "Readability",       expandable = true },
    { name = "performance-*",        desc = "Performance",       expandable = true },
    { name = "bugprone-*",           desc = "Bug-prone",         expandable = true },
    { name = "cppcoreguidelines-*",  desc = "Core Guidelines",   expandable = true },
    { name = "clang-analyzer-*",     desc = "Static analyzer",   expandable = true },
    { name = "misc-*",               desc = "Miscellaneous",     expandable = true },
    { name = "cert-*",               desc = "CERT",              expandable = true },
    { name = "google-*",             desc = "Google style",      expandable = true },
    { name = "hicpp-*",              desc = "High Integrity C++", expandable = true },
    { name = "portability-*",        desc = "Portability",       expandable = true },
    { name = "concurrency-*",        desc = "Concurrency",       expandable = true },
    { name = "llvm-*",               desc = "LLVM",              expandable = true },
    { name = "abseil-*",             desc = "Abseil",            expandable = true },
    { name = "boost-*",              desc = "Boost",             expandable = true },
    { name = "android-*",            desc = "Android",           expandable = true },
    { name = "fuchsia-*",            desc = "Fuchsia",           expandable = true },
    { name = "linuxkernel-*",        desc = "Linux Kernel",      expandable = true },
    { name = "mpi-*",                desc = "MPI",               expandable = true },
    { name = "openmp-*",             desc = "OpenMP",            expandable = true },
    { name = "zircon-*",             desc = "Zircon",            expandable = true },
  }

  local available = get_available_categories()

  for _, cat in ipairs(categories) do
    -- Mark unavailable categories
    cat.not_installed = not available[cat.name]
    -- Skip config source check for unavailable categories
    if not cat.not_installed then
      local config_source = ""
      for check_pattern, check_info in pairs(configured_checks) do
        if check_pattern == cat.name then
          local icon = check_info.source:match("config.yaml") and opts.icons.global_config or opts.icons.local_config
          config_source = " " .. icon
          break
        end
      end
      cat.config_source = config_source
    end
  end

  return categories
end

-- Expand category to individual checks
M.expand_category = function(category)
  local handle = io.popen("clang-tidy --list-checks -checks='" .. category .. "' 2>/dev/null")
  if not handle then return {} end

  local checks = {}
  local configured = get_all_configured_checks()
  local opts = require("diagnostic-picker.config").get()

  for line in handle:lines() do
    local check = line:match("^%s*(" .. category:gsub("%*", "[^%s]+") .. ")%s*$")
    if check then
      -- Determine config source for this check
      local check_source = ""
      if configured[check] then
        local info = configured[check]
        if info.source:match("config.yaml") then
          check_source = " " .. opts.icons.global_config
        elseif info.source:match(".clangd") then
          check_source = " " .. opts.icons.local_config
        end
        if info.type == "remove" then
          check_source = check_source .. opts.icons.disabled
        end
      end

      table.insert(checks, {
        name = check,
        config_source = check_source,
      })
    end
  end
  handle:close()
  return checks
end

-- Apply configuration
M.apply_config = function(state)
  local ft = vim.bo.filetype
  local clangd_path = vim.fn.getcwd() .. "/.clangd"

  -- Build list of disabled checks
  local remove_checks = {}
  if state[ft] then
    for check, enabled in pairs(state[ft]) do
      if not enabled and type(check) == "string" then
        table.insert(remove_checks, check)
      end
    end
  end
  table.sort(remove_checks)

  -- Get current configs to preserve enabled checks from global config
  local enabled_from_global = {}
  for check, info in pairs(get_all_configured_checks()) do
    if info.enabled and info.source:match("config.yaml") then
      table.insert(enabled_from_global, check)
    end
  end

  -- Build new config content
  local config_lines = {}
  table.insert(config_lines, "# Local clangd overrides")
  table.insert(config_lines, "# Generated by diagnostic-picker.nvim")
  table.insert(config_lines, "# This file overrides settings from ~/.config/clangd/config.yaml")
  table.insert(config_lines, "")

  -- CompileFlags section (C++ standard + boolean flags)
  table.insert(config_lines, "CompileFlags:")
  table.insert(config_lines, "  Add:")
  table.insert(config_lines, '    - "-std=' .. cpp_standard .. '"')
  for flag, enabled in pairs(compiler_flags) do
    if enabled then
      table.insert(config_lines, '    - "' .. flag .. '"')
    end
  end
  table.insert(config_lines, "")

  -- Diagnostics section
  table.insert(config_lines, "Diagnostics:")
  table.insert(config_lines, "  ClangTidy:")

  -- Add section (preserves global config)
  if #enabled_from_global > 0 then
    table.insert(config_lines, "    Add:")
    for _, check in ipairs(enabled_from_global) do
      table.insert(config_lines, "      - " .. check)
    end
  end

  -- Remove section (runtime toggles)
  if #remove_checks > 0 then
    table.insert(config_lines, "    Remove:")
    for _, check in ipairs(remove_checks) do
      table.insert(config_lines, "      - " .. check)
    end
  else
    table.insert(config_lines, "    Remove: []")
  end

  -- Write config
  local has_existing = vim.fn.filereadable(clangd_path) == 1
  local file = io.open(clangd_path, "w")
  if file then
    for _, line in ipairs(config_lines) do
      file:write(line .. "\n")
    end
    file:close()

    local action = has_existing and "Updated" or "Created"
    local message = action .. " " .. clangd_path .. "\n" ..
                    "C++ standard: " .. cpp_standard .. "\n" ..
                    "Disabled checks: " .. #remove_checks

    -- Automatically restart clangd
    vim.schedule(function()
      local clients = vim.lsp.get_clients({ name = "clangd" })
      for _, client in ipairs(clients) do
        vim.lsp.stop_client(client.id, true)
      end
      -- Brief delay then restart by re-triggering filetype detection
      vim.defer_fn(function()
        if vim.fn.exists(":LspStart") == 2 then
          vim.cmd("LspStart clangd")
        else
          vim.cmd("edit")
        end
      end, 500)
    end)

    return {
      success = true,
      message = message
    }
  else
    return {
      success = false,
      message = "Error: Could not write to " .. clangd_path
    }
  end
end

-- Restart LSP
M.restart_lsp = function()
  local clients = vim.lsp.get_clients({ name = "clangd" })
  for _, client in ipairs(clients) do
    vim.lsp.stop_client(client.id, true)
  end
  vim.defer_fn(function()
    if vim.fn.exists(":LspStart") == 2 then
      vim.cmd("LspStart clangd")
    else
      vim.cmd("edit")
    end
  end, 500)
end

return M
