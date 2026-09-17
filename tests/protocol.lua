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

vim.api.nvim_ui_send = original_ui_send
print("lector.nvim protocol tests passed")
