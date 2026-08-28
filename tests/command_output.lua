-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local original_ui_send = vim.api.nvim_ui_send
local original_on_key = vim.on_key
local original_get_mode = vim.api.nvim_get_mode
local input_listener
local sent = {}

vim.api.nvim_ui_send = function(value)
  table.insert(sent, value)
end
vim.on_key = function(callback)
  input_listener = callback
end

local function restore()
  vim.api.nvim_ui_send = original_ui_send
  vim.api.nvim_get_mode = original_get_mode
  vim.on_key = original_on_key
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

local function protocol_commands()
  local result = {}
  for _, value in ipairs(sent) do
    local command = value:match("^\27_Lector;A11y;1;(.+)\27\\$")
    if command then
      table.insert(result, command)
    end
  end
  return result
end

local function speech()
  local result = {}
  for _, command in ipairs(protocol_commands()) do
    local encoded = command:match("^say;([%da-f]+)$")
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

local function enter_command_line(stable)
  vim.api.nvim_exec_autocmds("CmdlineEnter", {
    pattern = ":",
    data = { cmdlevel = 1, cmdtype = ":" },
    modeline = false,
  })
  if stable ~= false then
    vim.wait(20)
  end
end

local function leave_command_line(abort)
  vim.api.nvim_exec_autocmds("CmdlineLeave", {
    pattern = ":",
    data = { abort = abort, cmdlevel = 1, cmdtype = ":" },
    modeline = false,
  })
end

local lector = require("lector")
local options = {
  announce_buffers = false,
  announce_cursor = false,
  announce_deletions = false,
  announce_diagnostics = false,
  announce_modes = true,
  announce_messages = true,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = false,
  announce_completions = false,
}
assert(lector.setup(options))
assert(type(input_listener) == "function", "input listener was not installed")
vim.wait(20)

vim.api.nvim_get_mode = function()
  return { mode = "i", blocking = false }
end
clear()
input_listener("x")
vim.wait(20)
equal({}, protocol_commands(), "ordinary Insert input keeps semantic policy stable")
vim.api.nvim_get_mode = original_get_mode

clear()
vim.api.nvim_get_mode = function()
  return { mode = "n", blocking = false }
end
input_listener("opaque input")
vim.wait(20)
equal(
  {},
  protocol_commands(),
  "ordinary normal-mode input keeps cursor suppression active"
)
vim.api.nvim_get_mode = original_get_mode

clear()
enter_command_line(false)
leave_command_line(false)
vim.wait(20)
equal(
  {
    "set;auto=1;cursor=0",
    "set;auto=0;cursor=0",
  },
  protocol_commands(),
  "a transient Ex implementation enables output reading without cursor tracking"
)

clear()
enter_command_line()
clear()
leave_command_line(false)
equal({ "end" }, protocol_commands(), "executed Ex command enables ordinary terminal reading")

input_listener("x")
vim.api.nvim_exec_autocmds("TextChanged", { modeline = false })
equal(
  { "end", "set;auto=0;cursor=0" },
  protocol_commands(),
  "a semantic edit reclaims policy after the input output handoff"
)

clear()
enter_command_line()
clear()
leave_command_line(true)
equal(
  {},
  protocol_commands(),
  "aborted command line leaves the existing semantic policy unchanged"
)

local mode = "rm"
vim.api.nvim_get_mode = function()
  return { mode = mode, blocking = mode:sub(1, 1) == "r" }
end

clear()
enter_command_line()
clear()
leave_command_line(false)
input_listener("\r")
vim.wait(20)
equal(
  { "end" },
  protocol_commands(),
  "a pager key leaves ordinary reading active while the pager remains open"
)

input_listener("\r")
mode = "n"
vim.wait(20)
equal(
  { "end", "set;auto=0;cursor=0" },
  protocol_commands(),
  "the key which closes a pager restores semantic policy afterwards"
)

mode = "r"
clear()
enter_command_line()
clear()
leave_command_line(false)
input_listener("\r")
vim.wait(20)
equal(
  { "end", "set;auto=0;cursor=0" },
  protocol_commands(),
  "a hit-enter key restores semantic policy before the editor redraws"
)

mode = "r?"
clear()
enter_command_line()
clear()
leave_command_line(false)
input_listener("y")
vim.wait(20)
equal(
  { "end", "set;auto=0;cursor=0" },
  protocol_commands(),
  "answering a confirmation restores semantic policy before the editor redraws"
)

mode = "rm"
clear()
enter_command_line()
clear()
leave_command_line(false)
input_listener("opaque input")
mode = "n"
vim.wait(20)
equal(
  { "end", "set;auto=0;cursor=0" },
  protocol_commands(),
  "leaving a pager restores semantic policy without inspecting its dismissal key"
)

mode = "n"
clear()
input_listener("x")
vim.cmd("echomsg 'lector blocking output fallback test'")
mode = "r"
input_listener("\r")
mode = "n"
vim.api.nvim_exec_autocmds("ModeChanged", {
  pattern = "r:n",
  modeline = false,
})
vim.wait(20)
equal(
  { "say;6c6563746f7220626c6f636b696e67206f75747075742066616c6c6261636b2074657374" },
  protocol_commands(),
  "unexpected blocking output is reported semantically without enabling cursor tracking"
)
equal(
  { "lector blocking output fallback test" },
  speech(),
  "a hit-enter dismissal does not compete with the exact message"
)

vim.api.nvim_get_mode = original_get_mode
clear()
enter_command_line()
clear()
leave_command_line(false)
vim.cmd("echomsg 'lector command output fallback test'")
vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
vim.wait(20)
equal(
  {
    "end",
    "set;auto=0;cursor=0",
  },
  protocol_commands(),
  "visible command output restores semantic policy without repeating the message"
)
equal(
  {},
  speech(),
  "visible command output is left to ordinary screen reading"
)

input_listener("x")
vim.wait(20)
clear()
vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
vim.wait(20)
for _, announcement in ipairs(speech()) do
  if announcement == "lector command output fallback test" then
    fail("captured history was replayed after fallback closed")
  end
end

lector.teardown()
options.announce_messages = false
assert(lector.setup(options))
vim.wait(20)
clear()
input_listener("x")
equal(
  {},
  protocol_commands(),
  "disabling message announcements also disables the input output handoff"
)
lector.teardown()
restore()
print("lector.nvim command output tests passed")
