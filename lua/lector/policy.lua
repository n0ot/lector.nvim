-- SPDX-License-Identifier: MIT

local M = {}

-- Neovim may add more-specific variants to these mode families. Its mode()
-- documentation recommends comparing leading characters rather than complete
-- mode names, so known editor-owned families deliberately accept variants.
local editor_mode_families = {
  n = true, -- Normal and operator-pending
  o = true, -- Operator-pending as reported by some API contexts
  v = true, -- characterwise Visual
  V = true, -- linewise Visual
  ["\22"] = true, -- blockwise Visual
  s = true, -- characterwise Select
  S = true, -- linewise Select
  ["\19"] = true, -- blockwise Select
  i = true, -- Insert and Insert completion
  R = true, -- Replace and Virtual Replace
  c = true, -- command-line, search, and Ex editing
}

function M.editor_mode(mode)
  return type(mode) == "string" and editor_mode_families[mode:sub(1, 1)] == true
end

function M.editor_owns(context)
  context = context or {}

  if context.ui_transaction or context.terminal then
    return false
  end

  -- Lector owns command-line editing and provider menus even when a command
  -- line or a semantically integrated menu happens to live over a float.
  if context.command_line_active or context.menu_active then
    return true
  end

  if context.buftype == "prompt" then
    return false
  end

  local config = type(context.window_config) == "table"
      and context.window_config
    or {}
  if config.external == true or (type(config.relative) == "string" and config.relative ~= "") then
    return false
  end

  return M.editor_mode(context.mode)
end

return M
