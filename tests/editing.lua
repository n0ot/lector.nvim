-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local original_ui_send = vim.api.nvim_ui_send
local original_on_key = vim.on_key
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

local function semantic_speech()
  local result = {}
  for _, value in ipairs(sent) do
    local encoded = value:match("^\27_Lector;A11y;1;say;([%da-f]+)\27\\$")
    local indentation, line = value:match(
      "^\27_Lector;A11y;1;line;indent=(%d+);([%da-f]+)\27\\$"
    )
    local kind = encoded and "say" or (line and "line" or nil)
    encoded = encoded or line
    if encoded then
      local item = {
        kind = kind,
        text = encoded:gsub("%x%x", function(pair)
          return string.char(tonumber(pair, 16))
        end),
      }
      if indentation then
        item.indentation = tonumber(indentation)
      end
      table.insert(result, item)
    end
  end
  return result
end

local function clear()
  sent = {}
end

local function ended()
  for _, value in ipairs(sent) do
    if value == "\27_Lector;A11y;1;end\27\\" then
      return true
    end
  end
  return false
end

local lector = require("lector")
assert(lector.setup({
  announce_buffers = false,
  announce_cursor = true,
  announce_deletions = true,
  announce_diagnostics = true,
  announce_modes = false,
  announce_messages = false,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = false,
  announce_completions = true,
}))
assert(type(input_listener) == "function", "input listener was not installed")
vim.wait(10)

clear()
lector.say("```python\nprint(`value`)\n```")
equal({ "print(value)" }, speech(), "Markdown presentation syntax is not spoken")

local before = "This is Lector and Lec"
local after = "This is Lector and Le"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { before })
vim.api.nvim_win_set_cursor(0, { 1, #before - 1 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
lector.update_menu({ id = "test-completion", name = "completion menu", count = 1 })
clear()

local backspace = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
local original_get_cursor = vim.api.nvim_win_get_cursor
vim.api.nvim_win_get_cursor = function()
  return { 1, #before }
end
input_listener(backspace)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { after })
vim.api.nvim_win_get_cursor = function()
  return { 1, #after }
end
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0, modeline = false })
vim.api.nvim_win_get_cursor = original_get_cursor
vim.api.nvim_win_set_cursor(0, { 1, #after - 1 })
equal({ "c" }, speech(), "Backspace remains audible while completion is open")

clear()
input_listener("x")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { after .. "x" })
vim.api.nvim_win_set_cursor(0, { 1, #after + 1 })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0, modeline = false })
equal({}, speech(), "completion-driven edits remain quiet")

lector.close_menu("test-completion")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
input_listener("x")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "ac" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })
equal({ "deleted b" }, speech(), "editing cursor movement does not precede deletion speech")

clear()
local original_get_mode = vim.api.nvim_get_mode
local diagnostics = {
  { lnum = 0, severity = vim.diagnostic.severity.ERROR, message = "invalid syntax" },
  { lnum = 0, severity = vim.diagnostic.severity.WARN, message = "unused import" },
}
vim.api.nvim_get_mode = function()
  return { mode = "i", blocking = false }
end
vim.api.nvim_exec_autocmds("DiagnosticChanged", {
  buffer = 0,
  data = { diagnostics = diagnostics },
  modeline = false,
})
vim.api.nvim_get_mode = original_get_mode
equal({}, speech(), "insert-time diagnostics remain quiet")

clear()
local original_diagnostic_get = vim.diagnostic.get
vim.diagnostic.get = function()
  return diagnostics
end
vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n", modeline = false })
vim.diagnostic.get = original_diagnostic_get
equal(
  { "error, invalid syntax, 1 more" },
  speech(),
  "leaving Insert mode reports the final diagnostic state"
)

clear()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
equal({}, speech(), "InsertLeave cursor adjustment remains quiet")

clear()
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
equal({ "c" }, speech(), "the next deliberate character motion remains audible")

clear()
vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n", modeline = false })
equal({}, speech(), "unchanged diagnostics do not repeat on another mode event")

clear()
vim.api.nvim_exec_autocmds("DiagnosticChanged", {
  buffer = 0,
  data = {
    diagnostics = {
      { lnum = 0, severity = vim.diagnostic.severity.ERROR, message = "invalid syntax" },
      { lnum = 0, severity = vim.diagnostic.severity.WARN, message = "unused import" },
      { lnum = 0, severity = vim.diagnostic.severity.INFO, message = "consider sorting" },
    },
  },
  modeline = false,
})
equal(
  { "error, invalid syntax, 2 more" },
  speech(),
  "normal-mode diagnostics include the remaining count"
)

clear()
local original_get_option_value = vim.api.nvim_get_option_value
vim.api.nvim_get_option_value = function(name, options)
  if name == "buftype" then
    return "terminal"
  end
  return original_get_option_value(name, options)
end
assert(not lector.say("hidden semantic speech"))
vim.api.nvim_get_option_value = original_get_option_value
equal({}, speech(), "terminal buffers restore Lector's ordinary fallback")

clear()
assert(lector.say("semantic speech restored"))
equal({ "semantic speech restored" }, speech(), "semantic mode resumes outside terminals")

vim.cmd("nnoremenu 10.10 PopUp.First <Cmd>let g:lector_popup_choice='First'<CR>")
vim.cmd("nnoremenu 10.20 PopUp.Second <Nop>")
vim.cmd("nnoremenu 10.30 PopUp.-99- <Nop>")
clear()
vim.api.nvim_exec_autocmds("MenuPopup", { pattern = "n", modeline = false })
local popup_count = 0
for _, item in ipairs(vim.fn.menu_get("PopUp", "n")[1].submenus or {}) do
  local mapping = type(item.mappings) == "table" and item.mappings.n or nil
  if item.hidden ~= 1
    and not item.name:match("^%-%d+%-$")
    and (type(item.submenus) == "table" or (mapping and mapping.enabled == 1))
  then
    popup_count = popup_count + 1
  end
end
equal(
  { "context menu" },
  speech(),
  "right-click menus announce their semantic role without reading every item"
)

local down = vim.api.nvim_replace_termcodes("<Down>", true, false, true)
local up = vim.api.nvim_replace_termcodes("<Up>", true, false, true)
local control_n = vim.api.nvim_replace_termcodes("<C-N>", true, false, true)
local enter = vim.api.nvim_replace_termcodes("<CR>", true, false, true)

clear()
input_listener(down)
equal(
  { "First, 1 of " .. popup_count },
  speech(),
  "the first Down selects and announces the first context-menu item"
)

clear()
input_listener(down)
equal(
  { "Second, 2 of " .. popup_count },
  speech(),
  "Down announces the next context-menu item"
)

clear()
input_listener(up)
equal(
  { "First, 1 of " .. popup_count },
  speech(),
  "Up announces the previous context-menu item"
)

clear()
input_listener(control_n)
equal({}, speech(), "CTRL-N remains ignored by the native context menu")

clear()
vim.g.lector_popup_choice = nil
equal(
  "",
  input_listener(enter),
  "Enter is consumed when the adapter can activate the selected menu item"
)
vim.wait(10)
equal(
  "First",
  vim.g.lector_popup_choice,
  "Enter activates the exact selected context-menu item"
)
equal({}, speech(), "context-menu activation adds no synthetic speech")

vim.cmd("nnoremenu 90.10 PopUp.Parent.Child <Nop>")
clear()
vim.api.nvim_exec_autocmds("MenuPopup", { pattern = "n", modeline = false })
local parent_index
local root_items = vim.fn.menu_get("PopUp", "n")[1].submenus or {}
local accessible_index = 0
for _, item in ipairs(root_items) do
  local mapping = type(item.mappings) == "table" and item.mappings.n or nil
  local has_submenu = type(item.submenus) == "table" and #item.submenus > 0
  if item.hidden ~= 1
    and not item.name:match("^%-%d+%-$")
    and (has_submenu or (mapping and mapping.enabled == 1))
  then
    accessible_index = accessible_index + 1
    if item.name == "Parent" then
      parent_index = accessible_index
    end
  end
end
local submenu_popup_count = accessible_index
assert(parent_index, "test submenu was not present")
for _ = 1, parent_index do
  clear()
  input_listener(down)
end
equal(
  { "Parent, submenu, " .. parent_index .. " of " .. submenu_popup_count },
  speech(),
  "a native submenu is identified before it opens"
)
clear()
input_listener(enter)
assert(ended(), "submenus should return to ordinary terminal tracking")
assert(not lector.health_info().active, "semantic mode stayed active inside a native submenu")
vim.wait(10)
assert(lector.health_info().active, "semantic mode did not resume after the menu closed")

lector.teardown()

vim.api.nvim_buf_set_name(0, "/private/tmp/lector-buffer-announcement-test.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "  first line" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
clear()
assert(lector.setup({
  announce_buffers = true,
  announce_cursor = false,
  announce_deletions = false,
  announce_diagnostics = false,
  announce_modes = false,
  announce_messages = false,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = false,
  announce_completions = false,
}))
vim.wait(10)
equal(
  {
    { kind = "say", text = "lector-buffer-announcement-test.lua" },
    { kind = "line", text = "first line", indentation = 2 },
  },
  semantic_speech(),
  "buffer entry announces the name and current line separately"
)
lector.teardown()
restore()
print("lector Neovim editing tests passed")
