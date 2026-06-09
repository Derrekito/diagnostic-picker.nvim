-- Tests for the bash-ls provider: shellcheckArguments string building.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function make_bash_ls_provider()
  package.loaded["diagnostic-picker.config"] = nil
  require("diagnostic-picker.config").setup({})
  local reg = reload("diagnostic-picker.provider")
  reg.load_providers()
  return reg.get_for_filetype("sh")
end

describe("bash-ls provider", function()
  it("is registered for sh filetype", function()
    local p = make_bash_ls_provider()
    assert.is_not_nil(p)
  end)

  it("apply_config builds --exclude string from disabled checks", function()
    local p = make_bash_ls_provider()
    local captured

    p.apply_lsp_settings = function(self, settings, bufnr)
      captured = settings
      return { success = true, message = "ok" }
    end

    local buf_state = { SC2034 = false, SC2086 = false, SC2046 = true }
    p:apply_config({ [1] = buf_state }, 1)

    assert.is_not_nil(captured)
    local args = captured.bashIde.shellcheckArguments
    assert.is_not_nil(args)
    assert.is_truthy(args:match("SC2034"), "SC2034 should be excluded")
    assert.is_truthy(args:match("SC2086"), "SC2086 should be excluded")
    assert.is_falsy(args:match("SC2046"), "SC2046 should not be excluded (enabled)")
  end)

  it("apply_config sends empty string when all items explicitly enabled", function()
    local p = make_bash_ls_provider()
    local captured

    p.apply_lsp_settings = function(self, settings, bufnr)
      captured = settings
      return { success = true, message = "ok" }
    end

    -- Explicitly enable everything including SC1091 which defaults false
    local buf_state = {
      SC2034 = true, SC2046 = true, SC2086 = true,
      SC2155 = true, SC1091 = true, SC2164 = true, SC2206 = true,
    }
    p:apply_config({ [1] = buf_state }, 1)

    assert.equals("", captured.bashIde.shellcheckArguments)
  end)
end)
