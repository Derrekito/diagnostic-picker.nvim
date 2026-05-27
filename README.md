# diagnostic-picker.nvim

A language-agnostic Neovim plugin for managing LSP diagnostic settings via a Telescope picker. Toggle severity levels, compiler flags, and linter categories without leaving your editor.

## Features

- Toggle diagnostic severity levels (ERROR, WARN, INFO, HINT)
- Language-specific sections: compiler flags, linter categories, LSP plugin toggles
- Expand clang-tidy categories to individual checks
- Filter/search across all items including collapsed categories
- Config files written automatically on apply; LSP restarted
- JSON-driven: add support for any language by dropping a config file

## Supported Languages

| Language       | Provider | Config written |
|----------------|----------|----------------|
| C/C++          | clangd   | `.clangd` (CompileFlags + ClangTidy) |
| Python         | pylsp    | LSP `workspace/didChangeConfiguration` |
| Lua            | lua-ls   | LSP `workspace/didChangeConfiguration` |
| Bash/Zsh       | bash-ls  | LSP `workspace/didChangeConfiguration` |
| MATLAB/Octave  | mh_lint  | `miss_hit.cfg` (MISS_HIT style/lint/metrics) |

## Installation

### lazy.nvim

```lua
{
  "Derrekito/diagnostic-picker.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("diagnostic-picker").setup()
  end,
  keys = {
    { "<leader>dg", function() require("diagnostic-picker").show() end, desc = "Diagnostic settings" }
  }
}
```

### Development (local path)

```lua
{
  dir = "~/Projects/diagnostic-picker.nvim",
  name = "diagnostic-picker",
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("diagnostic-picker").setup({
      debug = vim.env.DP_DEBUG == "1", -- launch as `DP_DEBUG=1 nvim` to log
    })
  end,
  keys = {
    { "<leader>dg", function() require("diagnostic-picker").show() end, desc = "Diagnostic settings" }
  }
}
```

## Usage

1. Open any file supported by an LSP
2. Press `<leader>dg` (or your mapped key)
3. Navigate with `j`/`k`
4. `Space` — toggle item on/off / select radio option
5. `Tab` — expand/collapse a category to show individual checks
6. Type to filter — collapsed categories are searched too
7. `Enter` — write config and restart LSP
8. `Esc` — close without changes

## Configuration

```lua
require("diagnostic-picker").setup({
  debug      = false,                              -- enable debug logging
  debug_file = "/tmp/diagnostic-picker-debug.log", -- log path

  -- Which severities are shown when the plugin first attaches.
  -- All off by default; the picker can toggle them per-buffer at runtime.
  severities = {
    ERROR = true,
    WARN  = true,
    INFO  = false,
    HINT  = false,
  },

  icons = {
    global_config = "🌍",  -- check comes from global config
    local_config  = "📁",  -- check comes from local config
    disabled      = "❌",  -- check is explicitly disabled
  },
})
```

## Adding a New Language

### Simple case — no custom logic needed

Drop a JSON file into `~/.config/nvim/diagnostic-picker/<name>.json`:

```json
{
  "provider": "my-ls",
  "lsp_name": "my_ls",
  "filetypes": ["myext"],
  "sections": [
    {
      "id": "checks",
      "title": "Checks",
      "kind": "toggle",
      "apply_to": "lsp_settings",
      "settings_path": "my_ls.diagnostics",
      "items": [
        { "name": "some-check", "desc": "Description", "default": true }
      ]
    }
  ]
}
```

The generic provider pushes all `lsp_settings` sections via
`workspace/didChangeConfiguration`. No Lua required.

### Complex case — custom apply logic

When the simple JSON-only approach isn't enough (e.g., the tool writes a
non-LSP config file like `.clangd`, or needs to shell out to enumerate
checks), a Lua provider subclass is required. Provider classes currently
must live inside the plugin at `lua/diagnostic-picker/providers/<name>.lua`
(hyphens in `provider` become underscores in the filename — see
`providers/clangd.lua` and `providers/pylsp.lua` for examples). The loader
does not yet pick up user-defined providers from `~/.config/nvim/`;
contributing a provider upstream is the supported path.

A minimal subclass looks like:

```lua
local Provider = require("diagnostic-picker.provider_base")

local MyProvider = setmetatable({}, { __index = Provider })
MyProvider.__index = MyProvider

function MyProvider.new(config)
  return setmetatable(Provider.new(config), MyProvider)
end

-- Write your tool's config file, restart LSP, etc.
function MyProvider:apply_config(current_state)
  -- current_state[ft]["item-name"] = true/false
  -- current_state[ft]["__section_id"] = "selected-radio-value"
  return { success = true, message = "Updated config" }
end

-- Optional: shell out to list sub-checks for expandable categories
function MyProvider:expand_category(category_name)
  return { { name = "my-check", config_source = "" } }
end

return MyProvider
```

### Section kinds

| `kind`      | Behaviour |
|-------------|-----------|
| `radio`     | One item selected at a time. State stored as `__<section_id>`. |
| `toggle`    | Each item independently on/off. |
| `category`  | Expandable rows; `expand_category()` provides sub-items. |

### `apply_to` values

| `apply_to`      | Effect |
|-----------------|--------|
| `compile_flags` | Written to `.clangd` CompileFlags (clangd only) |
| `clang_tidy`    | Written to `.clangd` Diagnostics.ClangTidy (clangd only) |
| `lsp_settings`  | Pushed via `workspace/didChangeConfiguration` |
| `cfg_file`      | Written to a tool-specific config file (e.g. `miss_hit.cfg`) |

## Architecture

```
diagnostic-picker.nvim/
├── configs/                      # Bundled JSON configs (one per language)
│   ├── clangd.json
│   ├── pylsp.json
│   ├── lua-ls.json
│   ├── bash-ls.json
│   └── mh-lint.json
└── lua/diagnostic-picker/
    ├── init.lua                  # Entry point: setup(), show(), apply_config()
    ├── config.lua                # Plugin options
    ├── dev.lua                   # Dev/debug helpers
    ├── state.lua                 # In-memory picker state
    ├── provider.lua              # Registry: loads JSON, instantiates providers
    ├── provider_base.lua         # Base Provider class
    ├── ui.lua                    # Telescope picker, keymaps, refresh logic
    └── providers/
        ├── init.lua              # Provider module index
        ├── bash_ls.lua           # BashLsProvider subclass
        ├── clangd.lua            # ClangdProvider subclass
        ├── lua_ls.lua            # LuaLsProvider subclass
        ├── mh_lint.lua           # MhLintProvider subclass
        └── pylsp.lua             # PylspProvider subclass
```

**JSON load order:** bundled `configs/` first, then
`~/.config/nvim/diagnostic-picker/`. User JSON files override bundled ones
for the same filetypes.

## License

MIT
