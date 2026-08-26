-- SPDX-License-Identifier: MIT

local M = {}

function M.check()
  vim.health.start("Lector accessibility")

  local ok, lector = pcall(require, "lector")
  if not ok then
    vim.health.error("The lector module could not be loaded: " .. tostring(lector))
    return
  end

  local info = lector.health_info()
  if info.ui_send_available then
    vim.health.ok("nvim_ui_send() is available")
  else
    vim.health.error("nvim_ui_send() is unavailable; semantic terminal messages cannot be sent")
  end

  if info.enabled then
    vim.health.ok("The Neovim accessibility client is enabled")
  else
    vim.health.warn("The module is installed but setup() has not enabled it")
  end

  if info.terminal_fallback then
    vim.health.info("The current terminal buffer is using Lector's ordinary reading mode")
  elseif info.active then
    vim.health.ok("Semantic mode is active for the current buffer")
  elseif info.enabled then
    vim.health.info("Semantic mode is temporarily inactive")
  end

  if info.text_put_post then
    vim.health.ok("Structured put events are available")
  else
    vim.health.info("TextPutPost is unavailable; put announcements use the keyboard fallback")
  end

  if info.search_wrapped then
    vim.health.ok("SearchWrapped is available")
  else
    vim.health.info("SearchWrapped is unavailable; search counts work without wrap announcements")
  end

  vim.health.info("Protocol version 1 is one-way, so terminal-side Lector reception cannot be queried")
end

return M
