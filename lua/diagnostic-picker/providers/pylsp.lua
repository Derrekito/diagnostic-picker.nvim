-- Pylsp provider (Python)
-- Subclasses Provider; applies config via LSP workspace/didChangeConfiguration.

local Provider = require("diagnostic-picker.provider_base")

local PylspProvider = setmetatable({}, { __index = Provider })
PylspProvider.__index = PylspProvider

function PylspProvider.new(config)
  local self = Provider.new(config)
  return setmetatable(self, PylspProvider)
end

function PylspProvider:get_categories(bufnr)
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

-- apply_config: push settings to pylsp via LSP.
-- current_state is the full state table (keyed by bufnr or ft string).
-- bufnr: the buffer that was active when the picker opened.
function PylspProvider:apply_config(current_state, bufnr)
  -- Prefer bufnr key; fall back to "python" ft string for backward compat
  local buf_state = (bufnr and current_state[bufnr]) or current_state["python"] or {}
  local plugins  = {}

  for _, section in ipairs(self.sections) do
    if section.apply_to == "lsp_settings" and section.kind == "toggle" then
      for _, item in ipairs(section.items or {}) do
        local enabled = buf_state[item.name]
        if enabled == nil then enabled = item.default ~= false end
        plugins[item.name] = { enabled = enabled }
      end
    end
  end

  return self:apply_lsp_settings({ pylsp = { plugins = plugins } }, bufnr)
end

function PylspProvider:is_installed()
  return vim.fn.executable("pylsp") == 1
end

return PylspProvider
