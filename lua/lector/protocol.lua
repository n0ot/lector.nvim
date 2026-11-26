-- SPDX-License-Identifier: MIT

local M = {}

local prefix = "Lector;A11y;1;"
local maximum_speech_bytes = 2000
local next_query_id = 0
local pending_query
local pending_channel
local capabilities = {}

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
  -- Preserve punctuation; the consumer applies the user's speech settings.
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

function M.reset_capabilities()
  pending_query = nil
  pending_channel = nil
  capabilities = {}
end

function M.query_capabilities()
  M.reset_capabilities()
  -- nvim_ui_send broadcasts. One receiver's response cannot vouch for others.
  local uis = vim.api.nvim_list_uis()
  if #uis ~= 1 then
    return false
  end
  pending_channel = uis[1].chan
  next_query_id = next_query_id + 1
  pending_query = tostring(next_query_id)
  if M.send("query;" .. pending_query) then
    return true
  end
  pending_query = nil
  return false
end

function M.receive_capabilities(sequence, channel)
  if type(sequence) ~= "string" or (channel and channel ~= pending_channel) then
    return false
  end
  -- Neovim passes the response without its terminating ST.
  sequence = sequence:gsub("\27\\$", "")
  local id, fields = sequence:match("^\27_Lector;A11y;1;capabilities;(%d+);([%w_=,;-]+)$")
  if not id or id ~= pending_query then
    return false
  end
  local reported = {}
  for field in fields:gmatch("[^;]+") do
    local name, value = field:match("^([%w_-]+)=([%w_,-]+)$")
    if not name or reported[name] then
      return false
    end
    reported[name] = value
  end
  capabilities = reported
  pending_query = nil
  return true
end

local function indentation_field(indentation)
  return "indent=" .. math.max(0, math.min(65535, math.floor(tonumber(indentation) or 0)))
end

function M.blank_line(indentation)
  if capabilities.cue and vim.tbl_contains(vim.split(capabilities.cue, ",", { plain = true }), "blank") then
    return M.send("cue;blank;" .. indentation_field(indentation) .. ";626c616e6b")
  end
  return M.line("blank", indentation)
end

function M.say_link(text)
  text = M.normalize(text)
  if not text then
    return false
  end
  if capabilities.link == "1" then
    return M.send("say-link;" .. hex_encode(text))
  end
  return M.say("link " .. text)
end

function M.line(text, indentation)
  text = M.normalize(text)
  if not text then
    return false
  end
  return M.send("line;" .. indentation_field(indentation) .. ";" .. hex_encode(text))
end

return M
