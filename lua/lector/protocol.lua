-- SPDX-License-Identifier: MIT

local M = {}

local prefix = "\27_Lector;A11y;1;"
local terminator = "\27\\"
local maximum_speech_bytes = 2000
local maximum_message_bytes = 4096
local maximum_links = 32
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

local function limit_utf8(text, limit)
  if #text <= limit then
    return text
  end

  local last = limit
  while last > 0 do
    local following = text:byte(last + 1)
    if not following or following < 0x80 or following > 0xBF then
      break
    end
    last = last - 1
  end
  return text:sub(1, last)
end

function M.normalize(text)
  text = tostring(text or "")
  -- Preserve punctuation; the consumer applies the user's speech settings.
  text = text:gsub("%c", " "):gsub("%s+", " ")
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  return limit_utf8(text, maximum_speech_bytes)
end

function M.send(payload)
  if not M.available() then
    return false
  end
  return pcall(vim.api.nvim_ui_send, prefix .. payload .. terminator)
end

function M.supports_inline_links()
  return capabilities.inline and vim.tbl_contains(vim.split(capabilities.inline, ",", { plain = true }), "link")
end

local function char_boundary(text, offset)
  local byte = text:byte(offset + 1)
  return not byte or byte < 0x80 or byte >= 0xC0
end

local function normalize_links(text, links)
  -- Replace control characters without moving any source byte offsets.
  local source = text:gsub("%c", " "):gsub("\194[\128-\159]", "  ")
  local collapsed = source:gsub("%s+", " ")
  local leading = collapsed:sub(1, 1) == " " and 1 or 0
  local normalized = limit_utf8(vim.trim(collapsed), maximum_speech_bytes)
  local whitespace = source:gmatch("()%s+()")
  local first, after = whitespace()
  local removed = 0

  -- Link offsets arrive in order, so each whitespace run is visited once.
  local function remap(offset)
    while after and after - 1 <= offset do
      removed = removed + after - first - 1
      first, after = whitespace()
    end
    local inside = first and math.max(0, offset - first) or 0
    return math.max(0, math.min(#normalized, offset - removed - inside - leading))
  end

  local mapped = {}
  local previous_end = 0
  for _, range in ipairs(links) do
    local start = type(range) == "table" and range[1]
    local finish = type(range) == "table" and range[2]
    if type(start) == "number" and type(finish) == "number"
      and start % 1 == 0 and finish % 1 == 0
      and start >= previous_end and start < finish and finish <= #source
      and char_boundary(source, start) and char_boundary(source, finish)
    then
      previous_end = finish
      local mapped_start, mapped_end = remap(start), remap(finish)
      if mapped_start < mapped_end then
        mapped[#mapped + 1] = { mapped_start, mapped_end }
        if #mapped == maximum_links then
          break
        end
      end
    end
  end
  return normalized, mapped
end

local function send_speech(command, text, links)
  if type(links) == "table" and #links > 0 and M.supports_inline_links() then
    local annotated, mapped = normalize_links(tostring(text or ""), links)
    local encoded = hex_encode(annotated)
    local header = command .. "links="
    local budget = maximum_message_bytes - #prefix - #header - 1 - #encoded - #terminator
    local markers = {}
    for _, range in ipairs(mapped) do
      local marker = ("%d-%d"):format(range[1], range[2])
      budget = budget - #marker - (#markers > 0 and 1 or 0)
      if budget < 0 then
        break
      end
      markers[#markers + 1] = marker
    end
    if #markers > 0 then
      return M.send(header .. table.concat(markers, ",") .. ";" .. encoded)
    end
  end
  local normalized = M.normalize(text)
  return normalized and M.send(command .. hex_encode(normalized)) or false
end

function M.say(text, links)
  return send_speech("say;", text, links)
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

function M.line(text, indentation, links)
  return send_speech("line;" .. indentation_field(indentation) .. ";", text, links)
end

return M
