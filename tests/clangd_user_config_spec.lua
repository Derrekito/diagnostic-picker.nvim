-- Tests for .clangd-user.yaml merging: user settings are folded into the
-- single generated YAML document (no '---' separators, ever), hand-written
-- .clangd files are migrated, and reimport_user_config re-merges without
-- picker state.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function make_provider()
  reload("diagnostic-picker.config")
  require("diagnostic-picker.config").setup({})
  reload("diagnostic-picker.provider")
  local reg = require("diagnostic-picker.provider")
  reg.load_providers()
  local p = reg.get_for_filetype("cpp")
  -- Don't actually bounce clangd in headless tests
  p.restart_lsp = function() end
  return p
end

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function make_tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function with_cwd(dir, fn)
  local orig = vim.fn.getcwd
  vim.fn.getcwd = function() return dir end
  local ok, err = pcall(fn)
  vim.fn.getcwd = orig
  assert(ok, err)
end

local function make_buf()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "cpp"
  return bufnr
end

local function apply(dir, provider, bufnr)
  with_cwd(dir, function()
    assert.is_true(provider:apply_config({ [bufnr] = {} }, bufnr).success)
  end)
end

local function assert_no_doc_separator(content)
  assert.is_falsy(content:match("\n%-%-%-"), "no '---' document separator anywhere")
  assert.is_falsy(content:match("^%-%-%-"), "no leading '---'")
end

describe("clangd user-config merge", function()
  it("writes a single document with no '---' when no user file exists", function()
    local dir = make_tmpdir()
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert.is_not_nil(content)
    assert.is_truthy(content:match("diagnostic%-picker"), "generated header present")
    assert.is_truthy(content:match("%-std=c%+%+17"), "default std written")
    assert_no_doc_separator(content)
  end)

  it("merges user CompileFlags.Add into the managed Add list", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml",
      'CompileFlags:\n  Add:\n    - "-I/opt/include"\n    - "-DFOO=1"\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert_no_doc_separator(content)
    local _, cf_count = content:gsub("CompileFlags:", "")
    assert.equals(1, cf_count, "exactly one CompileFlags section")
    assert.is_truthy(content:find('- "-I/opt/include"', 1, true), "user include flag merged")
    assert.is_truthy(content:find('- "-DFOO=1"', 1, true), "user define merged")
  end)

  it("ignores '---' lines in the user file", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml",
      '---\nCompileFlags:\n  Add:\n    - "-Iinclude"\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert_no_doc_separator(content)
    assert.is_truthy(content:find('- "-Iinclude"', 1, true), "user flag merged")
  end)

  it("carries unmanaged top-level sections over verbatim", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml",
      'CompileFlags:\n  Add:\n    - "-Iinclude"\nInlayHints:\n  Enabled: true\nIndex:\n  Background: Skip\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert_no_doc_separator(content)
    assert.is_truthy(content:match("InlayHints:\n  Enabled: true"), "InlayHints carried over")
    assert.is_truthy(content:match("Index:\n  Background: Skip"), "Index carried over")
  end)

  it("picker wins: user copies of managed flags and -std are filtered", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml",
      'CompileFlags:\n  Add:\n    - "-std=c++20"\n    - "-Wconversion"\n    - "-I/opt/include"\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert.is_falsy(content:find("c++20", 1, true), "user -std filtered (picker owns -std)")
    -- -Wconversion defaults off: appears exactly once, in the managed Remove list
    local _, wconv = content:gsub("%-Wconversion", "")
    assert.equals(1, wconv, "-Wconversion only in managed Remove, not re-added")
    assert.is_truthy(content:find('- "-I/opt/include"', 1, true), "unmanaged user flag kept")
  end)

  it("merges user ClangTidy entries and carries CheckOptions verbatim", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml", table.concat({
      "Diagnostics:",
      "  ClangTidy:",
      "    Add:",
      "      - cert-err34-c",
      "    CheckOptions:",
      "      readability-identifier-naming.VariableCase: camelBack",
      "",
    }, "\n"))
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local content = read_file(dir .. "/.clangd")
    assert_no_doc_separator(content)
    local _, diag_count = content:gsub("Diagnostics:", "")
    assert.equals(1, diag_count, "exactly one Diagnostics section")
    assert.is_truthy(content:match("Add:\n.*%- cert%-err34%-c"), "user tidy check in Add")
    assert.is_truthy(content:match("CheckOptions:"), "CheckOptions carried over")
    assert.is_truthy(content:match("VariableCase: camelBack"), "CheckOptions children intact")
  end)

  it("migrates a hand-written .clangd into .clangd-user.yaml", function()
    local dir = make_tmpdir()
    local hand = '# my hand config\nCompileFlags:\n  Add:\n    - "-I/usr/local/include"\n'
    write_file(dir .. "/.clangd", hand)
    local provider = make_provider()
    apply(dir, provider, make_buf())

    assert.equals(hand, read_file(dir .. "/.clangd-user.yaml"), "hand content preserved in user file")
    local content = read_file(dir .. "/.clangd")
    assert.is_truthy(content:match("diagnostic%-picker"), "regenerated")
    assert.is_truthy(content:find("-I/usr/local/include", 1, true), "hand flag merged back in")
    assert_no_doc_separator(content)
  end)

  it("does not migrate a previously generated .clangd", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd",
      "# Local clangd overrides — generated by diagnostic-picker.nvim\nCompileFlags:\n  Add:\n    - \"-std=c++20\"\n")
    local provider = make_provider()
    apply(dir, provider, make_buf())

    assert.is_nil(read_file(dir .. "/.clangd-user.yaml"), "no user file created from generated content")
  end)

  it("sync does not treat filtered user flags as picker state", function()
    local dir = make_tmpdir()
    -- user file force-adds a managed flag; the merge filters it out of the file
    write_file(dir .. "/.clangd-user.yaml", 'CompileFlags:\n  Add:\n    - "-Wconversion"\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    local state_mod = reload("diagnostic-picker.state")
    provider = make_provider()
    state_mod.init_ft_state("cpp", provider)

    local orig_expand = vim.fn.expand
    vim.fn.expand = function(p)
      if type(p) == "string" and p:match("clangd/config.yaml") then
        return dir .. "/no_global.yaml" -- nonexistent: isolate from real global
      end
      return orig_expand(p)
    end
    with_cwd(dir, function()
      provider:sync_state_from_files(state_mod.state["cpp"])
    end)
    vim.fn.expand = orig_expand

    local s = state_mod.state["cpp"]
    assert.is_true(s["-Wall"], "managed default flag synced")
    assert.is_false(s["-Wconversion"], "filtered user flag is not picker state")
  end)

  it("reimport_user_config re-merges an edited user file without state", function()
    local dir = make_tmpdir()
    write_file(dir .. "/.clangd-user.yaml", 'CompileFlags:\n  Add:\n    - "-Iold"\nInlayHints:\n  Enabled: true\n')
    local provider = make_provider()
    apply(dir, provider, make_buf())

    -- user edits the file by hand, then reimport runs (autocmd path)
    write_file(dir .. "/.clangd-user.yaml", 'CompileFlags:\n  Add:\n    - "-Inew"\nInlayHints:\n  Enabled: false\n')
    assert.is_true(provider:reimport_user_config(dir))

    local content = read_file(dir .. "/.clangd")
    assert_no_doc_separator(content)
    assert.is_truthy(content:match("%-std=c%+%+17"), "managed std intact")
    assert.is_truthy(content:find('- "-Inew"', 1, true), "new user flag merged")
    assert.is_falsy(content:find('- "-Iold"', 1, true), "deleted user flag gone")
    assert.is_truthy(content:match("Enabled: false"), "verbatim section updated")
    assert.is_falsy(content:match("Enabled: true"), "old verbatim content replaced")
  end)

  it("reimport_user_config refuses to touch a non-generated .clangd", function()
    local dir = make_tmpdir()
    local hand = "# hand written\nCompileFlags:\n  Add: [-DFOO]\n"
    write_file(dir .. "/.clangd", hand)
    write_file(dir .. "/.clangd-user.yaml", "InlayHints:\n  Enabled: true\n")

    local provider = make_provider()
    assert.is_false(provider:reimport_user_config(dir))
    assert.equals(hand, read_file(dir .. "/.clangd"), "hand-written file untouched")
  end)
end)
