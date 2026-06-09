# Development Guide

## Quick Start

### Setup

1. **Symlink for development** (fastest iteration):
```bash
ln -s ~/Projects/diagnostic-picker.nvim ~/.local/share/nvim/site/pack/dev/start/diagnostic-picker.nvim
```

2. **Or use lazy.nvim local path**:
```lua
{
  dir = "~/Projects/diagnostic-picker.nvim",
  name = "diagnostic-picker",
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("diagnostic-picker").setup({ debug = true })
  end
}
```

### Rapid Iteration Workflow

**Terminal 1**: Watch debug logs
```bash
tail -f /tmp/diagnostic-picker-debug.log
```

**Terminal 2**: Neovim
```vim
" Edit plugin code
" Then reload:
:lua package.loaded["diagnostic-picker"] = nil
:lua package.loaded["diagnostic-picker.config"] = nil
:lua package.loaded["diagnostic-picker.providers.clangd"] = nil
:lua require("diagnostic-picker").show()

" Or use this helper (add to your config):
:lua require("diagnostic-picker.dev").reload()
```

### Debug Helpers

Add to your nvim config for development:
```lua
-- Pretty print
P = function(v)
  print(vim.inspect(v))
  return v
end

-- Quick reload
R = function()
  -- Unload all diagnostic-picker modules
  for k in pairs(package.loaded) do
    if k:match("^diagnostic%-picker") then
      package.loaded[k] = nil
    end
  end
  return require("diagnostic-picker")
end
```

## Provider Interface

Each language provider must implement:

```lua
local M = {}

-- Provider metadata
M.name = "clangd"
M.filetypes = { "c", "cpp" }
M.lsp_name = "clangd"

-- Get available diagnostic categories
-- Returns: array of { name, desc, expandable }
M.get_categories = function()
  return {
    { name = "modernize-*", desc = "Modern C++", expandable = true },
    { name = "readability-*", desc = "Readability", expandable = true },
    -- ...
  }
end

-- Get expanded checks for a category
-- Returns: array of check names
M.get_checks = function(category)
  return { "modernize-use-auto", "modernize-loop-convert", ... }
end

-- Get current config state
-- Returns: table with enabled/disabled state
M.get_config = function()
  return {
    checks = {
      ["modernize-*"] = true,
      ["readability-magic-numbers"] = false,
    },
    metadata = {
      sources = { global = "~/.config/clangd/config.yaml", local = ".clangd" },
      current_standard = "c++17",
    }
  }
end

-- Get language standards/versions (optional)
-- Returns: array of version strings
M.get_standards = function()
  return { "c++98", "c++11", "c++14", "c++17", "c++20", "c++23", "c++26" }
end

-- Apply config changes
-- state: table with enabled/disabled checks and selected standard
M.apply_config = function(state)
  -- Write config file(s)
  -- Restart LSP
  return {
    success = true,
    message = "Config updated, LSP restarted"
  }
end

-- Check if this provider's tool is installed
M.is_installed = function()
  return vim.fn.executable("clangd") == 1
end

return M
```

## Adding a New Language Provider

1. **Create provider file**: `lua/diagnostic-picker/providers/mylang.lua`

2. **Implement the interface** (see above)

3. **Register in init.lua**:
```lua
-- Providers are auto-discovered from providers/ directory
-- Or manually register:
require("diagnostic-picker").register_provider(require("diagnostic-picker.providers.mylang"))
```

4. **Test**:
```bash
nvim test_file.mylang
# Open diagnostic picker
# Verify categories appear
# Toggle some checks
# Apply and verify config file changes
```

## Testing

### Manual Testing

1. Create test files in `tests/fixtures/`:
```
tests/fixtures/
├── test.cpp          # C++ test with violations
├── test.py           # Python test
└── test.lua          # Lua test
```

2. Open each file and verify:
   - Categories load correctly
   - Toggles update state
   - Config files written correctly
   - LSP restarts with new settings
   - Diagnostics update appropriately

### Debug Logging

Enable debug mode in setup:
```lua
require("diagnostic-picker").setup({
  debug = true,
  debug_file = "/tmp/diagnostic-picker-debug.log"
})
```

Debug functions available:
```lua
local debug = require("diagnostic-picker.debug")
debug.print("message", variable)
debug.dump(table)
```

## Architecture Notes

### Core (init.lua)
- Language-agnostic picker logic
- Telescope integration
- State management
- Provider registry and dispatch

### Config (config.lua)
- Plugin configuration
- Default settings
- User setup() function

### Provider Interface (provider.lua)
- Interface definition
- Provider validation
- Helper functions for common operations

### Providers (providers/*.lua)
- Language-specific implementations
- Config file parsing/writing
- LSP integration

## Common Pitfalls

1. **Forgetting to reload modules**: Always clear `package.loaded` when testing changes

2. **LSP not restarting**: Some LSPs need `:LspRestart` with the specific name, not just `:LspRestart`

3. **Config file permissions**: Ensure plugin can write to project directory

4. **State persistence**: Remember that picker state persists across invocations (by design)

5. **Telescope refresh**: Closing and reopening the picker is intentional for UI refresh

## Performance

- Config parsing happens on-demand, not at startup
- Category expansion (listing individual checks) can be slow for some tools
- Consider caching expanded check lists if performance becomes an issue

## Contributing

1. Fork the repo
2. Create a feature branch
3. Add tests for new providers
4. Update documentation
5. Submit PR with clear description

For questions: [open an issue](https://github.com/yourusername/diagnostic-picker.nvim/issues)
