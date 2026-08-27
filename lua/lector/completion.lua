-- SPDX-License-Identifier: MIT

local M = {}
local Completion = {}
Completion.__index = Completion

local native_menu_id = "neovim-insert-completion"
local command_line_menu_id = "neovim-command-line-completion"
local blink_menu_id = "blink-completion"

local function native_item_label(item)
  if type(item) ~= "table" then
    return nil
  end
  local abbreviation = type(item.abbr) == "string" and item.abbr or ""
  return abbreviation ~= "" and abbreviation or item.word
end

local function blink_documentation(item)
  if not item then
    return nil
  end
  if type(item.documentation) == "string" then
    return item.documentation
  end
  if type(item.documentation) == "table" then
    return item.documentation.value
  end
  return nil
end

local function blink_item_label(item)
  if not item then
    return nil
  end
  local label = item.label
  local details = type(item.labelDetails) == "table" and item.labelDetails.detail or nil
  if type(label) == "string" and type(details) == "string" and details ~= "" then
    return label .. " " .. details
  end
  return label
end

function M.new(dependencies)
  return setmetatable({
    blink_menu_open = false,
    blink_refresh_generation = 0,
    defer = assert(dependencies.defer),
    enabled = assert(dependencies.enabled),
    lifecycle_generation = assert(dependencies.lifecycle_generation),
    lifecycle_is_current = assert(dependencies.lifecycle_is_current),
    menus = assert(dependencies.menus),
    options = assert(dependencies.options),
  }, Completion)
end

function Completion:is_blink_open()
  return self.blink_menu_open
end

function Completion:invalidate()
  self.blink_menu_open = false
  self.blink_refresh_generation = self.blink_refresh_generation + 1
end

function Completion:reset()
  self:invalidate()
  self.menus:close(native_menu_id)
  self.menus:close(command_line_menu_id)
  self.menus:close(blink_menu_id)
end

function Completion:close_native()
  self.menus:close(native_menu_id)
end

function Completion:close_command_line()
  self.menus:close(command_line_menu_id)
end

function Completion:refresh_native()
  if not self.enabled() or not self.options().announce_completions then
    self:close_native()
    return
  end
  local ok, info = pcall(vim.fn.complete_info, { "pum_visible", "items", "selected" })
  if not ok
    or type(info) ~= "table"
    or tonumber(info.pum_visible) ~= 1
    or type(info.items) ~= "table"
  then
    self:close_native()
    return
  end

  local selected = tonumber(info.selected)
  local index = selected and selected >= 0 and selected + 1 or nil
  local item = index and info.items[index] or nil
  self.menus:update({
    id = native_menu_id,
    name = "completion menu",
    count = #info.items,
    index = index,
    label = native_item_label(item),
    kind = item and item.kind,
    source = item and item.menu,
    documentation = item and item.info,
  })
end

function Completion:refresh_command_line()
  if not self.enabled()
    or not self.options().announce_completions
    or vim.fn.exists("*cmdcomplete_info") ~= 1
  then
    self.menus:close(command_line_menu_id)
    return
  end
  local ok, info = pcall(vim.fn.cmdcomplete_info)
  if not ok
    or type(info) ~= "table"
    or tonumber(info.pum_visible) ~= 1
    or type(info.matches) ~= "table"
  then
    self.menus:close(command_line_menu_id)
    return
  end

  local selected = tonumber(info.selected)
  local index = selected and selected >= 0 and selected + 1 or nil
  self.menus:update({
    id = command_line_menu_id,
    name = "command completion menu",
    count = #info.matches,
    index = index,
    label = index and info.matches[index] or nil,
  })
end

function Completion:refresh_blink()
  if not self.enabled()
    or not self.blink_menu_open
    or not self.options().announce_completions
  then
    return
  end
  local ok, visible, items, index, item = pcall(function()
    local blink = require("blink.cmp")
    return blink.is_menu_visible(), blink.get_items(), blink.get_selected_item_idx(),
      blink.get_selected_item()
  end)
  if not ok or not visible or type(items) ~= "table" then
    return
  end
  index = tonumber(index)
  if not index or index < 1 or index > #items then
    index = nil
    item = nil
  end
  local kind = item and item.kind_name
  if not kind or kind == "" then
    kind = item and item.kind
  end
  local source = item and item.source_name
  if type(source) ~= "string" or source == "" then
    source = item and item.source_id
  end
  if type(source) == "string" and source:lower():find("cmdline", 1, true) then
    kind = nil
    source = nil
  end
  self.menus:update({
    id = blink_menu_id,
    name = "completion menu",
    count = #items,
    index = index,
    label = blink_item_label(item),
    kind = kind,
    source = source,
    documentation = blink_documentation(item),
  })
end

function Completion:schedule_blink_refresh()
  if not self.enabled()
    or not self.blink_menu_open
    or not self.options().announce_completions
  then
    return
  end
  self.blink_refresh_generation = self.blink_refresh_generation + 1
  local generation = self.blink_refresh_generation
  for _, delay in ipairs({ 0, 20, 100, 250 }) do
    self.defer(function()
      if self.enabled()
        and self.blink_menu_open
        and generation == self.blink_refresh_generation
      then
        self:refresh_blink()
      end
    end, delay)
  end
end

function Completion:open_blink()
  self.blink_menu_open = true
  self.menus:close(native_menu_id)
  self.menus:close(command_line_menu_id)
  self:schedule_blink_refresh()
end

function Completion:close_blink()
  self.blink_menu_open = false
  self.blink_refresh_generation = self.blink_refresh_generation + 1
  self.menus:close(blink_menu_id)
end

function Completion:schedule_blink_event_refresh()
  local lifecycle_generation = self.lifecycle_generation()
  vim.schedule(function()
    if self.lifecycle_is_current(lifecycle_generation) and self.blink_menu_open then
      self:refresh_blink()
    end
  end)
end

function Completion:refresh_documentation(command_line_active)
  if self.blink_menu_open then
    self:refresh_blink()
  elseif command_line_active then
    self:refresh_command_line()
  else
    self:refresh_native()
  end
end

return M
