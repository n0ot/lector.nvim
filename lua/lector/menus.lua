-- SPDX-License-Identifier: MIT

local protocol = require("lector.protocol")

local M = {}
local Menus = {}
Menus.__index = Menus

local native_completion_kinds = {
  v = "variable",
  f = "function",
  m = "member",
  t = "typedef",
  d = "macro",
}

local function readable_completion_kind(kind)
  if type(kind) == "number" then
    kind = vim.lsp
      and vim.lsp.protocol
      and vim.lsp.protocol.CompletionItemKind
      and vim.lsp.protocol.CompletionItemKind[kind]
  end
  kind = protocol.normalize(kind)
  if not kind then
    return nil
  end
  if native_completion_kinds[kind] then
    return native_completion_kinds[kind]
  end
  return kind:gsub("(%l)(%u)", "%1 %2"):lower()
end

local function count_text(count)
  return count == 1 and "1 item" or (count .. " items")
end

function M.new(dependencies)
  return setmetatable({
    enabled = assert(dependencies.enabled),
    options = assert(dependencies.options),
    say = assert(dependencies.say),
    states = {},
    current_id = nil,
  }, Menus)
end

function Menus:is_open()
  return self.current_id ~= nil
end

function Menus:announcement(menu)
  local options = self.options()
  local parts = { menu.label }
  if options.completion_include_kind and menu.kind then
    table.insert(parts, menu.kind)
  end
  if options.completion_include_source and menu.source then
    table.insert(parts, menu.source)
  end
  if options.completion_include_position and menu.index and menu.count > 0 then
    table.insert(parts, menu.index .. " of " .. menu.count)
  end
  return table.concat(parts, ", ")
end

function Menus:publish(menu, announce)
  if not self.enabled() or not announce or type(menu) ~= "table" then
    return false
  end
  local id = type(menu.id) == "string" and menu.id or nil
  local name = protocol.normalize(menu.name) or "menu"
  local count = tonumber(menu.count)
  local index = menu.index == nil and nil or tonumber(menu.index)
  if not id
    or id == ""
    or id:find("%c")
    or not count
    or count < 0
    or count ~= math.floor(count)
    or count > 100000
    or (index and (index < 1 or index > count or index ~= math.floor(index)))
  then
    return false
  end
  if count == 0 then
    self:close(id)
    return true
  end

  local label = index and protocol.normalize(menu.label) or nil
  if index and not label then
    return false
  end
  local current = {
    name = name,
    count = count,
    index = index,
    label = label,
    kind = readable_completion_kind(menu.kind),
    source = protocol.normalize(menu.source),
    documentation = protocol.normalize(menu.documentation),
  }
  current.key = table.concat({
    current.index or "",
    current.count,
    current.label or "",
    current.kind or "",
    current.source or "",
  }, "\0")

  local previous = self.states[id]
  self.states[id] = current
  self.current_id = id
  if current.index then
    if not previous or previous.key ~= current.key then
      return self.say(self:announcement(current))
    end
    return true
  end
  if not previous then
    return self.say(name .. ", " .. count_text(count) .. ", no selection")
  end
  if previous.index then
    return self.say(name .. ", no selection")
  end
  return true
end

function Menus:update(menu)
  return self:publish(menu, self.options().announce_completions)
end

function Menus:close(id)
  if type(id) ~= "string" then
    return false
  end
  self.states[id] = nil
  if self.current_id == id then
    self.current_id = next(self.states)
  end
  return true
end

function Menus:read_documentation(id)
  id = id or self.current_id
  local menu = id and self.states[id] or nil
  if not menu or not menu.index then
    return self.say("no completion selected")
  end
  if not menu.documentation then
    return self.say("no completion documentation")
  end
  return self.say(menu.documentation)
end

function Menus:reset()
  self.states = {}
  self.current_id = nil
end

return M
