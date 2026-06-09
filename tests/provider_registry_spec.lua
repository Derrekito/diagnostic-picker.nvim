-- Tests for the provider registry: loading, filetype lookup, fallback.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function fresh_registry()
  package.loaded["diagnostic-picker.config"] = nil
  require("diagnostic-picker.config").setup({})
  local reg = reload("diagnostic-picker.provider")
  reg.load_providers()
  return reg
end

describe("provider registry", function()
  it("returns a provider for cpp", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("cpp")
    assert.is_not_nil(p)
  end)

  it("returns a provider for c", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("c")
    assert.is_not_nil(p)
  end)

  it("returns the same provider object for all clangd filetypes", function()
    local reg = fresh_registry()
    local pc  = reg.get_for_filetype("c")
    local pcpp = reg.get_for_filetype("cpp")
    -- Same underlying provider (same sections table)
    assert.equals(pc.sections, pcpp.sections)
  end)

  it("returns nil for unknown filetype", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("cobol")
    assert.is_nil(p)
  end)

  it("clangd provider has compile_flags toggle section", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("cpp")
    local found = false
    for _, s in ipairs(p.sections) do
      if s.kind == "toggle" and s.apply_to == "compile_flags" then
        found = true
        break
      end
    end
    assert.is_true(found, "clangd provider must have a compile_flags toggle section")
  end)

  it("clangd provider has expandable category section", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("cpp")
    local found = false
    for _, s in ipairs(p.sections) do
      if s.kind == "category" and s.expandable then
        found = true
        break
      end
    end
    assert.is_true(found, "clangd provider must have an expandable category section")
  end)

  it("clangd provider get_language_options returns -Wall", function()
    local reg = fresh_registry()
    local p = reg.get_for_filetype("cpp")
    -- init state so _item_is_selected has something to read
    package.loaded["diagnostic-picker.state"] = nil
    local s = require("diagnostic-picker.state")
    s.init_ft_state("cpp", p)
    local opts = p:get_language_options("cpp")
    local names = {}
    for _, o in ipairs(opts) do names[o.name] = true end
    assert.is_true(names["-Wall"], "-Wall must appear in language options")
    assert.is_true(names["-Wextra"], "-Wextra must appear in language options")
  end)
end)
