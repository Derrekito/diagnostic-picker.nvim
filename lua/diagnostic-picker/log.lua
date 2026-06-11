-- Structured logging / diagnostics for diagnostic-picker.
--
-- Levels: trace < debug < info < warn < error.
--   * trace/debug/info  -> written to the debug_file only when config.debug is on.
--   * warn/error        -> written to the debug_file (if debug on) AND surfaced to
--                          the user via vim.notify, regardless of debug, so failure
--                          modes are never silent.
--
-- Also provides report_config_source(), the on-demand diagnostic that answers
-- "is the picker reading a .clangd file or falling back to JSON defaults, and from
-- where?" — wired to the :DiagnosticPickerDebug command.

local M = {}

local config = require("diagnostic-picker.config")

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }

local function write_file(line)
  local opts = config.get()
  local path = opts.debug_file
  if not path then return end
  local f = io.open(path, "a")
  if f then
    f:write(os.date("%H:%M:%S ") .. line .. "\n")
    f:close()
  end
end

local function fmt(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
  end
  return table.concat(parts, " ")
end

local function emit(level, ...)
  local opts = config.get()
  local msg = fmt(...)
  local lvl = LEVELS[level] or LEVELS.info

  -- File logging only when debug is enabled.
  if opts.debug then
    write_file(string.format("[%-5s] %s", level:upper(), msg))
  end

  -- warn/error always surface to the user.
  if lvl >= LEVELS.warn then
    local vlevel = level == "error" and vim.log.levels.ERROR or vim.log.levels.WARN
    vim.notify("[diagnostic-picker] " .. msg, vlevel)
  end
end

function M.trace(...) emit("trace", ...) end
function M.debug(...) emit("debug", ...) end
function M.info(...)  emit("info", ...) end
function M.warn(...)  emit("warn", ...) end
function M.error(...) emit("error", ...) end

-- Build a human-readable report of where the picker's state comes from for the
-- given buffer: resolved project root, which config files exist, and per-category
-- whether the value came from a file (Add/Remove) or a JSON default.
-- Returns the report as a list of lines (also logs it at info level).
function M.report_config_source(provider, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = { "=== diagnostic-picker config source report ===" }

  if not provider then
    lines[#lines + 1] = "No provider for this buffer's filetype: " .. tostring(vim.bo[bufnr].filetype)
    return lines
  end

  -- Resolve root + config files via the provider's own helper if exposed,
  -- otherwise replicate the marker search the clangd provider uses.
  local fname = vim.api.nvim_buf_get_name(bufnr)
  local root
  if provider.get_project_root then
    root = provider:get_project_root(bufnr)
  else
    local found = fname ~= "" and vim.fs.find(
      { "compile_commands.json", ".clangd", "compile_flags.txt", ".git" },
      { path = vim.fs.dirname(fname), upward = true }
    )[1]
    root = found and vim.fs.dirname(found) or vim.fn.getcwd()
  end

  local local_path  = root .. "/.clangd"
  local global_path = vim.fn.expand("~/.config/clangd/config.yaml")
  local has_local   = vim.fn.filereadable(local_path) == 1
  local has_global  = vim.fn.filereadable(global_path) == 1

  lines[#lines + 1] = "buffer file : " .. (fname ~= "" and fname or "(no file)")
  lines[#lines + 1] = "project root: " .. root
  lines[#lines + 1] = string.format("local  .clangd          : %s  [%s]", local_path, has_local and "FOUND" or "missing")
  lines[#lines + 1] = string.format("global config.yaml      : %s  [%s]", global_path, has_global and "FOUND" or "missing")

  if not has_local and not has_global then
    lines[#lines + 1] = ">> No config file found — picker is showing JSON DEFAULTS, not file state."
  else
    lines[#lines + 1] = ">> Reading state from the config file(s) above."
  end

  -- Per-category: file vs default. Uses get_configured_checks if the provider
  -- exposes it; otherwise just reports the live state value.
  local configured = provider.get_configured_checks and provider:get_configured_checks(root) or nil
  local state = require("diagnostic-picker.state")
  lines[#lines + 1] = "--- categories ---"
  for _, section in ipairs(provider.sections or {}) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        local name = item.name
        local live = state.is_enabled(bufnr, name)
        local src
        if configured and configured[name] then
          src = "file(" .. (configured[name].enabled and "Add" or "Remove") .. ")"
        else
          src = "default(" .. tostring(item.default ~= false) .. ")"
        end
        lines[#lines + 1] = string.format("  %-28s %s  source=%s", name, live and "[on] " or "[off]", src)
      end
    end
  end

  M.info(table.concat(lines, "\n"))
  return lines
end

return M
