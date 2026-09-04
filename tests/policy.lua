-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local policy = require("lector.policy")

local function equal(expected, actual, context)
  if expected ~= actual then
    error((context or "values differ")
      .. "\nexpected: " .. vim.inspect(expected)
      .. "\nactual:   " .. vim.inspect(actual), 2)
  end
end

for _, mode in ipairs({
  "n", "no", "nov", "niI", "o", "v", "V", "\22", "s", "S", "\19",
  "i", "ic", "ix", "R", "Rv", "Rvc", "c", "cr", "cv",
}) do
  equal(true, policy.editor_mode(mode), mode .. " is an editor-owned mode")
end

for _, mode in ipairs({ "", "r", "rm", "r?", "!", "t", "x" }) do
  equal(false, policy.editor_mode(mode), mode .. " fails open")
end

equal(true, policy.editor_owns({
  mode = "n",
  buftype = "",
  window_config = { relative = "", external = false },
}), "an ordinary editor window is owned")

equal(false, policy.editor_owns({
  mode = "n",
  buftype = "",
  window_config = { relative = "editor" },
}), "a focused floating UI fails open despite using Normal mode")

equal(false, policy.editor_owns({
  mode = "i",
  buftype = "prompt",
  window_config = { relative = "" },
}), "a prompt buffer fails open despite using Insert mode")

equal(true, policy.editor_owns({
  mode = "c",
  buftype = "prompt",
  command_line_active = true,
  window_config = { relative = "editor" },
}), "semantic command-line editing takes temporary ownership")

equal(true, policy.editor_owns({
  mode = "n",
  buftype = "prompt",
  menu_active = true,
  window_config = { relative = "editor" },
}), "an integrated semantic menu remains owned")

equal(false, policy.editor_owns({
  mode = "n",
  terminal = true,
  menu_active = true,
}), "a terminal job always retains ownership")

equal(false, policy.editor_owns({
  mode = "n",
  ui_transaction = true,
  menu_active = true,
}), "a vim.ui transaction always retains ownership")

print("lector.nvim policy tests passed")
