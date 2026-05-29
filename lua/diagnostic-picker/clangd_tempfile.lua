-- clangd_tempfile: session-scoped .clangd management for the clangd provider.
--
-- apply_session() writes a temporary .clangd (backing up any existing one) and
-- restores the original on VimLeavePre, so session changes never persist on
-- disk. apply_config() (permanent write) calls cancel_cleanup() first so a
-- pending restore from an earlier session-apply doesn't later revert the file
-- the user just committed.
--
-- State is keyed by project_root so multiple projects can have independent
-- pending restores in one nvim session.

local M = {}

-- project_root -> { backup_path = string|nil, had_existing = bool }
local pending = {}

local function clangd_path(project_root)
  return project_root .. "/.clangd"
end

local function backup_path(project_root)
  return project_root .. "/.clangd.diagnostic-picker.bak"
end

-- Restore the original .clangd for a project root (or remove the temp file if
-- there was no original). Clears the pending entry. Safe to call repeatedly.
local function restore(project_root)
  local entry = pending[project_root]
  if not entry then return end
  pending[project_root] = nil

  local bak = entry.backup_path
  if bak and vim.fn.filereadable(bak) == 1 then
    os.rename(bak, clangd_path(project_root))
  elseif not entry.had_existing then
    os.remove(clangd_path(project_root))
  end
end

-- Write a temporary .clangd from `lines`, backing up any existing file and
-- scheduling restore on exit. Returns true on success, false if the write
-- failed. If a session-apply is already pending for this root, its original
-- backup is preserved (we don't overwrite the real file's backup).
function M.write_temp(project_root, lines)
  local target = clangd_path(project_root)
  local had_existing = vim.fn.filereadable(target) == 1

  -- Only create a backup the first time we go temporary for this root, so a
  -- second session-apply doesn't back up our own temp file as the "original".
  local already_pending = pending[project_root] ~= nil
  local bak = backup_path(project_root)

  if not already_pending and had_existing then
    local src = io.open(target, "r")
    if src then
      local dst = io.open(bak, "w")
      if dst then
        dst:write(src:read("*a"))
        dst:close()
      end
      src:close()
    end
  end

  local f = io.open(target, "w")
  if not f then
    return false
  end
  for _, line in ipairs(lines) do
    f:write(line .. "\n")
  end
  f:close()

  pending[project_root] = {
    backup_path = (already_pending and pending[project_root].backup_path)
      or (had_existing and bak or nil),
    had_existing = already_pending and pending[project_root].had_existing or had_existing,
  }

  -- Restore on exit. once=true per group; re-registering refreshes the closure
  -- set, but restore() iterates all pending roots so a single fire is enough.
  local group = vim.api.nvim_create_augroup("clangd_tempfile_restore", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      for root in pairs(pending) do
        restore(root)
      end
    end,
  })

  return true
end

-- Cancel a pending session restore for this root (the user committed a
-- permanent .clangd, so the temp file IS the desired file now). Discards the
-- backup without restoring it.
function M.cancel_cleanup(project_root)
  local entry = pending[project_root]
  if not entry then return end
  pending[project_root] = nil
  if entry.backup_path and vim.fn.filereadable(entry.backup_path) == 1 then
    os.remove(entry.backup_path)
  end
end

return M
