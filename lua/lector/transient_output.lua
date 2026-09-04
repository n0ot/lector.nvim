-- SPDX-License-Identifier: MIT

local M = {}

local normal_only_commands = {
  ["\7"] = true, -- CTRL-G: buffer and cursor status
}

local direct_commands = {
  K = true, -- 'keywordprg', which can run an Ex or external command
}

-- These Normal/Visual commands call Neovim's message, selection, or pager
-- implementation directly. Unlike a typed Ex command, they have no
-- CmdlineLeave boundary at which output reading can be enabled.
local command_suffixes = {
  g = {
    ["\7"] = true, -- cursor position information
    ["\29"] = true, -- tag jump with selection when there are several matches
    ["8"] = true, -- UTF-8 bytes
    ["<"] = true, -- previous command output
    ["]"] = true, -- tag selection
    a = true, -- character value
  },
  ["["] = {
    D = true,
    I = true,
    d = true,
    i = true,
  },
  ["]"] = {
    D = true,
    I = true,
    d = true,
    i = true,
  },
  z = {
    ["="] = true, -- spelling suggestions
  },
}

local function observes_native_commands(mode)
  local kind = type(mode) == "string" and mode:sub(1, 1) or ""
  return kind == "n"
    or kind == "v"
    or kind == "V"
    or kind == "s"
    or kind == "S"
    or kind == "\22"
    or kind == "\19"
end

function M.new(dependencies)
  return setmetatable({
    begin_output = assert(dependencies.begin_output),
    pending_prefix = nil,
  }, { __index = M })
end

function M:reset()
  self.pending_prefix = nil
end

function M:observe_key(key, mode, count)
  if not observes_native_commands(mode) then
    self:reset()
    return false
  end

  if self.pending_prefix then
    local prefix = self.pending_prefix
    local suffixes = command_suffixes[prefix]
    self.pending_prefix = nil
    if suffixes and suffixes[key] then
      if prefix == "z" and key == "=" and (tonumber(count) or 0) ~= 0 then
        return false
      end
      self.begin_output(prefix .. key, mode, count)
      return true
    end
    return false
  end

  if command_suffixes[key] then
    self.pending_prefix = key
    return false
  end

  local normal_mode = mode:sub(1, 1) == "n"
  if direct_commands[key] or (normal_mode and normal_only_commands[key]) then
    self.begin_output(key, mode, count)
    return true
  end
  return false
end

return M
