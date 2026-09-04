-- SPDX-License-Identifier: MIT

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)

local output = require("lector.transient_output")
local started = 0
local observer = output.new({
  begin_output = function() started = started + 1 end,
})

local function equal(expected, actual, context)
  if not vim.deep_equal(expected, actual) then
    error((context or "values differ")
      .. "\nexpected: " .. vim.inspect(expected)
      .. "\nactual:   " .. vim.inspect(actual), 2)
  end
end

local function sequence(keys, mode)
  local observed = false
  for key in keys:gmatch(".") do
    observed = observer:observe_key(key, mode or "n") or observed
  end
  return observed
end

equal(false, observer:observe_key("v", "n"), "Visual entry is not output")
equal(false, observer:observe_key("V", "n"), "Visual-line entry is not output")
equal(false, observer:observe_key("\22", "n"), "Visual-block entry is not output")
equal(0, started, "Visual entry never enables automatic reading")

for _, command in ipairs({
  "z=", "g<", "g]", "ga", "g8", "g\7", "g\29",
  "[i", "]i", "[I", "]I", "[d", "]d", "[D", "]D",
}) do
  observer:reset()
  local before = started
  assert(sequence(command), command .. " was not recognized as native output")
  equal(before + 1, started, command .. " starts one output handoff")
end

observer:reset()
local before = started
assert(not sequence("gg"), "ordinary g command was classified as output")
assert(not observer:observe_key("<", "n"), "completed gg left a stale prefix")
equal(before, started, "ordinary g commands remain semantic")

observer:reset()
before = started
assert(observer:observe_key("K", "n"), "Normal K was not recognized")
assert(observer:observe_key("K", "v"), "Visual K was not recognized")
equal(before + 2, started, "keyword lookup hands off in Normal and Visual modes")

observer:reset()
before = started
assert(observer:observe_key("\7", "n"), "Normal CTRL-G was not recognized")
assert(not observer:observe_key("\7", "v"), "Visual CTRL-G toggles Select mode")
equal(before + 1, started, "Visual CTRL-G does not start output reading")

observer:reset()
observer:observe_key("z", "n")
assert(not observer:observe_key("=", "i"), "Insert input completed a Normal command")
equal(nil, observer.pending_prefix, "leaving an editor command mode clears prefixes")

observer:reset()
before = started
observer:observe_key("z", "n", 1)
assert(not observer:observe_key("=", "n", 1), "counted z= does not show suggestions")
equal(before, started, "counted spelling replacement remains semantic")

print("lector.nvim transient output tests passed")
