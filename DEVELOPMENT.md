# Development Guide

## Setup

Use lazy.nvim with a local path:

```lua
{
  dir = "~/Projects/diagnostic-picker.nvim",
  name = "diagnostic-picker",
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("diagnostic-picker").setup({ debug = true })
  end,
  keys = {
    { "<leader>dg", function() require("diagnostic-picker").show() end, desc = "Diagnostic settings" }
  }
}
```

## Iteration Workflow

**Watch logs in a second terminal:**
```bash
tail -f /tmp/diagnostic-picker-debug.log
```

**Reload without restarting nvim:**
```vim
:lua for k in pairs(package.loaded) do if k:match("^diagnostic%-picker") then package.loaded[k] = nil end end
:lua require("diagnostic-picker").setup({ debug = true })
```

Or add a keybind:
```lua
vim.keymap.set("n", "<leader>DR", function()
  for k in pairs(package.loaded) do
    if k:match("^diagnostic%-picker") then package.loaded[k] = nil end
  end
  require("diagnostic-picker").setup({ debug = true })
  print("diagnostic-picker reloaded")
end)
```

## Architecture

### Data flow

```
JSON config file
    └─► provider.lua (registry)
            └─► Provider subclass instantiated
                    └─► ui.lua calls:
                            provider:get_language_options()  → radio/toggle sections
                            provider:get_categories()        → expandable category rows
                            provider:expand_category(name)   → sub-check list
                            provider:get_config_info()       → header string
                    └─► on Enter: provider:apply_config(state)
```

### State shape

`state.state` (from `state.lua`):

```lua
{
  severities = { ERROR=true, WARN=true, INFO=true, HINT=true },
  expanded   = { ["modernize-*"] = true },   -- which categories are open
  cpp = {                                     -- per-filetype key
    ["modernize-use-auto"]  = false,          -- individual check toggled off
    ["__cpp_standard"]      = "c++20",        -- radio selection (prefix __)
    ["-Wall"]               = true,           -- compiler flag toggle
  },
}
```

### JSON schema

```json
{
  "provider":  "name",          // matches providers/<name>.lua (hyphens → underscores)
  "lsp_name":  "lsp_client",   // vim.lsp.get_clients({ name = lsp_name })
  "filetypes": ["ext"],
  "sections": [
    {
      "id":         "section_id",
      "title":      "Display Title",
      "kind":       "radio | toggle | category",
      "apply_to":   "compile_flags | clang_tidy | lsp_settings",
      "expandable": true,           // category sections only
      "settings_path": "a.b.c",    // lsp_settings: dot-path into settings table
      "flag_prefix":   "-std=",    // radio compile_flags: prepended to item name
      "items": [
        { "name": "item-name", "desc": "Description", "default": true }
      ]
    }
  ]
}
```

### Provider class hierarchy

```
Provider (provider_base.lua)
├── ClangdProvider (providers/clangd.lua)   — writes .clangd, shells to clang-tidy
├── PylspProvider  (providers/pylsp.lua)    — pushes lsp_settings
└── <generic>      (provider.lua)           — pushes lsp_settings, no Lua file needed
```

**Methods subclasses can override:**

| Method | Default behaviour |
|--------|-------------------|
| `apply_config(state)` | raises error — must override |
| `expand_category(name)` | returns `{}` |
| `get_categories()` | returns items from `kind=category` sections |
| `get_language_options()` | returns items from radio/toggle sections |
| `get_config_info()` | returns `nil` |
| `is_installed()` | checks `vim.fn.executable(lsp_name)` |

## Picker key bindings

| Key | Action |
|-----|--------|
| `Space` | Toggle item |
| `Tab` | Expand/collapse category |
| `Enter` | Apply severity filter for this session (no file I/O) |
| `gs` | Save provider config to disk + restart LSP |

`save_config()` is also a public function users can bind externally:
```lua
vim.keymap.set("n", "<leader>dG", require("diagnostic-picker").save_config)
```

## Adding a New Language

### No custom logic (lsp_settings only)

1. Add `~/.config/nvim/diagnostic-picker/<name>.json`
2. Set `"apply_to": "lsp_settings"` on sections
3. Done — the generic provider handles the rest

### Custom apply logic

1. Add the JSON config (defines filetypes and UI structure)
2. Add `~/.config/nvim/diagnostic-picker/<name>.lua`:

```lua
local Provider = require("diagnostic-picker.provider_base")

local MyProvider = setmetatable({}, { __index = Provider })
MyProvider.__index = MyProvider

function MyProvider.new(config)
  return setmetatable(Provider.new(config), MyProvider)
end

function MyProvider:apply_config(current_state)
  local ft_state = current_state[self.filetypes[1]] or {}
  -- read ft_state["item-name"], ft_state["__section_id"], etc.
  -- write config file / push LSP settings
  self:restart_lsp()
  return { success = true, message = "Done" }
end

-- Only needed for expandable category sections
function MyProvider:expand_category(category_name)
  return { { name = "check-name", config_source = "" } }
end

return MyProvider
```

The registry matches `provider` field in JSON to `providers/<name>.lua`
(hyphens in the JSON name become underscores in the filename).

## Debugging

Enable in setup:
```lua
require("diagnostic-picker").setup({
  debug      = true,
  debug_file = "/tmp/diagnostic-picker-debug.log",
})
```

Log from your provider:
```lua
-- debug_print is local to ui.lua; in provider code use:
local f = io.open("/tmp/diagnostic-picker-debug.log", "a")
if f then f:write("my message\n"); f:close() end
```

## Common Pitfalls

- **Stale modules**: always clear `package.loaded` after editing Lua files
- **`self` is nil in methods**: provider methods must be called with `:` not `.`
- **Radio state key**: stored as `__<section_id>`, not the item name
- **`expand_category` is slow**: it shells out per-category; results are not cached across picker opens
- **User JSON overrides bundled**: same filetypes in user dir wins — useful for customisation, easy to shadow unintentionally
