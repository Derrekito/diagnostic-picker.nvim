-- Tests for Provider:apply_config() — the generic lsp_settings implementation.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local captured_settings

local function make_provider(sections)
  package.loaded["diagnostic-picker.provider_base"] = nil
  local Provider = require("diagnostic-picker.provider_base")
  local p = Provider.new({
    provider  = "test",
    lsp_name  = "test_ls",
    filetypes = { "test" },
    sections  = sections,
  })
  -- Stub apply_lsp_settings on the instance to capture output
  p.apply_lsp_settings = function(self, settings, bufnr)
    captured_settings = settings
    return { success = true, message = "ok" }
  end
  return p
end

describe("Provider:apply_config generic lsp_settings", function()
  before_each(function()
    captured_settings = nil
  end)

  it("builds flat toggle settings from lsp_settings section", function()
    local p = make_provider({
      {
        id = "plugins", kind = "toggle", apply_to = "lsp_settings",
        settings_path = "pylsp.plugins",
        items = {
          { name = "pyflakes",    default = true  },
          { name = "pycodestyle", default = true  },
          { name = "pylint",      default = false },
        }
      }
    })

    local state = { [1] = { pyflakes = true, pycodestyle = false, pylint = false } }
    p:apply_config(state, 1)

    assert.is_not_nil(captured_settings)
    assert.is_true(captured_settings.pylsp.plugins.pyflakes)
    assert.is_false(captured_settings.pylsp.plugins.pycodestyle)
    assert.is_false(captured_settings.pylsp.plugins.pylint)
  end)

  it("uses JSON default when item not in state", function()
    local p = make_provider({
      {
        id = "diag", kind = "toggle", apply_to = "lsp_settings",
        settings_path = "Lua.diagnostics",
        items = {
          { name = "enable", default = true },
        }
      }
    })

    local state = { [1] = {} }  -- no overrides
    p:apply_config(state, 1)

    assert.is_true(captured_settings.Lua.diagnostics.enable)
  end)

  it("sets radio value at settings_path key", function()
    local p = make_provider({
      {
        id = "severity", kind = "radio", apply_to = "lsp_settings",
        settings_path = "Lua.diagnostics.severity",
        items = {
          { name = "Error"   },
          { name = "Warning", default = true },
          { name = "Hint"    },
        }
      }
    })

    local state = { [1] = {} }  -- use default
    p:apply_config(state, 1)

    assert.equals("Warning", captured_settings.Lua.diagnostics.severity)
  end)

  it("respects radio selection stored in state", function()
    local p = make_provider({
      {
        id = "severity", kind = "radio", apply_to = "lsp_settings",
        settings_path = "Lua.diagnostics.severity",
        items = {
          { name = "Error"   },
          { name = "Warning", default = true },
          { name = "Hint"    },
        }
      }
    })

    local state = { [1] = { __severity = "Hint" } }
    p:apply_config(state, 1)

    assert.equals("Hint", captured_settings.Lua.diagnostics.severity)
  end)

  it("falls back to empty state when bufnr not in state", function()
    local p = make_provider({
      {
        id = "diag", kind = "toggle", apply_to = "lsp_settings",
        settings_path = "foo.bar",
        items = { { name = "baz", default = true } }
      }
    })

    local state = {}  -- no bufnr key
    p:apply_config(state, 99)

    assert.is_true(captured_settings.foo.bar.baz)
  end)
end)
