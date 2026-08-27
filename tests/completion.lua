-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local original_ui_send = vim.api.nvim_ui_send
local sent = {}
vim.api.nvim_ui_send = function(value)
  table.insert(sent, value)
end

local function fail(message)
  vim.api.nvim_ui_send = original_ui_send
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

local quiet = {
  announce_buffers = false,
  announce_cursor = false,
  announce_deletions = false,
  announce_diagnostics = false,
  announce_modes = false,
  announce_messages = false,
  announce_floating_windows = false,
  announce_command_line = false,
  announce_value_changes = false,
  announce_completions = true,
}

local lector = require("lector")
assert(lector.setup(quiet))
vim.wait(20)
clear()

assert(lector.update_menu({
  id = "test-completion",
  name = "completion menu",
  count = 3,
}))
equal({ "completion menu, 3 items, no selection" }, speech(), "menu opening")

clear()
assert(lector.update_menu({
  id = "test-completion",
  name = "completion menu",
  count = 3,
}))
equal({}, speech(), "unchanged unselected menu")

assert(lector.update_menu({
  id = "test-completion",
  name = "completion menu",
  count = 3,
  index = 2,
  label = "print",
  kind = 3,
  source = "LSP",
  documentation = "Print a value.\nReturns nothing.",
}))
equal({ "print, function, LSP, 2 of 3" }, speech(), "selected item")

clear()
assert(lector.update_menu({
  id = "test-completion",
  name = "completion menu",
  count = 3,
  index = 2,
  label = "print",
  kind = 3,
  source = "LSP",
  documentation = "Updated documentation.",
}))
equal({}, speech(), "metadata refresh does not repeat selection")
assert(lector.read_menu_documentation("test-completion"))
equal({ "Updated documentation." }, speech(), "documentation on demand")

clear()
assert(lector.update_menu({
  id = "test-completion",
  name = "completion menu",
  count = 3,
}))
equal({ "completion menu, no selection" }, speech(), "selection cleared")
clear()
assert(lector.read_menu_documentation("test-completion"))
equal({ "no completion selected" }, speech(), "unselected documentation")
assert(lector.close_menu("test-completion"))

clear()
assert(not lector.update_menu({ id = "invalid", count = 2, index = 3, label = "bad" }))
equal({}, speech(), "invalid selection rejected")

local saved_complete_info = vim.fn.complete_info
vim.fn.complete_info = function()
  return {
    pum_visible = 1,
    selected = 0,
    mode = "omni",
    items = {
      { word = "alpha", abbr = "", kind = "f", menu = "language server", info = "Alpha docs" },
      { word = "beta", abbr = "beta()", kind = "m", menu = "language server" },
    },
  }
end
clear()
vim.api.nvim_exec_autocmds("CompleteChanged", { modeline = false })
equal({ "alpha, function, language server, 1 of 2" }, speech(), "native completion")
vim.fn.complete_info = saved_complete_info
vim.api.nvim_exec_autocmds("CompleteDone", { modeline = false })

local original_cmdcomplete_info = vim.fn.cmdcomplete_info
vim.fn.cmdcomplete_info = function()
  return {
    pum_visible = 1,
    selected = 1,
    matches = { "buffer", "bdelete", "belowright" },
  }
end
clear()
vim.api.nvim_exec_autocmds("CmdlineChanged", { pattern = ":", modeline = false })
equal({ "bdelete, 2 of 3" }, speech(), "command-line completion")
vim.fn.cmdcomplete_info = original_cmdcomplete_info
vim.api.nvim_exec_autocmds("CmdlineLeave", { pattern = ":", modeline = false })

local blink_selection = 1
local blink_candidates = {
  {
    label = "gamma",
    kind = 3,
    source_name = "LSP",
    documentation = { value = "Gamma docs" },
  },
  {
    label = "garden",
    labelDetails = { detail = "(path)" },
    kind_name = "Folder",
    source_name = "Path",
  },
}
package.loaded["blink.cmp"] = {
  is_menu_visible = function() return true end,
  get_selected_item = function() return blink_candidates[blink_selection] end,
  get_items = function() return blink_candidates end,
  get_selected_item_idx = function() return blink_selection end,
}

clear()
vim.api.nvim_exec_autocmds("User", { pattern = "BlinkCmpMenuOpen", modeline = false })
assert(vim.wait(500, function() return #speech() > 0 end), "Blink announcement timed out")
equal({ "gamma, function, LSP, 1 of 2" }, speech(), "Blink opening selection")

blink_selection = 2
clear()
vim.api.nvim_exec_autocmds("User", { pattern = "BlinkCmpListSelect", modeline = false })
assert(vim.wait(500, function() return #speech() > 0 end), "Blink selection timed out")
equal({ "garden (path), folder, Path, 2 of 2" }, speech(), "Blink changed selection")

clear()
vim.api.nvim_exec_autocmds("User", { pattern = "BlinkCmpListSelect", modeline = false })
vim.wait(20)
equal({}, speech(), "unchanged Blink selection does not repeat")

blink_candidates = {
  {
    label = "write",
    kind_name = "Property",
    source_name = "Cmdline",
  },
}
blink_selection = 1
clear()
vim.api.nvim_exec_autocmds("User", { pattern = "BlinkCmpListSelect", modeline = false })
assert(vim.wait(500, function() return #speech() > 0 end), "Blink Cmdline selection timed out")
equal({ "write, 1 of 1" }, speech(), "Blink command completion omits generic provider metadata")

clear()
vim.api.nvim_exec_autocmds("User", { pattern = "BlinkCmpMenuClose", modeline = false })
assert(lector.read_menu_documentation())
equal({ "no completion selected" }, speech(), "Blink close clears selection")

lector.teardown()
vim.api.nvim_ui_send = original_ui_send
print("lector.nvim completion tests passed")
