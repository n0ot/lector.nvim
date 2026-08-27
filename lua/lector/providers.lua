-- SPDX-License-Identifier: MIT

local unpack_values = unpack or table.unpack

local M = {}
local Providers = {}
Providers.__index = Providers

local function pack_values(...)
  return { n = select("#", ...), ... }
end

function M.new(dependencies)
  return setmetatable({
    activate = assert(dependencies.activate),
    changedtick = assert(dependencies.changedtick),
    command_line_active = assert(dependencies.command_line_active),
    enabled = assert(dependencies.enabled),
    lifecycle_generation = assert(dependencies.lifecycle_generation),
    lifecycle_is_current = assert(dependencies.lifecycle_is_current),
    menu_is_open = assert(dependencies.menu_is_open),
    observes_editor_state = assert(dependencies.observes_editor_state),
    options = assert(dependencies.options),
    pending_navigation = nil,
    say = assert(dependencies.say),
    search_announcement_generation = 0,
    search_wrapped = false,
    send_speech = assert(dependencies.send_speech),
    set_cursor_suppression = assert(dependencies.set_cursor_suppression),
    snapshot = assert(dependencies.snapshot),
    speech_generation = assert(dependencies.speech_generation),
    last_search_destination = nil,
  }, Providers)
end

function Providers:reset()
  self.pending_navigation = nil
  self.search_announcement_generation = self.search_announcement_generation + 1
  self.search_wrapped = false
  self.last_search_destination = nil
end

function Providers:clear_navigation()
  self.pending_navigation = nil
end

function Providers:cursor_navigation(current)
  local navigation = self.pending_navigation
  if navigation
    and navigation.snapshot
    and current
    and current.window == navigation.snapshot.window
    and current.buffer == navigation.snapshot.buffer
    and current.row == navigation.snapshot.row
    and current.column == navigation.snapshot.column
    and self.changedtick(current.buffer) == navigation.changedtick
  then
    return navigation
  end
  self.pending_navigation = nil
  return nil
end

function Providers:refresh_navigation(navigation)
  if navigation and self.pending_navigation == navigation then
    navigation.speech_generation = self.speech_generation()
  end
end

function Providers:schedule_failed_navigation(navigation)
  local lifecycle_generation = self.lifecycle_generation()
  vim.schedule(function()
    vim.schedule(function()
      if not self.lifecycle_is_current(lifecycle_generation)
        or self.pending_navigation ~= navigation
      then
        return
      end
      self.pending_navigation = nil
      if not self.enabled()
        or not self.options().announce_cursor
        or self.command_line_active()
        or self.menu_is_open()
        or navigation.speech_generation ~= self.speech_generation()
        or not self.observes_editor_state()
      then
        return
      end
      local current = self.snapshot()
      local previous = navigation.snapshot
      if not current
        or not previous
        or current.window ~= previous.window
        or current.buffer ~= previous.buffer
        or current.row ~= previous.row
        or current.column ~= previous.column
        or self.changedtick(current.buffer) ~= navigation.changedtick
      then
        return
      end
      self.say("no " .. navigation.direction .. " item")
    end)
  end)
end

function Providers:observe_navigation(direction, action, ...)
  if direction ~= "previous" and direction ~= "next" then
    error("direction must be 'previous' or 'next'", 2)
  end
  if type(action) ~= "function" then
    error("action must be a function", 2)
  end
  if not self.enabled() or not self.options().announce_cursor then
    return action(...)
  end

  local current = self.snapshot()
  local navigation = current and {
    direction = direction,
    snapshot = current,
    changedtick = self.changedtick(current.buffer),
    speech_generation = self.speech_generation(),
  } or nil
  self.pending_navigation = navigation

  local results = pack_values(pcall(action, ...))
  if not results[1] then
    if self.pending_navigation == navigation then
      self.pending_navigation = nil
    end
    error(results[2], 0)
  end
  if navigation then
    self:schedule_failed_navigation(navigation)
  end
  return unpack_values(results, 2, results.n)
end

function Providers:search_info(current, require_exact)
  if not current then
    return nil
  end
  local pattern = vim.fn.getreg("/")
  if type(pattern) ~= "string" or pattern == "" then
    return nil
  end
  local ok, count = pcall(vim.fn.searchcount, {
    recompute = 1,
    maxcount = 100000,
    timeout = 50,
  })
  if not ok or type(count) ~= "table" then
    return nil
  end
  local index = tonumber(count.current) or 0
  local total = tonumber(count.total) or 0
  if index < 1
    or total < 1
    or (require_exact and tonumber(count.exact_match) ~= 1)
  then
    return nil
  end
  return {
    count = count,
    index = index,
    total = total,
    key = table.concat({ pattern, current.buffer, index, total }, "\0"),
  }
end

function Providers:schedule_search_destination(current, require_exact)
  if not self.enabled() or not self.options().announce_search then
    self.search_wrapped = false
    self.last_search_destination = nil
    return false
  end
  require_exact = require_exact ~= false
  local initial = self:search_info(current, require_exact)
  if not initial then
    if require_exact then
      self.last_search_destination = nil
    end
    return false
  end
  self.search_announcement_generation = self.search_announcement_generation + 1
  local generation = self.search_announcement_generation
  vim.schedule(function()
    if not self.enabled() or generation ~= self.search_announcement_generation then
      return
    end
    local wrapped = self.search_wrapped
    self.search_wrapped = false
    local latest = self:search_info(self.snapshot(), require_exact)
    if not latest then
      return
    end
    if latest.key == self.last_search_destination and not wrapped then
      return
    end
    self.last_search_destination = latest.key
    self.activate()
    local announcement = latest.index .. " of " .. latest.total
    if tonumber(latest.count.incomplete) and tonumber(latest.count.incomplete) ~= 0 then
      announcement = announcement .. ", count incomplete"
    end
    if wrapped then
      announcement = announcement .. ", wrapped"
    end
    self.send_speech(announcement)
  end)
  return true
end

function Providers:schedule_search_announcement()
  local lifecycle_generation = self.lifecycle_generation()
  vim.schedule(function()
    if self.lifecycle_is_current(lifecycle_generation) then
      self:schedule_search_destination(self.snapshot(), false)
    end
  end)
  return true
end

function Providers:suppress_cursor()
  local suppression = {}
  self.set_cursor_suppression(suppression)
  vim.schedule(function()
    vim.schedule(function()
      self.set_cursor_suppression(nil, suppression)
    end)
  end)
end

function Providers:observe_search(action, ...)
  if type(action) ~= "function" then
    error("action must be a function", 2)
  end
  local suppression = {}
  self.set_cursor_suppression(suppression)
  local results = pack_values(pcall(action, ...))
  if not results[1] then
    self.set_cursor_suppression(nil, suppression)
    error(results[2], 0)
  end
  self:schedule_search_announcement()
  vim.schedule(function()
    vim.schedule(function()
      self.set_cursor_suppression(nil, suppression)
    end)
  end)
  return unpack_values(results, 2, results.n)
end

function Providers:announce_search_wrapped()
  self.search_wrapped = true
  self:schedule_search_announcement()
end

return M
