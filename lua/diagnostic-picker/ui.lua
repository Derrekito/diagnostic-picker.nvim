-- UI and Telescope integration

local M = {}

local state = require("diagnostic-picker.state")
local config = require("diagnostic-picker.config")
local provider_registry = require("diagnostic-picker.provider")

-- Check for Telescope
local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  vim.notify("diagnostic-picker requires telescope.nvim", vim.log.levels.ERROR)
  return {}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

-- Debug logging
local function debug_print(...)
  local opts = config.get()
  if opts.debug then
    local msg = table.concat(vim.tbl_map(tostring, {...}), " ")
    local f = io.open(opts.debug_file, "a")
    if f then
      f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
      f:close()
    end
  end
end

-- Entry maker function
M.make_entry = function(entry, provider)
  if entry.type == "header" then
    return {
      value = entry,
      display = entry.display,
      ordinal = entry.display,
    }
  elseif entry.type == "severity" then
    local enabled = state.state.severities[entry.name]
    local prefix = enabled and "[✓] " or "[ ] "
    return {
      value = entry,
      display = prefix .. entry.name,
      ordinal = entry.name,
    }
  elseif entry.type == "language_option" then
    local is_selected = entry.provider_data and entry.provider_data.is_selected or false
    local kind = entry.provider_data and entry.provider_data.kind or "radio"
    local prefix
    if kind == "toggle" then
      prefix = is_selected and "[✓] " or "[ ] "
    else
      prefix = is_selected and "[•] " or "[ ] "
    end
    return {
      value = entry,
      display = prefix .. entry.name,
      ordinal = entry.name,
      hl_group = is_selected and "DiagnosticOk" or nil,
    }
  elseif entry.type == "category" then
    if entry.not_installed then
      local desc = entry.desc and (" - " .. entry.desc) or ""
      return {
        value = entry,
        display = "    " .. entry.name .. desc .. " (not available)",
        ordinal = entry.name,
        hl_group = "DiagnosticError",
      }
    end
    -- Derive enabled state from children when category is expandable.
    -- A category is "on" only if every child item is enabled.
    local enabled
    if entry.expandable and provider and provider.expand_category then
      local checks = provider:expand_category(entry.name)
      if #checks > 0 then
        enabled = true
        for _, check in ipairs(checks) do
          local check_name = check.name or check
          if not state.is_enabled(entry.bufnr, check_name) then
            enabled = false
            break
          end
        end
      else
        enabled = state.is_enabled(entry.bufnr, entry.name)
      end
    else
      enabled = state.is_enabled(entry.bufnr, entry.name)
    end
    local expanded = state.is_expanded(entry.name)
    -- Show [-]/[+] only for expandable categories; auto_expand ones start open
    local auto_open = entry.auto_expand and state.state.expanded[entry.name] == nil
    local is_open = expanded or auto_open
    local expand_icon = entry.expandable and (is_open and "[-] " or "[+] ") or ""
    local prefix = enabled and "[✓] " or "[ ] "
    local desc = entry.desc and (" - " .. entry.desc) or ""
    local config_source = entry.config_source or ""
    return {
      value = entry,
      display = expand_icon .. prefix .. entry.name .. desc .. config_source,
      ordinal = entry.name,
    }
  elseif entry.type == "check" then
    local enabled = state.is_enabled(entry.bufnr, entry.name)
    local prefix = enabled and "[✓] " or "[ ] "
    local source_indicator = entry.config_source or ""

    return {
      value = entry,
      display = "    " .. prefix .. entry.name .. source_indicator,
      ordinal = entry.name,
    }
  end
end

-- Build items list for current buffer.
-- force_expand: when true (filtering active), include all sub-checks regardless of expand state.
M.build_items = function(ft, provider, force_expand, bufnr)
  debug_print("build_items called with ft =", ft, "bufnr =", tostring(bufnr))

  local items = {
    { type = "header", display = "=== Severity Levels ===" },
    { type = "severity", name = "ERROR" },
    { type = "severity", name = "WARN" },
    { type = "severity", name = "INFO" },
    { type = "severity", name = "HINT" },
  }

  -- Add provider-specific sections if provider exists
  if provider then
    -- Add language options grouped by their group field
    if provider.get_language_options then
      local lang_opts = provider:get_language_options(bufnr)
      if lang_opts and #lang_opts > 0 then
        local current_group = nil
        for _, opt in ipairs(lang_opts) do
          local group = opt.group or "Options"
          if group ~= current_group then
            current_group = group
            table.insert(items, { type = "header", display = "=== " .. group .. " ===" })
          end
          table.insert(items, {
            type = "language_option",
            name = opt.name,
            provider_data = opt,
          })
        end
      end
    end

    -- Add categories header with config info
    local header_text = "=== " .. ft:upper() .. " Linter Categories"
    if provider.get_config_info then
      local info = provider:get_config_info(bufnr)
      if info then
        header_text = header_text .. " (" .. info .. ")"
      end
    end
    header_text = header_text .. " ==="
    table.insert(items, { type = "header", display = header_text })

    -- Get categories from provider
    local categories = provider:get_categories(bufnr)
    debug_print("categories for", ft, ":", categories and #categories or "nil")

    if categories and #categories > 0 then
      for _, cat in ipairs(categories) do
        table.insert(items, {
          type = "category",
          bufnr = bufnr,
          name = cat.name,
          desc = cat.desc,
          expandable = cat.expandable,
          config_source = cat.config_source,
          not_installed = cat.not_installed,
        })

        -- If expanded (or auto_expand and not explicitly collapsed, or force_expand), add individual checks
        local auto_open = cat.auto_expand and state.state.expanded[cat.name] == nil
        if (force_expand or auto_open or state.is_expanded(cat.name)) and provider.expand_category then
          local checks = provider:expand_category(cat.name)
          for _, check in ipairs(checks) do
            table.insert(items, {
              type = "check",
              bufnr = bufnr,
              name = check.name or check,
              parent = cat.name,
              config_source = check.config_source,
            })
          end
        end
      end
    end
  else
    -- No provider for this filetype
    table.insert(items, {
      type = "header",
      display = "=== No provider for filetype: " .. ft .. " ==="
    })
  end

  return items
end

-- Rebuild the finder and refresh the picker in-place.
-- restore_row: if given, explicitly set cursor to this row after refresh (for expand/collapse).
-- The picker always uses selection_strategy="row" so simple toggles keep cursor automatically.
local function refresh_picker(current_picker, ft, provider, restore_row, force_expand, bufnr)
  local new_items = M.build_items(ft, provider, force_expand, bufnr)

  local new_finder = finders.new_table({
    results = new_items,
    entry_maker = function(entry)
      return M.make_entry(entry, provider)
    end,
  })

  local target_row = restore_row or current_picker._selection_row
  debug_print("refresh_picker: target_row =", target_row)

  -- Register a one-shot completion callback. It fires at _on_complete(), which is the
  -- last thing the completor does -- after the cursor reset to row 1 for ascending sort.
  -- Clear all previous callbacks first to avoid stacking from rapid toggles.
  if target_row then
    current_picker:clear_completion_callbacks()
    current_picker:register_completion_callback(function(p)
      current_picker:clear_completion_callbacks()
      -- Reset _selection_entry so set_selection doesn't early-return on "same entry" check
      current_picker._selection_entry = nil
      debug_print("completion_callback: setting selection to", target_row)
      current_picker:set_selection(target_row)
    end)
  end

  current_picker:refresh(new_finder, { reset_prompt = false })
end

-- Show unified picker
M.show = function(opts)
  opts = opts or require('telescope.themes').get_dropdown({
    layout_config = {
      prompt_position = "top",
    },
    initial_mode = "normal",
  })

  -- Get current buffer and filetype BEFORE opening picker
  local original_bufnr = vim.api.nvim_get_current_buf()
  local original_ft = vim.bo[original_bufnr].filetype
  local provider = provider_registry.get_for_filetype(original_ft)

  state.init_severities()

  -- Initialize state for this buffer on first open.
  -- sync_state_from_files reads existing config files and populates state to
  -- reflect reality; if no config file exists the JSON defaults are kept.
  if provider then
    local is_first_open = state.state[original_bufnr] == nil
    state.init_buf_state(original_bufnr, provider)
    if is_first_open and provider.sync_state_from_files then
      provider:sync_state_from_files(state.state[original_bufnr], original_bufnr)
    end
  end

  local items = M.build_items(original_ft, provider, false, original_bufnr)

  local filter_active = false

  local function make_finder(force_expand)
    local built = M.build_items(original_ft, provider, force_expand, original_bufnr)
    return finders.new_table({
      results = built,
      entry_maker = function(entry)
        return M.make_entry(entry, provider)
      end,
    })
  end

  pickers.new(opts, {
    prompt_title = "Diagnostic Settings (Space=toggle, Tab=expand, Enter=apply session, gs=save to disk)",
    finder = make_finder(false),
    sorter = conf.generic_sorter(opts),
    selection_strategy = "row",
    attach_mappings = function(prompt_bufnr, map)
      -- Watch prompt for filter mode: rebuild with all checks expanded when typing,
      -- collapsed when prompt is cleared
      vim.api.nvim_buf_attach(prompt_bufnr, false, {
        on_lines = function()
          local prompt = action_state.get_current_picker(prompt_bufnr):_get_prompt()
          local is_filtering = prompt ~= ""
          if is_filtering == filter_active then return end
          filter_active = is_filtering
          local current_picker = action_state.get_current_picker(prompt_bufnr)
          if current_picker then
            current_picker:refresh(make_finder(is_filtering), { reset_prompt = false })
          end
        end,
      })

      -- Enter: apply session-only (no file write)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        require("diagnostic-picker").apply_config(original_bufnr)
      end)

      -- gs: save to disk + restart LSP
      map("n", "gs", function()
        actions.close(prompt_bufnr)
        require("diagnostic-picker").save_config(original_bufnr)
      end)

      -- Space to toggle selection (normal mode)
      local toggle_fn = function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then return end

        local current_picker = action_state.get_current_picker(prompt_bufnr)
        local entry = selection.value
        debug_print("toggle: type =", entry.type, "name =", entry.name)

        -- Not-installed categories are display-only
        if entry.not_installed then return end

        if entry.type == "severity" then
          state.toggle_severity(entry.name)
        elseif entry.type == "language_option" then
          if provider and provider.set_language_option then
            provider:set_language_option(entry.provider_data, entry.name, original_bufnr)
          end
        elseif entry.type == "category" then
          state.toggle_category(entry.bufnr, entry.name)
          local new_value = state.is_enabled(entry.bufnr, entry.name)
          if provider and provider.expand_category then
            local checks = provider:expand_category(entry.name)
            for _, check in ipairs(checks) do
              local check_name = check.name or check
              if not state.state[entry.bufnr] then state.state[entry.bufnr] = {} end
              state.state[entry.bufnr][check_name] = new_value
            end
          end
        elseif entry.type == "check" then
          state.toggle_check(entry.bufnr, entry.name)
        end

        refresh_picker(current_picker, original_ft, provider, nil, filter_active, original_bufnr)
      end

      map("n", "<Space>", toggle_fn)

      -- Tab to expand/collapse categories
      map("n", "<Tab>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then return end

        local current_picker = action_state.get_current_picker(prompt_bufnr)
        local entry = selection.value

        if entry.type == "category" and entry.expandable and not entry.not_installed then
          -- Capture row before state change; list grows/shrinks so we need to restore explicitly
          local current_row = current_picker:get_selection_row()
          state.toggle_expanded(entry.name)
          debug_print("expand/collapse", entry.name, "now =", state.is_expanded(entry.name))
          refresh_picker(current_picker, original_ft, provider, current_row, filter_active, original_bufnr)
        end
      end)

      return true
    end,
  }):find()

  -- Start in normal mode after picker opens
  vim.schedule(function()
    vim.cmd("stopinsert")
  end)
end

return M
