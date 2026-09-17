-- SPDX-License-Identifier: MIT

local protocol = require("lector.protocol")

local M = {}
local ContextMenu = {}
ContextMenu.__index = ContextMenu

local menu_id = "nvim-popup-menu"

local function popup_mode(event_mode)
  return event_mode == "tl" and "t" or event_mode
end

local function menu_component(name)
  return name:gsub("\\", "\\\\"):gsub("%.", "\\.")
end

local function menu_items(event_mode)
  local mode = popup_mode(event_mode)
  local ok, menus = pcall(vim.fn.menu_get, "PopUp", mode)
  if not ok or type(menus) ~= "table" or type(menus[1]) ~= "table" then
    return {}
  end
  local items = {}
  for _, item in ipairs(menus[1].submenus or {}) do
    local mappings = type(item.mappings) == "table" and item.mappings or {}
    local mapping = mappings[mode]
    local has_submenu = type(item.submenus) == "table" and #item.submenus > 0
    local name = protocol.normalize(item.name)
    if item.hidden ~= 1
      and name
      and not name:match("^%-%d+%-$")
      and (has_submenu or (type(mapping) == "table" and mapping.enabled == 1))
    then
      table.insert(items, {
        label = name,
        submenu = has_submenu,
        activation_path = not has_submenu
          and type(mapping) == "table"
          and mapping.enabled == 1
          and ("PopUp." .. menu_component(item.name))
          or nil,
      })
    end
  end
  return items
end

function M.new(dependencies)
  local down = vim.api.nvim_replace_termcodes("<Down>", true, false, true)
  local up = vim.api.nvim_replace_termcodes("<Up>", true, false, true)
  local enter_keys = {
    [vim.api.nvim_replace_termcodes("<CR>", true, false, true)] = true,
    [vim.api.nvim_replace_termcodes("<kEnter>", true, false, true)] = true,
  }
  local submenu_keys = vim.tbl_extend("force", {}, enter_keys)
  submenu_keys[vim.api.nvim_replace_termcodes("<Right>", true, false, true)] = true
  return setmetatable({
    activate = assert(dependencies.activate),
    deactivate = assert(dependencies.deactivate),
    enabled = assert(dependencies.enabled),
    enter_keys = enter_keys,
    input = assert(dependencies.input),
    menus = assert(dependencies.menus),
    navigation_keys = {
      [down] = 1,
      [up] = -1,
    },
    navigation_input = {
      [down] = "<Down>",
      [up] = "<Up>",
    },
    opposite_navigation_key = {
      [down] = up,
      [up] = down,
    },
    options = assert(dependencies.options),
    popup = nil,
    say = assert(dependencies.say),
    submenu_keys = submenu_keys,
    suppress_cursor = assert(dependencies.suppress_cursor),
    escape = vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
  }, ContextMenu)
end

function ContextMenu:queue_navigation(popup, key, count)
  if count < 1 then
    return 0
  end
  local input_key = self.navigation_input[key]
  local input = string.rep(input_key, count)
  local ok, written = pcall(self.input, input)
  if not ok or type(written) ~= "number" then
    return 0
  end
  local queued = math.min(count, math.floor(written / #input_key))
  if queued > 0 then
    popup.forwarded_navigation = {
      key = key,
      remaining = queued,
    }
  end
  return queued
end

function ContextMenu:reset()
  self.popup = nil
  self.menus:close(menu_id)
end

function ContextMenu:open(event)
  if not self.enabled() or not self.options().announce_popup_menus then
    return
  end
  local popup = {
    event_mode = event.match,
    index = nil,
    items = {},
  }
  self.popup = popup
  popup.items = menu_items(popup.event_mode)
  if #popup.items == 0 then
    self:reset()
    return
  end
  self.say("context menu")
  vim.schedule(function()
    if self.popup ~= popup then
      return
    end
    local activation_path = popup.activation_path
    self:reset()
    if activation_path then
      local ok, err = pcall(vim.api.nvim_cmd, {
        cmd = "emenu",
        args = { activation_path },
      }, {})
      if not ok then
        vim.notify(
          "Context-menu activation failed: " .. tostring(err),
          vim.log.levels.ERROR
        )
      end
    end
    self.activate()
  end)
end

function ContextMenu:handle_key(key)
  local popup = self.popup
  if not popup or popup.fallback then
    return false, false
  end
  local forwarded = popup.forwarded_navigation
  if forwarded and forwarded.key == key then
    forwarded.remaining = forwarded.remaining - 1
    if forwarded.remaining == 0 then
      popup.forwarded_navigation = nil
    end
    return true, false
  end
  local direction = self.navigation_keys[key]
  if direction and #popup.items > 0 then
    local previous_index = popup.index
    local consume = false
    -- Neovim clamps its native selection at either end.  When Lector wraps,
    -- walk the native selection back across the menu and keep those synthetic
    -- arrows from producing intermediate announcements.
    if not popup.index then
      if direction > 0 then
        popup.index = 1
      else
        local queued = self:queue_navigation(
          popup,
          self.opposite_navigation_key[key],
          #popup.items
        )
        if queued > 0 then
          popup.index = queued
          consume = true
        end
      end
    elseif direction < 0 and popup.index == 1 then
      local queued = self:queue_navigation(
        popup,
        self.opposite_navigation_key[key],
        #popup.items - 1
      )
      popup.index = popup.index + queued
      consume = queued > 0
    elseif direction > 0 and popup.index == #popup.items then
      local queued = self:queue_navigation(
        popup,
        self.opposite_navigation_key[key],
        #popup.items - 1
      )
      popup.index = popup.index - queued
      consume = queued > 0
    else
      popup.index = popup.index + direction
    end
    if popup.index ~= previous_index then
      self.menus:publish({
        id = menu_id,
        name = "context menu",
        count = #popup.items,
        index = popup.index,
        label = popup.items[popup.index].label
          .. (popup.items[popup.index].submenu and ", submenu" or ""),
      }, true)
    end
    if consume then
      return true, true
    end
  end
  if self.submenu_keys[key]
    and popup.index
    and popup.items[popup.index].submenu
  then
    popup.fallback = true
    self.menus:close(menu_id)
    self.deactivate()
    return true, false
  end
  if self.enter_keys[key] and popup.index then
    local activation_path = popup.items[popup.index].activation_path
    if activation_path then
      self.suppress_cursor(50)
      local ok, written = pcall(vim.api.nvim_input, self.escape)
      if ok and written == #self.escape then
        popup.activation_path = activation_path
        return true, true
      end
    end
  end
  return true, false
end

return M
