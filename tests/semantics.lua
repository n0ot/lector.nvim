-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local original_ui_send = vim.api.nvim_ui_send
local original_on_key = vim.on_key
local original_ui_select = vim.ui.select
local input_listener
local pending_ui_select
local sent = {}

vim.api.nvim_ui_send = function(value)
  table.insert(sent, value)
end
vim.on_key = function(callback)
  input_listener = callback
end
vim.ui.select = function(items, options, callback)
  pending_ui_select = {
    items = items,
    options = options,
    callback = callback,
  }
end

local function restore()
  vim.api.nvim_ui_send = original_ui_send
  vim.on_key = original_on_key
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

local function semantic_text()
  local result = {}
  for _, value in ipairs(sent) do
    local encoded = value:match("^\27_Lector;A11y;1;say;([%da-f]+)\27\\$")
      or value:match("^\27_Lector;A11y;1;line;indent=%d+;([%da-f]+)\27\\$")
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

local lector = require("lector")
assert(lector.setup({
  announce_buffers = false,
  announce_cursor = true,
  announce_deletions = true,
  announce_diagnostics = false,
  announce_modes = false,
  announce_messages = false,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = true,
  announce_puts = true,
  announce_folds = true,
  announce_search = true,
  announce_quickfix = true,
  announce_recording = true,
  announce_spelling = true,
  announce_completions = false,
  announce_popup_menus = false,
}))
assert(type(input_listener) == "function", "input listener was not installed")

vim.api.nvim_buf_set_name(0, "/private/tmp/lector-semantics.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)

clear()
vim.cmd("normal! dd")
vim.wait(10)
equal({ "two" }, semantic_text(), "linewise deletion reads the line under the resulting cursor")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "foo bar baz" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
clear()
local original_get_mode = vim.api.nvim_get_mode
local simulated_mode = "n"
vim.api.nvim_get_mode = function()
  return { mode = simulated_mode, blocking = false }
end
input_listener("opaque input")
simulated_mode = "o"
input_listener("opaque input")
input_listener("opaque input")
vim.api.nvim_get_mode = original_get_mode
vim.cmd("normal! daw")
vim.wait(10)
equal({ "baz" }, semantic_text(), "word-object deletion reads the resulting cursor word")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
clear()
vim.cmd("normal! vld")
vim.wait(10)
equal(
  { "c" },
  semantic_text(),
  "characterwise Visual deletion reads only the resulting cursor character"
)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
clear()
vim.cmd("normal! Vjd")
vim.wait(10)
equal({ "three" }, semantic_text(), "Visual line deletion reads the resulting line")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "anchor" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.setreg('"', { "pasted line" }, "V")
clear()
input_listener("opaque input")
vim.cmd("normal! p")
vim.wait(10)
equal({ "pasted 1 line" }, speech(), "put fallback reports linewise register contents")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fold one", "fold two", "outside" })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.wo.foldmethod = "manual"
vim.cmd("1,2fold")
vim.cmd("normal! zM")
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  { "folded, 2 lines" },
  speech(),
  "entering a closed fold announces its hidden extent"
)

clear()
input_listener("opaque input")
vim.cmd("normal! zo")
vim.wait(10)
equal({ "fold opened" }, speech(), "opening a fold without moving the cursor is announced")

vim.cmd("normal! zE")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one two one", "one" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.setreg("/", "one")
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
lector.observe_search(function()
  vim.cmd("normal! n")
end)
vim.wait(10)
equal({ "2 of 3" }, speech(), "search navigation announces match position")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
clear()
lector.observe_search(function()
  vim.cmd("normal! n")
end)
vim.wait(10)
equal({ "1 of 3, wrapped" }, speech(), "wrapped search is announced once")

vim.fn.setqflist({}, "r", {
  title = "Build",
  items = {
    {
      bufnr = vim.api.nvim_get_current_buf(),
      lnum = 2,
      col = 1,
      text = "bad value",
      type = "E",
    },
  },
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  {
    "Build, error, bad value, lector-semantics.lua, line 2, column 1, 1 of 1",
  },
  semantic_text(),
  "a quickfix destination replaces the competing cursor-line announcement"
)

vim.fn.setqflist({}, "f")
vim.fn.setloclist(0, {}, "r", {
  title = "Window checks",
  items = {
    {
      bufnr = vim.api.nvim_get_current_buf(),
      lnum = 1,
      col = 1,
      text = "local warning",
      type = "W",
    },
  },
})
clear()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  {
    "Window checks, warning, local warning, lector-semantics.lua, line 1, column 1, 1 of 1",
  },
  semantic_text(),
  "a location-list destination uses the window-local list without repeating the line"
)
vim.fn.setloclist(0, {}, "f")

local source_buffer = vim.api.nvim_get_current_buf()
vim.fn.setqflist({}, "r", {
  title = "Open list",
  items = {
    { bufnr = source_buffer, lnum = 1, text = "first problem", type = "E" },
    { bufnr = source_buffer, lnum = 2, text = "second problem", type = "W" },
  },
})
vim.cmd("copen")
vim.wait(10)
clear()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {
  buffer = vim.api.nvim_get_current_buf(),
  modeline = false,
})
vim.wait(10)
equal(
  { "Open list, warning, second problem, lector-semantics.lua, line 2, 2 of 2" },
  semantic_text(),
  "an open quickfix window reads its structured entry"
)
vim.cmd("cclose")
vim.fn.setqflist({}, "f")
vim.wait(10)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "the quik brown fox" })
vim.bo.spelllang = "en_us"
vim.wo.spell = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  { "misspelled, quik" },
  speech(),
  "a cursor destination announces its spelling state without inspecting input"
)
clear()
vim.api.nvim_win_set_cursor(0, { 1, 5 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal({ "u" }, speech(), "movement within the same misspelling does not repeat its status")

local original_spellsuggest = vim.o.spellsuggest
vim.o.spellsuggest = "best,5"
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local suggestions = vim.fn.spellsuggest("quik", 5, false)
local expected_suggestions = { "Change quik to" }
local spelling_items = {}
for index, suggestion in ipairs(suggestions) do
  table.insert(expected_suggestions, index .. ", " .. suggestion)
  table.insert(spelling_items, { word = suggestion })
end
table.insert(expected_suggestions, "Type a number and Enter, or q to cancel")
clear()
input_listener("z", "z")
input_listener("=", "=")
pending_ui_select = nil
vim.ui.select(spelling_items, {
  prompt = 'Change "quik" to:',
  kind = "spell",
  format_item = function(item) return item.word end,
}, function() end)
equal(
  { table.concat(expected_suggestions, ". ") },
  speech(),
  "a spelling selector reuses the announcement made before z= opens"
)
assert(pending_ui_select, "the spelling selector did not reach its UI provider")
assert(lector.health_info().active, "a semantic spelling selector yielded terminal ownership")
for _, value in ipairs(sent) do
  if value:find("set;auto=1;cursor=0", 1, true)
    or value:find(";end\27\\", 1, true)
  then
    fail("a semantic spelling selector yielded terminal reading")
  end
end
pending_ui_select.callback(nil, nil)
vim.wait(10)

clear()
input_listener("z", "z")
input_listener("=", "=")
vim.api.nvim_exec_autocmds("CmdlineEnter", {
  pattern = "-",
  data = { cmdlevel = 1, cmdtype = "-" },
  modeline = false,
})
equal(
  { table.concat(expected_suggestions, ". ") },
  speech(),
  "z= announces Neovim's own spelling suggestions semantically"
)
for _, value in ipairs(sent) do
  if value:find("set;auto=1;cursor=0", 1, true) then
    fail("a semantically announced z= prompt enabled terminal automatic reading")
  end
end
vim.api.nvim_exec_autocmds("CmdlineLeave", {
  pattern = "-",
  data = { abort = true, cmdlevel = 1, cmdtype = "-" },
  modeline = false,
})
vim.wait(10)
equal(
  { table.concat(expected_suggestions, ". ") },
  speech(),
  "closing the native suggestion prompt does not repeat its contents"
)

clear()
pending_ui_select = nil
vim.ui.select({ { word = "test" }, { word = "tests" } }, {
  prompt = 'Change "tesst" to:',
  kind = "spell",
  format_item = function(item) return item.word end,
}, function() end)
equal(
  { "Change tesst to. 1, test. 2, tests. Choose an item, or cancel" },
  speech(),
  "spell UI metadata is sufficient without observing a mapping"
)
assert(pending_ui_select, "the direct spelling selector did not reach its UI provider")
assert(lector.health_info().active, "a direct spelling selector yielded terminal ownership")
pending_ui_select.callback(nil, nil)
vim.wait(10)
vim.o.spellsuggest = original_spellsuggest
vim.wo.spell = false

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
lector.observe_navigation("next", function()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
end)
vim.wait(10)
equal(
  { "second" },
  semantic_text(),
  "an observed navigation uses its resulting cursor geometry"
)

clear()
local navigation_result = lector.observe_navigation("next", function()
  return "provider result"
end)
equal(
  "provider result",
  navigation_result,
  "navigation observation preserves the provider's return value"
)
vim.wait(10)
equal(
  { "no next item" },
  speech(),
  "an observed navigation with no distinct destination is announced"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
clear()
lector.observe_navigation("next", function()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end)
lector.observe_navigation("next", function() end)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  { "second", "no next item" },
  semantic_text(),
  "coalesced cursor movement retains its destination and failure feedback"
)
equal(
  { "no next item" },
  speech(),
  "a rapid failed navigation survives the prior cursor event"
)

clear()
local command_looking_input = {
  { "f", "]f" },
  { "s", "]s" },
  { "b", "[b" },
  { "p", "p" },
  { "n", "n" },
  { "g", "g" },
  { "d", "d" },
  { "x", "x" },
  { "\1", "\1" },
  { "\24", "\24" },
}
for _, input in ipairs(command_looking_input) do
  input_listener(input[1], input[2])
end
vim.wait(10)
equal(
  {},
  speech(),
  "literal input and mapping expansions have no editor-command semantics"
)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "value 9" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0, modeline = false })
vim.wait(10)
clear()
input_listener("opaque input")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "value 10" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })
vim.wait(10)
equal(
  { "10" },
  speech(),
  "numeric changes are detected from their text effect without inspecting input"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
vim.wait(10)
clear()
lector.observe_navigation("previous", function() end)
vim.wait(10)
equal(
  { "no previous item" },
  speech(),
  "an observed provider navigation retains its semantic direction"
)

local original_buffer = vim.api.nvim_get_current_buf()
local next_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(next_buffer, "/private/tmp/lector-next-buffer.lua")
clear()
lector.observe_navigation("next", function()
  vim.api.nvim_set_current_buf(next_buffer)
end)
vim.wait(10)
equal(
  {},
  speech(),
  "a successful mapped buffer navigation cancels the unavailable destination"
)
vim.api.nvim_set_current_buf(original_buffer)
vim.wait(10)
vim.api.nvim_buf_delete(next_buffer, { force = true })

clear()
lector.observe_navigation("next", function()
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "added by provider action" })
end)
vim.wait(10)
equal(
  {},
  speech(),
  "a nonmoving provider action which changes text is not reported as unavailable"
)

clear()
lector.observe_navigation("next", function() end)
lector.say("navigation result")
vim.wait(10)
equal(
  { "navigation result" },
  speech(),
  "another semantic result supersedes the unavailable-destination announcement"
)

clear()
local navigation_ok, navigation_error = pcall(function()
  lector.observe_navigation("next", function()
    error("provider failure")
  end)
end)
assert(not navigation_ok and navigation_error:find("provider failure", 1, true))
vim.wait(10)
equal({}, speech(), "a failed provider action is rethrown without stale navigation speech")

clear()
vim.cmd("normal! qq")
equal({ "recording q" }, speech(), "macro recording start is announced")
clear()
vim.cmd("normal! q")
equal({ "recording stopped" }, speech(), "macro recording stop is announced")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta", "gamma" })
vim.api.nvim_win_set_cursor(0, { 2, 1 })
vim.bo.modified = true
clear()
assert(lector.announce_status())
equal(
  { "lector-semantics.lua, modified, line 2 of 3, column 2" },
  speech(),
  "on-demand status exposes statusline position and buffer state"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! vj")
clear()
assert(lector.announce_status())
equal(
  { "lector-semantics.lua, modified, line 2 of 3, column 1, 2 lines selected" },
  speech(),
  "on-demand status summarizes the active Visual selection"
)
vim.cmd("normal! \27")

lector.teardown()
restore()
print("lector.nvim semantic tests passed")
