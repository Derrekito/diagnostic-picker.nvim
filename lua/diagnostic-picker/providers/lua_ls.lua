-- lua-language-server provider
-- Pushes Lua.diagnostics.disable (array of suppressed check names) and
-- Lua.diagnostics.severity (selected level) via didChangeConfiguration.

local Provider = require("diagnostic-picker.provider_base")

local LuaLsProvider = setmetatable({}, { __index = Provider })
LuaLsProvider.__index = LuaLsProvider

function LuaLsProvider.new(config)
  return setmetatable(Provider.new(config), LuaLsProvider)
end

function LuaLsProvider:apply_config(current_state, bufnr)
  local buf_state = (bufnr and current_state[bufnr]) or {}
  local disable = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      local val = buf_state[section.id]
      if val == nil then val = section.default ~= false end
      if not val then
        table.insert(disable, section.id)
      end
    end
  end
  table.sort(disable)
  return self:apply_lsp_settings({ Lua = { diagnostics = { disable = disable } } }, bufnr)
end

function LuaLsProvider:is_installed()
  return vim.fn.executable("lua-language-server") == 1
end

return LuaLsProvider
