-- Tests for state.lua: init, toggle, is_enabled.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function make_provider()
  package.loaded["diagnostic-picker.config"] = nil
  require("diagnostic-picker.config").setup({})
  package.loaded["diagnostic-picker.provider"] = nil
  local reg = require("diagnostic-picker.provider")
  reg.load_providers()
  return reg.get_for_filetype("cpp")
end

describe("state.init_ft_state", function()
  it("initializes compile flag toggles from JSON defaults", function()
    local s = reload("diagnostic-picker.state")
    local p = make_provider()
    s.init_ft_state("cpp", p)
    -- JSON defaults all true
    assert.is_true(s.state["cpp"]["-Wall"])
    assert.is_true(s.state["cpp"]["-Wshadow"])
  end)

  it("initializes category items from JSON defaults", function()
    local s = reload("diagnostic-picker.state")
    local p = make_provider()
    s.init_ft_state("cpp", p)
    assert.is_true(s.state["cpp"]["modernize-*"])
    assert.is_true(s.state["cpp"]["bugprone-*"])
  end)

  it("is a no-op when called a second time", function()
    local s = reload("diagnostic-picker.state")
    local p = make_provider()
    s.init_ft_state("cpp", p)
    s.state["cpp"]["-Wall"] = false  -- mutate
    s.init_ft_state("cpp", p)       -- should not reset
    assert.is_false(s.state["cpp"]["-Wall"], "second init must not overwrite existing state")
  end)
end)

describe("state toggles", function()
  it("toggle_category flips enabled state", function()
    local s = reload("diagnostic-picker.state")
    s.state["cpp"] = { ["modernize-*"] = true }
    s.toggle_category("cpp", "modernize-*")
    assert.is_false(s.state["cpp"]["modernize-*"])
    s.toggle_category("cpp", "modernize-*")
    assert.is_true(s.state["cpp"]["modernize-*"])
  end)

  it("toggle_category treats nil as true", function()
    local s = reload("diagnostic-picker.state")
    s.state["cpp"] = {}
    s.toggle_category("cpp", "missing")
    assert.is_false(s.state["cpp"]["missing"], "nil → treated as true → toggled to false")
  end)

  it("toggle_check flips individual check state", function()
    local s = reload("diagnostic-picker.state")
    s.state["cpp"] = { ["modernize-use-auto"] = true }
    s.toggle_check("cpp", "modernize-use-auto")
    assert.is_false(s.state["cpp"]["modernize-use-auto"])
  end)

  it("is_enabled returns true for nil (default)", function()
    local s = reload("diagnostic-picker.state")
    s.state["cpp"] = {}
    assert.is_true(s.is_enabled("cpp", "anything"))
  end)

  it("is_enabled returns true when no ft state exists", function()
    local s = reload("diagnostic-picker.state")
    assert.is_true(s.is_enabled("noft", "anything"))
  end)

  it("toggle_severity flips severity", function()
    local s = reload("diagnostic-picker.state")
    s.init_severities()
    local initial = s.state.severities.ERROR
    s.toggle_severity("ERROR")
    assert.not_equal(initial, s.state.severities.ERROR)
    s.toggle_severity("ERROR")
    assert.equals(initial, s.state.severities.ERROR)
  end)
end)
