-- Tests for parse_clangd_config (the YAML parser in the clangd provider).
-- We access it by loading the module in a fresh environment.

local fixtures = vim.fn.getcwd() .. "/tests/fixtures"

-- Reload helper: wipe module cache so each test gets a fresh copy.
local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

-- Expose parse_clangd_config by temporarily monkey-patching io.open so we can
-- feed any path. Simpler: just use the real fixture files on disk.
describe("parse_clangd_config", function()
  -- We can't call the private function directly, so we drive it via
  -- sync_state_from_files with mocked paths. Instead, test the observable
  -- output of sync_state_from_files, which calls parse internally.

  local function make_provider()
    reload("diagnostic-picker.config")
    require("diagnostic-picker.config").setup({})
    reload("diagnostic-picker.provider")
    local reg = require("diagnostic-picker.provider")
    reg.load_providers()
    return reg.get_for_filetype("cpp")
  end

  it("parses block-list compile flags", function()
    local state_mod = reload("diagnostic-picker.state")
    local provider  = make_provider()
    assert.is_not_nil(provider)

    state_mod.init_ft_state("cpp", provider)
    -- Override paths to fixtures
    local orig_expand = vim.fn.expand
    local orig_getcwd = vim.fn.getcwd
    local orig_readable = vim.fn.filereadable

    vim.fn.expand = function(p)
      if p:match("clangd/config.yaml") then return fixtures .. "/global_config.yaml" end
      return orig_expand(p)
    end
    vim.fn.getcwd = function() return fixtures end
    vim.fn.filereadable = function(p)
      if p == fixtures .. "/global_config.yaml" then return 1 end
      if p == fixtures .. "/.clangd" then return 0 end
      return orig_readable(p)
    end

    provider:sync_state_from_files(state_mod.state["cpp"])

    vim.fn.expand     = orig_expand
    vim.fn.getcwd     = orig_getcwd
    vim.fn.filereadable = orig_readable

    local s = state_mod.state["cpp"]
    assert.is_true(s["-Wall"],     "-Wall should be enabled (in global)")
    assert.is_true(s["-Wextra"],   "-Wextra should be enabled (in global)")
    assert.is_true(s["-Wpedantic"],"-Wpedantic should be enabled (in global)")
    assert.is_false(s["-Wshadow"], "-Wshadow should be disabled (not in global)")
    assert.is_false(s["-Wlifetime"], "-Wlifetime should be disabled (not in global)")
  end)

  it("parses multi-line flow-sequence Add lists for clang-tidy categories", function()
    local state_mod = reload("diagnostic-picker.state")
    local provider  = make_provider()

    state_mod.init_ft_state("cpp", provider)

    local orig_expand   = vim.fn.expand
    local orig_getcwd   = vim.fn.getcwd
    local orig_readable = vim.fn.filereadable

    vim.fn.expand = function(p)
      if p:match("clangd/config.yaml") then return fixtures .. "/global_config.yaml" end
      return orig_expand(p)
    end
    vim.fn.getcwd   = function() return fixtures end
    vim.fn.filereadable = function(p)
      if p == fixtures .. "/global_config.yaml" then return 1 end
      if p == fixtures .. "/.clangd" then return 0 end
      return orig_readable(p)
    end

    provider:sync_state_from_files(state_mod.state["cpp"])

    vim.fn.expand       = orig_expand
    vim.fn.getcwd       = orig_getcwd
    vim.fn.filereadable = orig_readable

    local s = state_mod.state["cpp"]
    assert.is_true(s["modernize-*"],    "modernize-* in global Add → enabled")
    assert.is_true(s["readability-*"],  "readability-* in global Add → enabled")
    assert.is_true(s["bugprone-*"],     "bugprone-* in global Add → enabled")
    assert.is_false(s["performance-*"], "performance-* not in global → disabled")
    assert.is_false(s["google-*"],      "google-* not in global → disabled")
  end)

  it("local .clangd overrides global: std and remove", function()
    local state_mod = reload("diagnostic-picker.state")
    local provider  = make_provider()

    state_mod.init_ft_state("cpp", provider)

    local orig_expand   = vim.fn.expand
    local orig_getcwd   = vim.fn.getcwd
    local orig_readable = vim.fn.filereadable

    vim.fn.expand = function(p)
      if p:match("clangd/config.yaml") then return fixtures .. "/global_config.yaml" end
      return orig_expand(p)
    end
    vim.fn.getcwd = function() return fixtures end
    vim.fn.filereadable = function(p)
      if p == fixtures .. "/global_config.yaml" then return 1 end
      if p == fixtures .. "/.clangd"            then return 1 end
      return orig_readable(p)
    end

    -- Rename fixture so parse_clangd_config finds it as ".clangd"
    local local_src  = fixtures .. "/local_clangd"
    local local_dest = fixtures .. "/.clangd"
    os.rename(local_src, local_dest)

    provider:sync_state_from_files(state_mod.state["cpp"])

    os.rename(local_dest, local_src)
    vim.fn.expand       = orig_expand
    vim.fn.getcwd       = orig_getcwd
    vim.fn.filereadable = orig_readable

    local s = state_mod.state["cpp"]
    -- Local sets c++20, overriding global c++17
    assert.equals("c++20", s["__cpp_standard"], "local .clangd std wins")
    -- readability-* is in global Add but in local Remove → disabled
    assert.is_false(s["readability-*"], "readability-* removed by local .clangd")
    -- modernize-* only in global Add, not removed locally → still enabled
    assert.is_true(s["modernize-*"], "modernize-* from global survives")
  end)

  it("falls back to JSON defaults when no config files exist", function()
    local state_mod = reload("diagnostic-picker.state")
    local provider  = make_provider()

    local orig_readable = vim.fn.filereadable
    vim.fn.filereadable = function() return 0 end

    state_mod.init_ft_state("cpp", provider)
    provider:sync_state_from_files(state_mod.state["cpp"])

    vim.fn.filereadable = orig_readable

    -- JSON defaults are all false for clangd compile flags
    local s = state_mod.state["cpp"]
    assert.is_false(s["-Wall"],    "JSON default for -Wall is false")
    assert.is_false(s["-Wshadow"], "JSON default for -Wshadow is false")
  end)
end)
