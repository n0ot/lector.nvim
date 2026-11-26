-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local protocol = require("lector.protocol")
local original_ui_send = vim.api.nvim_ui_send
local sent
vim.api.nvim_ui_send = function(value)
  sent = value
end

local function equal(expected, actual)
  assert(expected == actual,
    "expected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
end

local function decode(payload)
  return (payload:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

-- Punctuation belongs to the consumer, regardless of apparent markup syntax.
for _, text in ipairs({
  [[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]],
  "```",
  "```lua",
  "before `value` after",
  "**bold** _word_ [label](target)",
  "“value”—…",
}) do
  equal(text, protocol.normalize(text))
  assert(protocol.say(text))
  equal(text, decode(assert(sent:match("^\27_Lector;A11y;1;say;(%x+)\27\\$"))))
  assert(protocol.line(text, 4))
  equal(text, decode(assert(sent:match("^\27_Lector;A11y;1;line;indent=4;(%x+)\27\\$"))))
end

equal("```lua local value = `x` ```",
  protocol.normalize("```lua\nlocal value = `x`\n```"))
equal("a b", protocol.normalize(" \ta\0\nb\r "))
equal(nil, protocol.normalize(" \t\r\n"))
equal(false, protocol.say(" \n"))
equal(false, protocol.line(" \n", 0))
equal(string.rep("a", 2000), protocol.normalize(string.rep("a", 2001)))
equal(string.rep("a", 1999), protocol.normalize(string.rep("a", 1999) .. "é"))

local original_list_uis = vim.api.nvim_list_uis
local uis = { { chan = 8 } }
vim.api.nvim_list_uis = function() return uis end
assert(protocol.query_capabilities())
equal("\27_Lector;A11y;1;query;1\27\\", sent)
local reply = "\27_Lector;A11y;1;capabilities;1;cue=blank;link=1"
equal(false, protocol.receive_capabilities(reply, 9))
assert(protocol.receive_capabilities(reply, 8))
assert(protocol.blank_line(0))
equal("\27_Lector;A11y;1;cue;blank;indent=0;626c616e6b\27\\", sent)

uis[2] = { chan = 9 }
equal(false, protocol.query_capabilities())
equal(false, protocol.receive_capabilities(reply, 8))
assert(protocol.blank_line(0))
equal("\27_Lector;A11y;1;line;indent=0;626c616e6b\27\\", sent)
uis[2] = nil
assert(protocol.query_capabilities())
equal(false, protocol.receive_capabilities(reply, 8))
assert(protocol.receive_capabilities(reply:gsub("capabilities;1;", "capabilities;2;"), 8))
assert(protocol.line("x y", 0, { { 2, 3 } }))
equal("\27_Lector;A11y;1;line;indent=0;782079\27\\", sent)
assert(protocol.query_capabilities())
assert(protocol.receive_capabilities("\27_Lector;A11y;1;capabilities;3;inline=link", 8))
assert(protocol.say("a\té end", { { 2, 4 }, { 5, 8 } }))
equal("\27_Lector;A11y;1;say;links=2-4,5-8;6120c3a920656e64\27\\", sent)
assert(protocol.line("a é end", 2, { { 2, 4 }, { 5, 8 } }))
equal("\27_Lector;A11y;1;line;indent=2;links=2-4,5-8;6120c3a920656e64\27\\", sent)
local wide = "  a" .. string.rep(" ", 2000) .. "end  "
assert(protocol.line(wide, 2, { { 2, 3 }, { 2003, 2006 } }))
equal("\27_Lector;A11y;1;line;indent=2;links=0-1,2-5;6120656e64\27\\", sent)
vim.api.nvim_list_uis = original_list_uis
vim.api.nvim_ui_send = original_ui_send
print("lector.nvim protocol tests passed")
