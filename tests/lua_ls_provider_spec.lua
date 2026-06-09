-- Tests for the lua-ls provider: flat category sections, apply_config output shape.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function make_lua_ls_provider()
  package.loaded["diagnostic-picker.config"] = nil
  require("diagnostic-picker.config").setup({})
  local reg = reload("diagnostic-picker.provider")
  reg.load_providers()
  return reg.get_for_filetype("lua")
end

describe("lua-ls provider", function()
  it("is registered for lua filetype", function()
    local p = make_lua_ls_provider()
    assert.is_not_nil(p)
  end)

  it("has flat category sections for each check", function()
    local p = make_lua_ls_provider()
    local found = false
    for _, s in ipairs(p.sections) do
      if s.id == "undefined-global" and s.kind == "category" then found = true end
    end
    assert.is_true(found)
  end)

  it("apply_config sends Lua.diagnostics.disable array for disabled checks", function()
    local p = make_lua_ls_provider()
    local captured

    p.apply_lsp_settings = function(self, settings, bufnr)
      captured = settings
      return { success = true, message = "ok" }
    end

    local buf_state = { ["unused-local"] = false, ["spell-check"] = false }
    p:apply_config({ [1] = buf_state }, 1)

    assert.is_not_nil(captured)
    assert.is_not_nil(captured.Lua.diagnostics.disable)
    local set = {}
    for _, v in ipairs(captured.Lua.diagnostics.disable) do set[v] = true end
    assert.is_true(set["unused-local"])
    assert.is_true(set["spell-check"])
  end)

  it("apply_config does not include severity key", function()
    local p = make_lua_ls_provider()
    local captured

    p.apply_lsp_settings = function(self, settings, bufnr)
      captured = settings
      return { success = true, message = "ok" }
    end

    p:apply_config({ [1] = {} }, 1)

    assert.is_nil(captured.Lua.diagnostics.severity)
  end)

  it("apply_config includes checks that default false when not explicitly enabled", function()
    local p = make_lua_ls_provider()
    local captured

    p.apply_lsp_settings = function(self, settings, bufnr)
      captured = settings
      return { success = true, message = "ok" }
    end

    -- spell-check defaults false; not in buf_state means use default
    p:apply_config({ [1] = {} }, 1)

    local set = {}
    for _, v in ipairs(captured.Lua.diagnostics.disable) do set[v] = true end
    assert.is_true(set["spell-check"], "spell-check should be disabled by default")
    assert.is_nil(set["undefined-global"], "undefined-global should not be disabled by default")
  end)
end)
