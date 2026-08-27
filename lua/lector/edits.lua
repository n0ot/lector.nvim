-- SPDX-License-Identifier: MIT

local protocol = require("lector.protocol")

local M = {}
local Edits = {}
Edits.__index = Edits

local function spoken_register_text(text)
  text = tostring(text or "")
  if text == "" then
    return "blank"
  end
  if text:match("^ +$") then
    return #text == 1 and "space" or (#text .. " spaces")
  end
  if text:match("^\t+$") then
    return #text == 1 and "tab" or (#text .. " tabs")
  end
  if text:match("^%s+$") then
    return "blank"
  end
  local characters = vim.fn.strchars(text, true)
  if characters > 160 then
    return characters .. " characters"
  end
  return protocol.normalize(text) or "blank"
end

local function edit_announcement(verb, contents, regtype)
  contents = type(contents) == "table" and contents or {}
  regtype = type(regtype) == "string" and regtype or "v"
  local kind = regtype:sub(1, 1)
  local count = #contents
  if kind == "V" then
    return verb .. " " .. count .. (count == 1 and " line" or " lines")
  end
  if kind == "\22" then
    return verb .. " block, " .. count .. (count == 1 and " line" or " lines")
  end
  if count > 1 then
    return verb .. " text across " .. count .. " lines"
  end
  return verb .. " " .. spoken_register_text(contents[1])
end

local function structured_event_data(event)
  if event and type(event.data) == "table" and event.data.operator then
    return event.data
  end
  return vim.v.event
end

function M.new(dependencies)
  local self = setmetatable({
    activate = assert(dependencies.activate),
    changed_region_matches_register = assert(dependencies.changed_region_matches_register),
    changedtick = assert(dependencies.changedtick),
    character_at_cursor = assert(dependencies.character_at_cursor),
    command_line_active = assert(dependencies.command_line_active),
    current_register = assert(dependencies.current_register),
    edit_destination_ticks = {},
    lifecycle_generation = assert(dependencies.lifecycle_generation),
    lifecycle_is_current = assert(dependencies.lifecycle_is_current),
    line_change = assert(dependencies.line_change),
    menu_is_open = assert(dependencies.menu_is_open),
    numeric_value_at_or_after = assert(dependencies.numeric_value_at_or_after),
    options = assert(dependencies.options),
    pending_input = nil,
    pending_structured_edit = nil,
    put_announcement_ticks = {},
    remember = assert(dependencies.remember),
    remember_text = assert(dependencies.remember_text),
    send_line = assert(dependencies.send_line),
    send_speech = assert(dependencies.send_speech),
    snapshot = assert(dependencies.snapshot),
    spoken_line = assert(dependencies.spoken_line),
    structured_edit_ticks = {},
    suppress_edit_cursor = false,
    suppress_visual_delete_mode_return = nil,
    text_windows = assert(dependencies.text_windows),
    word_at_or_after = assert(dependencies.word_at_or_after),
  }, Edits)
  return self
end

function Edits:reset()
  self.pending_input = nil
  self.pending_structured_edit = nil
  self.structured_edit_ticks = {}
  self.edit_destination_ticks = {}
  self.put_announcement_ticks = {}
  self.suppress_edit_cursor = false
  self.suppress_visual_delete_mode_return = nil
end

function Edits:consume_cursor_suppression()
  if not self.suppress_edit_cursor then
    return false
  end
  self.suppress_edit_cursor = false
  return true
end

function Edits:consume_visual_mode_return(left_visual, mode_kind)
  if self.suppress_visual_delete_mode_return and left_visual and mode_kind == "n" then
    self.suppress_visual_delete_mode_return = nil
    return true
  end
  return false
end

function Edits:mark_structured(buffer)
  local tick = self.changedtick(buffer)
  if tick then
    self.structured_edit_ticks[buffer] = tick
  end
end

function Edits:input_before_change(buffer)
  local input = self.pending_input
  local previous = input and input.snapshot or nil
  if previous and previous.buffer == buffer then
    return previous, input
  end
  local previous_text = self.text_windows()[vim.api.nvim_get_current_win()]
  if previous_text and previous_text.buffer == buffer then
    return previous_text, nil
  end
  return nil, input
end

function Edits:destination_from_effect(data, previous, current)
  local regtype = tostring(data and data.regtype or ""):sub(1, 1)
  if regtype == "V" or regtype == "\22" then
    return "line"
  end
  if data and data.visual then
    return "character"
  end
  if previous
    and current
    and previous.buffer == current.buffer
    and (previous.row ~= current.row or previous.line_count ~= current.line_count)
  then
    return "line"
  end
  local contents = data and data.regcontents or {}
  local deleted = type(contents) == "table" and table.concat(contents, "\n") or ""
  if previous
    and current
    and previous.row == current.row
    and previous.column == current.column
    and current.word
    and vim.fn.strchars(deleted, true) > 1
  then
    return "word"
  end
  return "character"
end

function Edits:schedule_destination(buffer, destination_kind, previous)
  if not self.options().announce_deletions then
    self.suppress_edit_cursor = false
    return
  end
  local tick = self.changedtick(buffer)
  if not tick or self.edit_destination_ticks[buffer] == tick then
    return
  end
  self.edit_destination_ticks[buffer] = tick
  local lifecycle_generation = self.lifecycle_generation()
  vim.schedule(function()
    if not self.lifecycle_is_current(lifecycle_generation) then
      return
    end
    local current = self.snapshot()
    if not current or current.buffer ~= buffer then
      return
    end
    self.activate()
    local moved_lines = previous
      and previous.buffer == current.buffer
      and (previous.row ~= current.row or previous.line_count ~= current.line_count)
    if destination_kind == "line" or moved_lines then
      self.send_line(self.spoken_line(current), current.indentation)
    elseif destination_kind == "word" then
      local word = self.word_at_or_after(current.line, current.column)
      self.send_speech(word or self.character_at_cursor(current))
    else
      self.send_speech(self.character_at_cursor(current))
    end
    self.suppress_edit_cursor = false
    self.remember(current)
    self.remember_text(current)
  end)
end

function Edits:announce_operator(event)
  local data = structured_event_data(event)
  local operator = data and data.operator
  if operator ~= "d" and operator ~= "c" then
    return
  end
  local buffer = event.buf or vim.api.nvim_get_current_buf()
  local previous = self:input_before_change(buffer)
  local current = self.snapshot()
  self.suppress_edit_cursor = true
  self:mark_structured(buffer)
  local pending = {
    buffer = buffer,
    destination_kind = self:destination_from_effect(data, previous, current),
    previous = previous,
  }
  self.pending_structured_edit = pending
  local regtype = tostring(data.regtype or ""):sub(1, 1)
  if regtype ~= "V" and regtype ~= "\22" and data.visual then
    if operator == "d" and self.options().announce_deletions then
      local suppression = {}
      self.suppress_visual_delete_mode_return = suppression
      vim.schedule(function()
        if self.suppress_visual_delete_mode_return == suppression then
          self.suppress_visual_delete_mode_return = nil
        end
      end)
    end
  end
  vim.schedule(function()
    if self.pending_structured_edit == pending then
      self.pending_structured_edit = nil
      self:schedule_destination(buffer, pending.destination_kind, previous)
    end
  end)
  self.remember_text(current)
end

function Edits:announce_put(data, buffer)
  self:mark_structured(buffer)
  self.pending_structured_edit = nil
  self.pending_input = nil
  local tick = self.changedtick(buffer)
  local already_announced = tick and self.put_announcement_ticks[buffer] == tick
  if tick then
    self.put_announcement_ticks[buffer] = tick
  end
  if self.options().announce_puts and not self.menu_is_open() and not already_announced then
    self.activate()
    self.send_speech(edit_announcement("pasted", data.regcontents, data.regtype))
  end
  local current = self.snapshot()
  self.suppress_edit_cursor = false
  self.remember(current)
  self.remember_text(current)
end

function Edits:announce_put_event(event)
  local data = structured_event_data(event)
  if not data or (data.operator ~= "p" and data.operator ~= "P") then
    return
  end
  self:announce_put(data, event.buf or vim.api.nvim_get_current_buf())
end

function Edits:changed_value_at_cursor(current)
  return self.numeric_value_at_or_after(current.line, current.column)
    or self.character_at_cursor(current)
end

function Edits:history_replay(input)
  if not input or type(input.undo) ~= "table" then
    return false
  end
  local ok, current = pcall(vim.fn.undotree)
  if not ok or type(current) ~= "table" then
    return false
  end
  return current.seq_last == input.undo.seq_last
    and current.seq_cur ~= input.undo.seq_cur
end

function Edits:unstructured_destination(previous, current, removed)
  if previous
    and (previous.row ~= current.row or previous.line_count ~= current.line_count)
  then
    return "line"
  end
  if previous
    and previous.column == current.column
    and current.word
    and vim.fn.strchars(removed, true) > 1
  then
    return "word"
  end
  return "character"
end

function Edits:suppress_related_cursor_event()
  self.suppress_edit_cursor = true
  vim.schedule(function()
    vim.schedule(function()
      if self.suppress_edit_cursor == true then
        self.suppress_edit_cursor = false
      end
    end)
  end)
end

function Edits:announce_text_change(event)
  self.activate()
  local current = self.snapshot()
  if not current then
    return
  end
  local previous, input = self:input_before_change(current.buffer)
  local effect, removed = self.line_change(previous, current)
  local current_tick = self.changedtick(current.buffer)
  local structured = current_tick
    and self.structured_edit_ticks[current.buffer] == current_tick
  if structured then
    self.structured_edit_ticks[current.buffer] = nil
  end
  if self.menu_is_open() and effect ~= "deletion" then
    self:suppress_related_cursor_event()
    self.remember(current)
    self.remember_text(current)
    if self.pending_input == input then
      self.pending_input = nil
    end
    return
  end
  local is_put = event
    and event.event == "TextChanged"
    and not self:history_replay(input)
    and effect ~= "deletion"
    and self.changed_region_matches_register(input)
  if is_put then
    if self.pending_input == input then
      self.pending_input = nil
    end
    self:announce_put(input.register, current.buffer)
    return
  end
  if structured then
    self:suppress_related_cursor_event()
  elseif self:history_replay(input) then
    self.pending_structured_edit = nil
    self:suppress_related_cursor_event()
  elseif effect == "deletion" and self.options().announce_deletions then
    self:suppress_related_cursor_event()
    self:schedule_destination(
      current.buffer,
      self:unstructured_destination(previous, current, removed),
      previous
    )
  elseif event
    and event.event == "TextChanged"
    and previous
    and previous.row == current.row
    and self.options().announce_value_changes
  then
    local before = self.numeric_value_at_or_after(previous.line, previous.column)
    local after = self.numeric_value_at_or_after(current.line, current.column)
    if before and after and before ~= after then
      self.send_speech(self:changed_value_at_cursor(current))
    end
    self:suppress_related_cursor_event()
  else
    self:suppress_related_cursor_event()
  end
  self.remember(current)
  self.remember_text(current)
  if self.pending_input == input then
    self.pending_input = nil
  end
end

function Edits:observe_input_state()
  if self.command_line_active() then
    self.pending_input = nil
    return
  end
  local current = self.snapshot()
  if not current then
    self.pending_input = nil
    return
  end
  local ok_undo, undo = pcall(vim.fn.undotree)
  local input = {
    snapshot = current,
    changedtick = self.changedtick(current.buffer),
    register = self.current_register(),
    undo = ok_undo and undo or nil,
  }
  self.pending_input = input
  vim.schedule(function()
    if self.pending_input == input then
      local tick = self.changedtick(current.buffer)
      if tick and input.changedtick and tick ~= input.changedtick then
        local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
        self:announce_text_change({
          event = (mode == "i" or mode == "R") and "TextChangedI" or "TextChanged",
        })
      end
      if self.pending_input == input then
        self.pending_input = nil
      end
    end
  end)
end

return M
