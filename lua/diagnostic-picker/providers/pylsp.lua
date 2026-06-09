-- Pylsp provider (Python)
-- Subclasses Provider; applies config via LSP workspace/didChangeConfiguration.

local Provider = require("diagnostic-picker.provider_base")

local PylspProvider = setmetatable({}, { __index = Provider })
PylspProvider.__index = PylspProvider

function PylspProvider.new(config)
  local self = Provider.new(config)
  return setmetatable(self, PylspProvider)
end

function PylspProvider:get_categories()
  local categories = {}
  for _, section in ipairs(self.sections) do
    if section.kind == "category" then
      for _, item in ipairs(section.items or {}) do
        table.insert(categories, vim.tbl_extend("keep", {}, item))
      end
    end
  end
  return categories
end

function PylspProvider:apply_config(current_state)
  local ft_state = current_state["python"] or {}
  local plugins  = {}

  for _, section in ipairs(self.sections) do
    if section.apply_to == "lsp_settings" and section.kind == "toggle" then
      for _, item in ipairs(section.items or {}) do
        local enabled = ft_state[item.name]
        if enabled == nil then enabled = item.default ~= false end
        plugins[item.name] = { enabled = enabled }
      end
    end
  end

  return self:apply_lsp_settings({ pylsp = { plugins = plugins } })
end

function PylspProvider:is_installed()
  return vim.fn.executable("pylsp") == 1
end

return PylspProvider
