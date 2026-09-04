-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local original_ui_send = vim.api.nvim_ui_send
local original_defer_fn = vim.defer_fn
local original_ui_input = vim.ui.input
local original_ui_select = vim.ui.select
local sent = {}
vim.api.nvim_ui_send = function(value)
  table.insert(sent, value)
end

local function restore()
  vim.api.nvim_ui_send = original_ui_send
  vim.defer_fn = original_defer_fn
  vim.ui.input = original_ui_input
  vim.ui.select = original_ui_select
end

local function fail(message)
  restore()
  error(message, 2)
end

local function equal(expected, actual, context)
  if not vim.deep_equal(expected, actual) then
    fail((context or "values differ")
      .. "\nexpected: " .. vim.inspect(expected)
      .. "\nactual:   " .. vim.inspect(actual))
  end
end

local function speech()
  local result = {}
  for _, value in ipairs(sent) do
    local encoded = value:match("^\27_Lector;A11y;1;say;([%da-f]+)\27\\$")
    if encoded then
      table.insert(result, (encoded:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
      end)))
    end
  end
  return result
end

local function clear()
  sent = {}
end

local options = {
  announce_buffers = true,
  announce_cursor = false,
  announce_deletions = false,
  announce_diagnostics = false,
  announce_modes = false,
  announce_messages = false,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = false,
  announce_puts = false,
  announce_folds = false,
  announce_search = false,
  announce_quickfix = false,
  announce_recording = false,
  announce_spelling = false,
  announce_completions = false,
  announce_popup_menus = false,
}

local commands = {
  "LectorSay",
  "LectorAccessibilityEnable",
  "LectorAccessibilityDisable",
  "LectorCompletionDocumentation",
  "LectorDiagnostic",
  "LectorStatus",
}

local baseline_input_listeners = vim.on_key()
local timers = {}
vim.defer_fn = function()
  local timer = {
    closed = false,
    stopped = false,
  }
  function timer:stop()
    self.stopped = true
  end
  function timer:is_closing()
    return self.closed
  end
  function timer:close()
    self.closed = true
  end
  table.insert(timers, timer)
  return timer
end

local first = require("lector")
local first_options = vim.tbl_extend("force", {}, options, {
  announce_completions = true,
})
assert(first.setup(first_options))
local first_ui_input = vim.ui.input
local first_ui_select = vim.ui.select
assert(first_ui_input ~= original_ui_input, "setup did not install the input handoff")
assert(first_ui_select ~= original_ui_select, "setup did not install the selector handoff")
vim.api.nvim_exec_autocmds("User", {
  pattern = "BlinkCmpMenuOpen",
  modeline = false,
})
equal(4, #timers, "the reload test did not start the deferred refresh timers")

package.loaded["lector"] = nil
local second = require("lector")
assert(first ~= second, "module reload returned the original instance")
assert(second.setup(options))
assert(vim.ui.input ~= first_ui_input, "module reload retained the stale input wrapper")
assert(vim.ui.select ~= first_ui_select, "module reload retained the stale selector wrapper")
assert(not first.health_info().enabled, "the replaced module instance remained enabled")
for _, timer in ipairs(timers) do
  assert(timer.stopped and timer.closed, "module reload did not cancel a deferred timer")
end

timers = {}
assert(second.setup(first_options))
vim.api.nvim_exec_autocmds("User", {
  pattern = "BlinkCmpMenuOpen",
  modeline = false,
})
equal(4, #timers, "repeated setup did not start the deferred refresh timers")
assert(second.setup(options))
for _, timer in ipairs(timers) do
  assert(timer.stopped and timer.closed, "repeated setup did not cancel a deferred timer")
end
vim.defer_fn = original_defer_fn
equal(
  baseline_input_listeners + 1,
  vim.on_key(),
  "module reload replaces rather than accumulates the input listener"
)

vim.wait(20)
equal(
  { "unnamed buffer" },
  speech(),
  "only the replacement instance runs its deferred startup announcement"
)

local autocmd_count = #vim.api.nvim_get_autocmds({
  group = "LectorApplicationAccessibility",
})
clear()
assert(second.setup(options))
assert(second.setup(options))
vim.wait(20)
equal(
  { "unnamed buffer" },
  speech(),
  "repeated setup invalidates deferred work from the previous lifecycle"
)
equal(
  autocmd_count,
  #vim.api.nvim_get_autocmds({ group = "LectorApplicationAccessibility" }),
  "repeated setup replaces rather than accumulates autocmds"
)
equal(
  baseline_input_listeners + 1,
  vim.on_key(),
  "repeated setup replaces rather than accumulates the input listener"
)

first.teardown()
for _, name in ipairs(commands) do
  equal(2, vim.fn.exists(":" .. name), "a stale instance cannot remove " .. name)
end
equal(
  baseline_input_listeners + 1,
  vim.on_key(),
  "a stale instance cannot remove the active input listener"
)

vim.cmd("LectorAccessibilityDisable")
assert(not second.health_info().enabled, "the disable command did not target the active instance")
vim.cmd("LectorAccessibilityEnable")
assert(second.health_info().enabled, "the enable command did not target the active instance")

local replacement_ui_select = function() end
local replacement_ui_input = function() end
vim.ui.input = replacement_ui_input
vim.ui.select = replacement_ui_select
vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
assert(
  vim.ui.input ~= replacement_ui_input,
  "SafeState did not wrap an input provider installed after setup"
)
assert(
  vim.ui.select ~= replacement_ui_select,
  "SafeState did not wrap a selector installed after setup"
)

clear()
second.teardown()
equal(replacement_ui_input, vim.ui.input, "teardown restores the latest input provider")
equal(replacement_ui_select, vim.ui.select, "teardown restores the latest selector provider")
vim.wait(20)
equal({}, speech(), "teardown cancels pending deferred announcements")
equal(
  baseline_input_listeners,
  vim.on_key(),
  "teardown removes the input listener"
)
for _, name in ipairs(commands) do
  equal(0, vim.fn.exists(":" .. name), "teardown removes " .. name)
end
local autocmd_ok = pcall(vim.api.nvim_get_autocmds, {
  group = "LectorApplicationAccessibility",
})
assert(not autocmd_ok, "teardown left its autocmd group installed")

restore()
print("lector.nvim reload tests passed")
