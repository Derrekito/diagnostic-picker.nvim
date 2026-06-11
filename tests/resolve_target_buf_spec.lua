-- Tests for provider.resolve_target_buf: picking the buffer the picker should
-- target when the focused window is a sidebar (nvim-tree, terminal, quickfix)
-- whose filetype has no provider.

local function reload(mod)
  package.loaded[mod] = nil
  return require(mod)
end

local function setup_registry()
  reload("diagnostic-picker.config")
  require("diagnostic-picker.config").setup({})
  local reg = reload("diagnostic-picker.provider")
  reg.load_providers()
  return reg
end

local function buf_with_ft(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = ft
  return buf
end

describe("provider.resolve_target_buf", function()
  before_each(function()
    vim.cmd("silent only")
  end)

  it("returns the current buffer when its filetype has a provider", function()
    local reg = setup_registry()
    local buf = buf_with_ft("cpp")
    vim.api.nvim_win_set_buf(0, buf)

    local rbuf, rft = reg.resolve_target_buf()
    assert.equals(buf, rbuf)
    assert.equals("cpp", rft)
  end)

  it("falls back to another window whose buffer has a provider", function()
    local reg = setup_registry()
    -- background window: real code buffer
    local code_buf = buf_with_ft("cpp")
    vim.api.nvim_win_set_buf(0, code_buf)
    -- focused window: sidebar-like buffer with no provider
    vim.cmd("vsplit")
    local tree_buf = buf_with_ft("NvimTree")
    vim.api.nvim_win_set_buf(0, tree_buf)
    assert.equals(tree_buf, vim.api.nvim_get_current_buf())

    local rbuf, rft = reg.resolve_target_buf()
    assert.equals(code_buf, rbuf, "should resolve to the code window's buffer")
    assert.equals("cpp", rft)
  end)

  it("returns the current buffer when no window has a provider filetype", function()
    local reg = setup_registry()
    local tree_buf = buf_with_ft("NvimTree")
    vim.api.nvim_win_set_buf(0, tree_buf)

    local rbuf, rft = reg.resolve_target_buf()
    assert.equals(tree_buf, rbuf)
    assert.equals("NvimTree", rft)
  end)
end)
