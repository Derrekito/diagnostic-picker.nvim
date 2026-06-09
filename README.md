# diagnostic-picker.nvim

A language-agnostic Neovim plugin for managing LSP diagnostic settings with a beautiful Telescope picker interface.

## Features

- 🎯 **Toggle diagnostic severity levels** (ERROR, WARN, INFO, HINT)
- 🔧 **Language-specific linter control** via provider system
- 📝 **Config file management** (reads and writes language-specific configs)
- 🎨 **Visual indicators** showing config sources
- ⚡ **Auto-restart LSP** when settings change
- 🔌 **Extensible** - Easy to add new language providers

## Currently Supported Languages

### C/C++ (clangd)
- Toggle clang-tidy check categories
- Expand categories to see individual checks
- Select C++ standard (c++98 through c++26)
- Merges global (`~/.config/clangd/config.yaml`) and local (`.clangd`) configs
- Runtime overrides written to local `.clangd`

### Coming Soon
- Python (pylsp)
- Rust (rust-analyzer)
- Lua (lua_ls)
- Shell (shellcheck)

## Installation

### lazy.nvim

```lua
{
  "yourusername/diagnostic-picker.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("diagnostic-picker").setup({
      -- Optional config
    })
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
    require("diagnostic-picker").setup()
  end
}
```

## Usage

1. Open a file with LSP diagnostics
2. Invoke the picker (e.g., `<leader>dg`)
3. Navigate with `j`/`k`, toggle with `Space`, expand with `Tab`
4. Press `Enter` to apply changes
5. LSP automatically restarts

## Controls

- **Space** - Toggle item on/off
- **Tab** - Expand/collapse categories (shows individual checks)
- **Enter** - Apply changes and update config files
- **Esc** - Cancel without changes

## Architecture

The plugin uses a provider-based architecture for language-agnostic support:

```
lua/diagnostic-picker/
├── init.lua              # Core picker logic
├── config.lua            # Plugin configuration
├── provider.lua          # Provider interface
└── providers/
    ├── clangd.lua        # C/C++ support
    ├── pylsp.lua         # Python support
    └── ...
```

Each provider implements a standard interface for:
- Getting available diagnostic categories
- Reading current config state
- Writing config updates
- Restarting the LSP

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for details on:
- Provider interface specification
- Adding new language support
- Testing and debugging
- Contributing guidelines

## License

MIT
