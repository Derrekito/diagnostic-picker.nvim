-- bash-language-server provider
-- Builds shellcheckArguments string (--exclude=SC...,SC...) from disabled checks.

local Provider = require("diagnostic-picker.provider_base")

local BashLsProvider = setmetatable({}, { __index = Provider })
BashLsProvider.__index = BashLsProvider

function BashLsProvider.new(config)
  return setmetatable(Provider.new(config), BashLsProvider)
end

function BashLsProvider:apply_config(current_state, bufnr)
  local buf_state = (bufnr and current_state[bufnr]) or {}
  local excluded = {}

  for _, section in ipairs(self.sections) do
    if section.kind == "toggle" and section.apply_to == "lsp_settings" then
      for _, name in ipairs(self:collect_disabled(buf_state, section.id)) do
        table.insert(excluded, name)
      end
    end
  end

  table.sort(excluded)

  local args = #excluded > 0 and ("--exclude=" .. table.concat(excluded, ",")) or ""
  return self:apply_lsp_settings({ bashIde = { shellcheckArguments = args } }, bufnr)
end

function BashLsProvider:is_installed()
  return vim.fn.executable("bash-language-server") == 1
end

return BashLsProvider
