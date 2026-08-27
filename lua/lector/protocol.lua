-- SPDX-License-Identifier: MIT

local M = {}

local prefix = "Lector;A11y;1;"
local maximum_speech_bytes = 2000

local function hex_encode(text)
  return (text:gsub(".", function(character)
    return string.format("%02x", string.byte(character))
  end))
end

function M.available()
  return type(vim.api.nvim_ui_send) == "function"
end

function M.normalize(text)
  text = tostring(text or "")
  text = text:gsub("```[^\r\n]*[\r\n]+", ""):gsub("```", "")
  text = text:gsub("`([^`\r\n]+)`", "%1")
  text = text:gsub("%c", " "):gsub("%s+", " ")
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  if #text <= maximum_speech_bytes then
    return text
  end

  local last = maximum_speech_bytes
  while last > 0 do
    local following = text:byte(last + 1)
    if not following or following < 0x80 or following > 0xBF then
      break
    end
    last = last - 1
  end
  return text:sub(1, last)
end

function M.send(payload)
  if not M.available() then
    return false
  end
  return pcall(vim.api.nvim_ui_send, "\27_" .. prefix .. payload .. "\27\\")
end

function M.say(text)
  text = M.normalize(text)
  if not text then
    return false
  end
  return M.send("say;" .. hex_encode(text))
end

function M.line(text, indentation)
  text = M.normalize(text)
  if not text then
    return false
  end
  indentation = math.max(0, math.min(65535, math.floor(tonumber(indentation) or 0)))
  return M.send("line;indent=" .. indentation .. ";" .. hex_encode(text))
end

return M
