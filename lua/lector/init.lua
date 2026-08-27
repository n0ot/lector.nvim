-- SPDX-License-Identifier: MIT

local M = {}
local completion_module = require("lector.completion")
local context_menu_module = require("lector.context_menu")
local edits_module = require("lector.edits")
local editor = require("lector.editor")
local menus_module = require("lector.menus")
local protocol = require("lector.protocol")
local completion
local edits
local providers_module = require("lector.providers")
local providers

local character_at_cursor = editor.character_at_cursor
local character_distance = editor.character_distance
local changedtick = editor.changedtick
local fold_line_count = editor.fold_line_count
local normalize_speech = protocol.normalize
local snapshot = editor.snapshot
local spoken_character = editor.spoken_character
local spoken_deletion = editor.spoken_deletion
local spoken_line = editor.spoken_line
local visual_selection_summary = editor.visual_selection_summary
local word_at = editor.word_at
local word_at_or_after = editor.word_at_or_after
local floating_window_scan_interval_ms = 50
local floating_window_scan_duration_ms = 1000
local group_name = "LectorApplicationAccessibility"
local instance_registry = debug.getregistry()
local instance_registry_key = "lector.nvim.active_instance"
local user_command_names = {
  "LectorSay",
  "LectorAccessibilityEnable",
  "LectorAccessibilityDisable",
  "LectorCompletionDocumentation",
  "LectorStatus",
}

local state = {
  enabled = false,
  active = false,
  options = {},
  windows = {},
  text_windows = {},
  known_windows = {},
  command_lines = {},
  command_line_active = false,
  command_line_level = 0,
  pending_insert_diagnostics = {},
  suppress_next_cursor = nil,
  last_mode = nil,
  last_buffer_announcement = nil,
  terminal_fallback = false,
  terminal_command_line = false,
  command_output_fallback = false,
  discard_pending_messages = false,
  suppress_prompt_mode_return = nil,
  last_spelling = nil,
  diagnostic_announcements = {},
  recent_list_destination = nil,
  list_selections = {},
  fold_observation_generation = 0,
  input_namespace = nil,
  message_history = nil,
  message_poll_scheduled = false,
  buffer_announcement_generation = 0,
  cursor_announcement_generation = 0,
  window_scan_generation = 0,
  speech_generation = 0,
  closed_announcement_generation = 0,
  lifecycle_generation = 0,
  deferred_timers = {},
}

local defaults = {
  announce_buffers = true,
  announce_cursor = true,
  announce_deletions = true,
  announce_diagnostics = true,
  announce_modes = true,
  announce_messages = true,
  announce_floating_windows = true,
  announce_command_line = true,
  announce_value_changes = true,
  announce_puts = true,
  announce_folds = true,
  announce_search = true,
  announce_quickfix = true,
  announce_recording = true,
  announce_spelling = true,
  announce_completions = true,
  announce_popup_menus = true,
  completion_include_kind = true,
  completion_include_source = true,
  completion_include_position = true,
}

local menus = menus_module.new({
  enabled = function() return state.enabled end,
  options = function() return state.options end,
  say = function(text) return M.say(text) end,
})

local function send_speech(text)
  if not state.active then
    return false
  end
  local sent = protocol.say(text)
  if sent then
    state.speech_generation = state.speech_generation + 1
  end
  return sent
end

local function send_line(text, indentation)
  if not state.active then
    return false
  end
  local sent = protocol.line(text, indentation)
  if sent then
    state.speech_generation = state.speech_generation + 1
  end
  return sent
end

function M.activate()
  if not state.enabled then
    return false
  end
  state.command_output_fallback = false
  local ok, buftype = pcall(vim.api.nvim_get_option_value, "buftype", {
    buf = vim.api.nvim_get_current_buf(),
  })
  if ok and buftype == "terminal" then
    if state.terminal_command_line then
      if state.active then
        return true
      end
      local sent = protocol.send("set;auto=0;cursor=0")
      state.active = sent
      return sent
    end
    if not state.terminal_fallback then
      state.terminal_fallback = true
      state.last_buffer_announcement = nil
    end
    M.deactivate()
    return false
  end
  state.terminal_fallback = false
  if state.active then
    return true
  end
  local sent = protocol.send("set;auto=0;cursor=0")
  state.active = sent
  return sent
end

function M.deactivate()
  if state.active then
    protocol.send("end")
  end
  state.active = false
end

function M.say(text)
  if not M.activate() then
    return false
  end
  return send_speech(text)
end

local function lifecycle_is_current(generation)
  return state.enabled and generation == state.lifecycle_generation
end

local function cancel_deferred_timers()
  for timer in pairs(state.deferred_timers) do
    pcall(timer.stop, timer)
    local ok, closing = pcall(timer.is_closing, timer)
    if not ok or not closing then
      pcall(timer.close, timer)
    end
  end
  state.deferred_timers = {}
end

local function defer_tracked(callback, timeout)
  local timer
  timer = vim.defer_fn(function()
    state.deferred_timers[timer] = nil
    callback()
  end, timeout)
  state.deferred_timers[timer] = true
  return timer
end

local function schedule_closed_announcement()
  if not state.enabled then
    return
  end
  state.closed_announcement_generation = state.closed_announcement_generation + 1
  local generation = state.closed_announcement_generation
  local lifecycle_generation = state.lifecycle_generation
  local speech_generation = state.speech_generation
  -- Give announcements caused by the close, including a scheduled buffer
  -- announcement, a complete event-loop turn to run first.
  vim.schedule(function()
    vim.schedule(function()
      if lifecycle_is_current(lifecycle_generation)
        and generation == state.closed_announcement_generation
        and speech_generation == state.speech_generation
      then
        M.say("closed")
      end
    end)
  end)
end

local context_menu = context_menu_module.new({
  activate = function() return M.activate() end,
  deactivate = function() return M.deactivate() end,
  enabled = function() return state.enabled end,
  menus = menus,
  options = function() return state.options end,
  say = function(text) return M.say(text) end,
  schedule_closed = schedule_closed_announcement,
  suppress_cursor = function(timeout)
    local suppression = {}
    state.suppress_next_cursor = suppression
    defer_tracked(function()
      if state.suppress_next_cursor == suppression then
        state.suppress_next_cursor = nil
      end
    end, timeout)
  end,
})

completion = completion_module.new({
  defer = defer_tracked,
  enabled = function() return state.enabled end,
  lifecycle_generation = function() return state.lifecycle_generation end,
  lifecycle_is_current = lifecycle_is_current,
  menus = menus,
  options = function() return state.options end,
})

local function menu_is_open()
  return menus:is_open()
end

function M.update_menu(menu)
  return menus:update(menu)
end

function M.close_menu(id)
  return menus:close(id)
end

function M.read_menu_documentation(id)
  return menus:read_documentation(id)
end

local function close_all_menus()
  context_menu:reset()
  completion:reset()
  menus:reset()
end

local function remember(current)
  if current then
    state.windows[current.window] = current
  end
end

local function remember_text(current)
  if current then
    state.text_windows[current.window] = current
  end
end

edits = edits_module.new({
  activate = function() return M.activate() end,
  changed_region_matches_register = editor.changed_region_matches_register,
  changedtick = changedtick,
  character_at_cursor = character_at_cursor,
  command_line_active = function() return state.command_line_active end,
  current_register = editor.current_register,
  lifecycle_generation = function() return state.lifecycle_generation end,
  lifecycle_is_current = lifecycle_is_current,
  line_change = editor.line_change,
  menu_is_open = menu_is_open,
  numeric_value_at_or_after = editor.numeric_value_at_or_after,
  options = function() return state.options end,
  remember = remember,
  remember_text = remember_text,
  send_line = send_line,
  send_speech = send_speech,
  snapshot = snapshot,
  spoken_deletion = spoken_deletion,
  spoken_line = spoken_line,
  text_windows = function() return state.text_windows end,
  word_at_or_after = word_at_or_after,
})

local function announce_closed_fold(current)
  if not state.options.announce_folds then
    return
  end
  local count = fold_line_count(current)
  if count then
    send_speech("folded, " .. count .. (count == 1 and " line" or " lines"))
  end
end

local function spell_error_at_cursor(current)
  if not state.options.announce_spelling then
    return nil
  end
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode == "i" or mode == "R" or mode == "c" or mode == "t" then
    return nil
  end
  local ok_spell, spell = pcall(vim.api.nvim_get_option_value, "spell", {
    win = current.window,
  })
  if not ok_spell or not spell then
    return nil
  end

  local view = vim.fn.winsaveview()
  local ok, result = pcall(vim.fn.spellbadword)
  local found_cursor = vim.api.nvim_win_get_cursor(current.window)
  pcall(vim.fn.winrestview, view)
  if not ok or type(result) ~= "table" or type(result[1]) ~= "string" then
    return nil
  end
  local word = result[1]
  local kind = result[2]
  if word == "" or found_cursor[1] ~= current.row then
    return nil
  end
  local start_column = found_cursor[2]
  if current.column < start_column or current.column >= start_column + #word then
    return nil
  end
  return {
    key = table.concat(
      { current.window, current.buffer, current.row, start_column, word, kind },
      "\0"
    ),
    word = word,
    kind = kind,
  }
end

local function announce_spelling(current, spelling)
  spelling = spelling or spell_error_at_cursor(current)
  if not spelling then
    state.last_spelling = nil
    return false
  end
  if state.last_spelling == spelling.key then
    return false
  end
  state.last_spelling = spelling.key
  local labels = {
    bad = "misspelled",
    caps = "capitalization",
    rare = "rare word",
    ["local"] = "regional spelling",
  }
  send_speech((labels[spelling.kind] or "spelling") .. ", " .. spelling.word)
  return true
end

local function get_list_info(kind)
  local what = {
    id = 0,
    idx = 0,
    size = 0,
    items = 0,
    title = 0,
    changedtick = 0,
  }
  local ok, info
  if kind == "location" then
    ok, info = pcall(vim.fn.getloclist, 0, what)
  else
    ok, info = pcall(vim.fn.getqflist, what)
  end
  if not ok or type(info) ~= "table" or tonumber(info.id) == 0 then
    return nil
  end
  return info
end

local function list_entry_announcement(info, index)
  local items = info and info.items
  local item = type(items) == "table" and items[index] or nil
  if type(item) ~= "table" then
    return nil
  end
  local parts = {}
  local types = {
    E = "error",
    W = "warning",
    I = "information",
    N = "note",
  }
  local item_type = types[item.type]
  if item_type then
    table.insert(parts, item_type)
  end
  local text = normalize_speech(item.text)
  if text then
    table.insert(parts, text)
  end
  local buffer = tonumber(item.bufnr) or 0
  if buffer > 0 and vim.api.nvim_buf_is_valid(buffer) then
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" then
      table.insert(parts, vim.fn.fnamemodify(name, ":t"))
    end
  end
  local line = tonumber(item.lnum) or 0
  if line > 0 then
    table.insert(parts, "line " .. line)
  end
  local size = tonumber(info.size) or #items
  table.insert(parts, index .. " of " .. size)
  return table.concat(parts, ", "), item
end

local function current_list_window_kind(current)
  local ok_filetype, filetype = pcall(vim.api.nvim_get_option_value, "filetype", {
    buf = current.buffer,
  })
  if not ok_filetype or filetype ~= "qf" then
    return nil
  end
  local ok, info = pcall(vim.fn.getwininfo, current.window)
  local window_info = ok and type(info) == "table" and info[1] or nil
  return window_info and window_info.loclist == 1 and "location" or "quickfix"
end

local function announce_list_window_entry(current)
  if not state.options.announce_quickfix then
    return false
  end
  local kind = current_list_window_kind(current)
  if not kind then
    return false
  end
  local info = get_list_info(kind)
  local announcement = info and list_entry_announcement(info, current.row) or nil
  if not announcement then
    return false
  end
  send_speech(announcement)
  return true
end

local function list_item_matches_current(item, current)
  if type(item) ~= "table" then
    return false
  end
  local buffer = tonumber(item.bufnr) or 0
  local line = tonumber(item.lnum) or 0
  return buffer == current.buffer and (line == 0 or line == current.row)
end

local function announce_selected_list_destination(current)
  if not state.options.announce_quickfix or current_list_window_kind(current) then
    return false
  end
  for _, kind in ipairs({ "location", "quickfix" }) do
    local info = get_list_info(kind)
    local index = info and tonumber(info.idx) or 0
    local item = info and type(info.items) == "table" and info.items[index] or nil
    if index > 0 and list_item_matches_current(item, current) then
      local scope = kind == "location" and (kind .. ":" .. current.window) or kind
      local signature = table.concat({
        info.id or 0,
        info.changedtick or 0,
        index,
      }, ":")
      if state.list_selections[scope] ~= signature then
        state.list_selections[scope] = signature
        local announcement = list_entry_announcement(info, index)
        if announcement then
          local recent = {
            window = current.window,
            buffer = current.buffer,
            row = current.row,
          }
          state.recent_list_destination = recent
          vim.schedule(function()
            if state.recent_list_destination == recent then
              state.recent_list_destination = nil
            end
          end)
          state.discard_pending_messages = true
          send_speech(announcement)
          return true
        end
      end
    end
  end
  return false
end

local function is_recent_list_destination(current)
  local recent = state.recent_list_destination
  return recent
    and recent.window == current.window
    and recent.buffer == current.buffer
    and recent.row == current.row
end

local function schedule_fold_observation()
  if not state.options.announce_folds then
    return
  end
  state.fold_observation_generation = state.fold_observation_generation + 1
  local generation = state.fold_observation_generation
  vim.schedule(function()
    if not state.enabled or generation ~= state.fold_observation_generation then
      return
    end
    local current = snapshot()
    if not current then
      return
    end
    local previous = state.windows[current.window]
    if not previous or previous.buffer ~= current.buffer or previous.row ~= current.row then
      return
    end
    if previous.fold_start == current.fold_start and previous.fold_end == current.fold_end then
      return
    end
    M.activate()
    if current.fold_start >= 0 then
      local count = fold_line_count(current)
      send_speech("fold closed, " .. count .. (count == 1 and " line" or " lines"))
    elseif previous.fold_start >= 0 then
      send_speech("fold opened")
    end
    remember(current)
  end)
end

function M.announce_status()
  if not M.activate() then
    return false
  end
  local current = snapshot()
  if not current then
    return false
  end
  local name = vim.api.nvim_buf_get_name(current.buffer)
  name = name == "" and "unnamed buffer" or vim.fn.fnamemodify(name, ":t")
  local parts = { name }
  local function option(name_, scope)
    local ok, value = pcall(vim.api.nvim_get_option_value, name_, scope)
    return ok and value or nil
  end
  if option("modified", { buf = current.buffer }) then
    table.insert(parts, "modified")
  end
  if option("readonly", { buf = current.buffer }) then
    table.insert(parts, "read only")
  elseif option("modifiable", { buf = current.buffer }) == false then
    table.insert(parts, "not modifiable")
  end
  table.insert(parts, "line " .. current.row .. " of " .. current.line_count)
  local prefix = current.line:sub(1, current.column)
  table.insert(parts, "column " .. (vim.fn.strchars(prefix, true) + 1))
  local fold_count = fold_line_count(current)
  if fold_count then
    table.insert(parts, "folded, " .. fold_count .. (fold_count == 1 and " line" or " lines"))
  end
  local selection = visual_selection_summary(current)
  if selection then
    table.insert(parts, selection)
  end
  return send_speech(table.concat(parts, ", "))
end

local function diagnostic_severity_name(severity)
  local name = vim.diagnostic.severity[severity]
  if type(name) ~= "string" then
    return "diagnostic"
  end
  name = name:lower()
  if name == "warn" then
    return "warning"
  end
  if name == "info" then
    return "information"
  end
  return name
end

local function diagnostic_on_line(current, diagnostics)
  diagnostics = diagnostics
    or vim.diagnostic.get(current.buffer, { lnum = current.row - 1 })
  local selected
  local count = 0
  for _, diagnostic in ipairs(diagnostics or {}) do
    if diagnostic.lnum == current.row - 1 then
      count = count + 1
      if not selected
        or (diagnostic.severity or math.huge) < (selected.severity or math.huge)
      then
        selected = diagnostic
      end
    end
  end
  return selected, count
end

local function announce_current_line_diagnostic(current, diagnostics)
  if not state.options.announce_diagnostics then
    return false
  end
  local diagnostic, count = diagnostic_on_line(current, diagnostics)
  if not diagnostic then
    state.diagnostic_announcements[current.window] = nil
    return false
  end
  local severity = diagnostic_severity_name(diagnostic.severity)
  local announcement = severity .. ", " .. diagnostic.message
  if count > 1 then
    announcement = announcement .. ", " .. (count - 1) .. " more"
  end
  local key = table.concat({ current.buffer, current.row, announcement }, "\0")
  if state.diagnostic_announcements[current.window] == key then
    return false
  end
  state.diagnostic_announcements[current.window] = key
  send_speech(announcement)
  return true
end

local function announce_cursor(event)
  M.activate()
  local current = snapshot()
  if not current then
    providers:clear_navigation()
    return
  end
  -- A coalesced CursorMoved can belong to an earlier action. The provider
  -- observer retains a newer unchanged navigation until its failure check.
  local deferred_navigation = providers:cursor_navigation(current)
  if state.suppress_next_cursor then
    state.suppress_next_cursor = nil
    remember(current)
    providers:refresh_navigation(deferred_navigation)
    return
  end
  if edits:consume_cursor_suppression(current) then
    remember(current)
    providers:refresh_navigation(deferred_navigation)
    return
  end
  if menu_is_open() then
    remember(current)
    providers:refresh_navigation(deferred_navigation)
    return
  end
  local announced_list_destination = announce_selected_list_destination(current)
  local spelling = spell_error_at_cursor(current)
  local new_spelling = spelling and state.last_spelling ~= spelling.key
  local previous = state.windows[current.window]
  local unchanged_buffer = previous
    and (previous.changedtick == nil
      or current.changedtick == nil
      or previous.changedtick == current.changedtick)
  if not announced_list_destination
    and state.options.announce_cursor
    and previous
    and previous.buffer == current.buffer
    and unchanged_buffer
  then
    if previous.row ~= current.row then
      if not announce_list_window_entry(current) then
        send_line(spoken_line(current), current.indentation)
      end
      announce_closed_fold(current)
      announce_current_line_diagnostic(current)
    elseif previous.column ~= current.column then
      if not new_spelling then
        local distance = character_distance(current.line, current.column, previous.column)
        if distance > 1 and current.word and current.word_start ~= previous.word_start then
          send_speech(current.word)
        else
          send_speech(character_at_cursor(current))
        end
      end
    end
  end
  if announced_list_destination then
    state.last_spelling = spelling and spelling.key or nil
  else
    announce_spelling(current, spelling)
  end
  remember(current)
  providers:refresh_navigation(deferred_navigation)
end

local function schedule_cursor_announcement(event)
  state.cursor_announcement_generation = state.cursor_announcement_generation + 1
  local generation = state.cursor_announcement_generation
  local lifecycle_generation = state.lifecycle_generation
  vim.schedule(function()
    if lifecycle_is_current(lifecycle_generation)
      and generation == state.cursor_announcement_generation
    then
      announce_cursor(event)
    end
  end)
end

local mode_names = {
  n = "normal",
  i = "insert",
  v = "visual",
  V = "visual line",
  ["\22"] = "visual block",
  s = "select",
  S = "select line",
  R = "replace",
  r = "prompt",
  t = "terminal",
}

local announce_pending_insert_diagnostics

local function announce_mode(event)
  local previous_mode, mode = event.match:match("^([^:]+):(.+)$")
  mode = mode or vim.api.nvim_get_mode().mode
  local previous_kind = previous_mode and previous_mode:sub(1, 1) or ""
  local mode_kind = mode:sub(1, 1)
  local left_visual = previous_kind == "v"
    or previous_kind == "V"
    or previous_kind == "\22"
  if edits:consume_visual_mode_return(left_visual, mode_kind) then
    state.last_mode = mode_names[mode] or mode_names[mode_kind]
    return
  end
  if state.suppress_prompt_mode_return and previous_kind == "r" then
    state.suppress_prompt_mode_return = nil
    return
  end
  local command_output_owns_transition = state.command_output_fallback
    and (mode_kind == "r"
      or mode_kind == "!"
      or previous_kind == "r"
      or (previous_kind == "c" and mode_kind == "n"))
  if command_output_owns_transition then
    return
  end
  M.activate()
  local left_insert = previous_mode
    and (previous_mode:sub(1, 1) == "i" or previous_mode:sub(1, 1) == "R")
    and mode:sub(1, 1) ~= "i"
    and mode:sub(1, 1) ~= "R"
  if mode:sub(1, 1) ~= "i" and mode:sub(1, 1) ~= "R" then
    close_all_menus()
  end
  if state.options.announce_modes then
    local name = mode_names[mode] or mode_names[mode:sub(1, 1)]
    if name and name ~= state.last_mode then
      state.last_mode = name
      send_speech(name)
    end
  end
  if left_insert then
    local suppression = {}
    state.suppress_next_cursor = suppression
    vim.schedule(function()
      vim.schedule(function()
        if state.suppress_next_cursor == suppression then
          state.suppress_next_cursor = nil
        end
      end)
    end)
    announce_pending_insert_diagnostics()
  end
end

local function announce_buffer()
  M.activate()
  providers:clear_navigation()
  close_all_menus()
  local current = snapshot()
  if not current then
    return
  end
  remember(current)
  remember_text(current)
  if announce_list_window_entry(current) then
    return
  end
  if announce_selected_list_destination(current) or is_recent_list_destination(current) then
    return
  end
  if not state.options.announce_buffers then
    return
  end
  local announcement_key = table.concat({
    current.window,
    current.buffer,
  }, "\0")
  if announcement_key == state.last_buffer_announcement then
    return
  end
  state.last_buffer_announcement = announcement_key
  local name = vim.api.nvim_buf_get_name(current.buffer)
  name = name == "" and "unnamed buffer" or vim.fn.fnamemodify(name, ":t")
  send_speech(name)
end

local function schedule_buffer_announcement()
  state.buffer_announcement_generation = state.buffer_announcement_generation + 1
  state.cursor_announcement_generation = state.cursor_announcement_generation + 1
  local generation = state.buffer_announcement_generation
  M.activate()
  vim.schedule(function()
    if state.enabled and generation == state.buffer_announcement_generation then
      announce_buffer()
    end
  end)
end

local function prepare_to_leave_terminal(event)
  local ok, buftype = pcall(vim.api.nvim_get_option_value, "buftype", {
    buf = event.buf,
  })
  if not state.enabled or not ok or buftype ~= "terminal" then
    return
  end
  state.terminal_fallback = false
  local sent = send("set;auto=0;cursor=0")
  state.active = sent
end

local function announce_diagnostics(event)
  M.activate()
  if not state.options.announce_diagnostics then
    return
  end
  local current = snapshot()
  if not current or event.buf ~= current.buffer then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R" then
    state.pending_insert_diagnostics[current.buffer] = true
    return
  end
  local diagnostics = event.data and event.data.diagnostics
    or vim.diagnostic.get(current.buffer, { lnum = current.row - 1 })
  announce_current_line_diagnostic(current, diagnostics)
end

announce_pending_insert_diagnostics = function()
  if not state.options.announce_diagnostics then
    return
  end
  local current = snapshot()
  if not current or not state.pending_insert_diagnostics[current.buffer] then
    return
  end
  state.pending_insert_diagnostics[current.buffer] = nil
  announce_current_line_diagnostic(current)
end

local function character_at(text, column)
  local character = vim.fn.strcharpart(text:sub(column + 1), 0, 1)
  return spoken_character(character)
end

local function announce_command_line_position(level, position)
  local command_line = state.command_lines[level]
  if not command_line or command_line.position == position then
    return
  end
  local distance = character_distance(command_line.text, position, command_line.position)
  local previous_word_start = select(2, word_at(command_line.text, command_line.position))
  local word, word_start = word_at(command_line.text, position)
  command_line.position = position
  if distance > 1 and word and word_start ~= previous_word_start then
    send_speech(word)
  else
    send_speech(character_at(command_line.text, position))
  end
end

local function current_command_line(level)
  local ok_text, text = pcall(vim.fn.getcmdline)
  local ok_position, position = pcall(vim.fn.getcmdpos)
  if not ok_text or not ok_position or position < 1 then
    return nil
  end
  return {
    text = text,
    position = position - 1,
    level = level,
  }
end

local function remember_command_line(level)
  local command_line = current_command_line(level)
  if command_line then
    state.command_lines[level] = command_line
  end
end

local function announce_command_line(event)
  if state.terminal_fallback then
    state.terminal_command_line = true
  end
  M.activate()
  local event_level = event and event.data and event.data.cmdlevel
  local level = tonumber(event_level) or state.command_line_level + 1
  state.command_line_level = level
  state.command_line_active = true
  remember_command_line(level)
  if not state.options.announce_command_line then
    return
  end
  local names = {
    [":"] = "command",
    ["/"] = "search",
    ["?"] = "search backwards",
    ["="] = "expression",
    ["@"] = "input",
  }
  send_speech(names[vim.fn.getcmdtype()] or "command")
end

local function command_line_change(previous, current)
  local first = 0
  local limit = math.min(#previous, #current)
  while first < limit and previous:byte(first + 1) == current:byte(first + 1) do
    first = first + 1
  end
  local suffix = 0
  while suffix < #previous - first
    and suffix < #current - first
    and previous:byte(#previous - suffix) == current:byte(#current - suffix)
  do
    suffix = suffix + 1
  end
  return previous:sub(first + 1, #previous - suffix),
    current:sub(first + 1, #current - suffix)
end

local function command_line_change_size(text)
  local ok, size = pcall(vim.fn.strchars, text, true)
  return ok and size or #text
end

local function announce_command_line_change(previous, current)
  local removed, added = command_line_change(previous, current)
  local removed_size = command_line_change_size(removed)
  local added_size = command_line_change_size(added)
  if removed_size > 0 and added_size == 0 then
    send_speech(spoken_deletion(removed))
  elseif removed_size > 1 or added_size > 1 then
    send_speech(current == "" and "blank" or current)
  end
end

local function announce_current_command_line(level)
  level = tonumber(level) or state.command_line_level
  if not state.command_line_active or state.command_line_level ~= level then
    return
  end
  local current = current_command_line(level)
  if not current then
    return
  end
  if menu_is_open() then
    state.command_lines[level] = current
    return
  end
  local previous = state.command_lines[level]
  if not state.options.announce_command_line then
    state.command_lines[level] = current
    return
  end
  if previous and previous.text == current.text then
    announce_command_line_position(level, current.position)
    return
  end
  state.command_lines[level] = current
  if previous then
    announce_command_line_change(previous.text, current.text)
  end
end

local function read_message_history()
  local ok, result = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok or type(result) ~= "table" or type(result.output) ~= "string" then
    return nil
  end
  return result.output
end

local function message_history_lines(history)
  if history == "" then
    return {}
  end
  return vim.split(history, "\n", { plain = true })
end

local function new_message_history(previous, current)
  if previous == nil or current == "" or current == previous then
    return nil
  end
  if previous == "" then
    return current
  end
  if current:sub(1, #previous) == previous then
    local added = current:sub(#previous + 1):gsub("^\n", "")
    return added ~= "" and added or nil
  end

  local old_lines = message_history_lines(previous)
  local new_lines = message_history_lines(current)
  local largest_overlap = math.min(#old_lines, #new_lines)
  for overlap = largest_overlap, 1, -1 do
    local matches = true
    for offset = 1, overlap do
      if old_lines[#old_lines - overlap + offset] ~= new_lines[offset] then
        matches = false
        break
      end
    end
    if matches then
      if overlap == #new_lines then
        return nil
      end
      return table.concat(new_lines, "\n", overlap + 1)
    end
  end

  return new_lines[#new_lines]
end

local function poll_messages()
  if not state.enabled then
    return
  end
  local current = read_message_history()
  if current == nil then
    return
  end
  if state.discard_pending_messages then
    state.discard_pending_messages = false
    state.message_history = current
    return
  end
  local added = new_message_history(state.message_history, current)
  state.message_history = current
  if state.command_output_fallback then
    local ok_mode, current_mode = pcall(vim.api.nvim_get_mode)
    local mode = ok_mode and current_mode and current_mode.mode or ""
    if mode:sub(1, 1) == "r" or mode:sub(1, 1) == "!" then
      return
    end
    M.activate()
    return
  end
  if state.options.announce_messages and added then
    M.activate()
    send_speech(added)
  end
end

local function schedule_message_poll()
  if not state.enabled or state.message_poll_scheduled then
    return
  end
  state.message_poll_scheduled = true
  local lifecycle_generation = state.lifecycle_generation
  vim.schedule(function()
    if not lifecycle_is_current(lifecycle_generation) then
      return
    end
    state.message_poll_scheduled = false
    poll_messages()
  end)
end

local function observes_editor_state()
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  return mode == "n"
    or mode == "o"
    or mode == "v"
    or mode == "V"
    or mode == "s"
    or mode == "S"
    or mode == "\22"
    or mode == "\19"
end

providers = providers_module.new({
  activate = function() return M.activate() end,
  changedtick = changedtick,
  command_line_active = function() return state.command_line_active end,
  enabled = function() return state.enabled end,
  lifecycle_generation = function() return state.lifecycle_generation end,
  lifecycle_is_current = lifecycle_is_current,
  menu_is_open = menu_is_open,
  observes_editor_state = observes_editor_state,
  options = function() return state.options end,
  say = function(text) return M.say(text) end,
  send_speech = send_speech,
  set_cursor_suppression = function(value, expected)
    if expected == nil or state.suppress_next_cursor == expected then
      state.suppress_next_cursor = value
    end
  end,
  snapshot = snapshot,
  speech_generation = function() return state.speech_generation end,
})

--- Observe one provider-owned navigation action without depending on how it
--- is mapped. The action's normal Neovim events announce successful movement;
--- an unchanged editor state announces the unavailable direction.
function M.observe_navigation(direction, action, ...)
  return providers:observe_navigation(direction, action, ...)
end

--- Observe an action which selects a search result without depending on how
--- it is mapped. Cursor speech still comes from Neovim events; this adds the
--- current and total match position after the action completes.
function M.observe_search(action, ...)
  return providers:observe_search(action, ...)
end

local schedule_floating_window_scan

local function detach_input_listener()
  state.window_scan_generation = state.window_scan_generation + 1
  if state.input_namespace and type(vim.on_key) == "function" then
    pcall(vim.on_key, nil, state.input_namespace)
  end
end

local function attach_input_listener()
  if type(vim.on_key) ~= "function" then
    return
  end
  state.input_namespace = state.input_namespace
    or vim.api.nvim_create_namespace("lector")
  local function suppress_prompt_return()
    local suppression = {}
    state.suppress_prompt_mode_return = suppression
    vim.schedule(function()
      if state.suppress_prompt_mode_return == suppression then
        state.suppress_prompt_mode_return = nil
      end
    end)
  end

  local function restore_command_output_fallback()
    local fallback_active = state.command_output_fallback
    local ok, current_mode = pcall(vim.api.nvim_get_mode)
    local mode = ok and current_mode and current_mode.mode or ""
    local closes_prompt = mode == "r" or mode == "r?"
    if closes_prompt then
      if fallback_active then
        state.discard_pending_messages = true
      end
      suppress_prompt_return()
      M.activate()
      return true
    end
    if not fallback_active then
      return false
    end
    if mode:sub(1, 1) ~= "r" and mode:sub(1, 1) ~= "!" then
      return false
    end

    vim.schedule(function()
      if not state.enabled
        or not state.command_output_fallback
        or state.command_line_active
      then
        return
      end
      local mode_ok, next_mode = pcall(vim.api.nvim_get_mode)
      local name = mode_ok and next_mode and next_mode.mode or ""
      if name:sub(1, 1) ~= "r" and name:sub(1, 1) ~= "!" then
        state.discard_pending_messages = true
        suppress_prompt_return()
        M.activate()
      end
    end)
    return true
  end

  -- Input is only a transaction boundary here. Editor semantics come from
  -- Neovim state and events; literal keys are interpreted only while
  -- lector.nvim owns a context menu.
  vim.on_key(function(resolved_key)
    if not state.enabled then
      return
    end
    local popup_handled, popup_consumed = context_menu:handle_key(resolved_key)
    if popup_handled then
      schedule_message_poll()
      if popup_consumed then
        return ""
      end
      return
    end
    restore_command_output_fallback()
    edits:observe_input_state()
    schedule_message_poll()
    schedule_fold_observation()
    schedule_floating_window_scan()
  end, state.input_namespace)
end

local ignored_floating_window_filetypes = {
  ["blink-cmp-documentation"] = true,
  ["blink-cmp-menu"] = true,
  wk = true,
}

local function announce_floating_windows(windows)
  local lifecycle_generation = state.lifecycle_generation
  vim.schedule(function()
    if not lifecycle_is_current(lifecycle_generation)
      or not state.options.announce_floating_windows
    then
      return
    end
    if completion:is_blink_open() then
      return
    end
    local readable = {}
    for _, window in ipairs(windows) do
      if vim.api.nvim_win_is_valid(window) and vim.api.nvim_get_current_win() ~= window then
        local config = vim.api.nvim_win_get_config(window)
        local buffer = vim.api.nvim_win_get_buf(window)
        local filetype = vim.bo[buffer].filetype
        if (config.relative ~= "" or config.external)
          and vim.api.nvim_buf_is_valid(buffer)
          and vim.bo[buffer].buftype ~= "terminal"
          and not ignored_floating_window_filetypes[filetype]
        then
          local line_count = math.min(vim.api.nvim_buf_line_count(buffer), 200)
          local lines = vim.api.nvim_buf_get_lines(buffer, 0, line_count, false)
          table.insert(readable, {
            column = tonumber(config.col) or 0,
            row = tonumber(config.row) or 0,
            text = table.concat(lines, "\n"),
            window = window,
            zindex = tonumber(config.zindex) or 50,
          })
        end
      end
    end
    table.sort(readable, function(left, right)
      if left.zindex ~= right.zindex then
        return left.zindex < right.zindex
      end
      if left.row ~= right.row then
        return left.row < right.row
      end
      if left.column ~= right.column then
        return left.column < right.column
      end
      return left.window < right.window
    end)
    local contents = {}
    for _, item in ipairs(readable) do
      table.insert(contents, item.text)
    end
    M.say(table.concat(contents, "\n"))
  end)
end

local function announce_new_floating_windows()
  local current_windows = {}
  local new_windows = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    current_windows[window] = true
    if not state.known_windows[window] then
      state.known_windows[window] = true
      table.insert(new_windows, window)
    end
  end
  for window in pairs(state.known_windows) do
    if not current_windows[window] then
      state.known_windows[window] = nil
      state.windows[window] = nil
    end
  end
  if #new_windows > 0 then
    announce_floating_windows(new_windows)
  end
end

schedule_floating_window_scan = function()
  if not state.options.announce_floating_windows then
    return
  end
  state.window_scan_generation = state.window_scan_generation + 1
  local generation = state.window_scan_generation
  local checks_remaining = math.floor(
    floating_window_scan_duration_ms / floating_window_scan_interval_ms
  )
  local function scan()
    if not state.enabled or generation ~= state.window_scan_generation then
      return
    end
    announce_new_floating_windows()
    if checks_remaining <= 0 then
      return
    end
    checks_remaining = checks_remaining - 1
    defer_tracked(scan, floating_window_scan_interval_ms)
  end
  vim.schedule(scan)
end

local function forget_window(event)
  local window = tonumber(event.match)
  if not window then
    return
  end
  state.known_windows[window] = nil
  state.windows[window] = nil
  state.text_windows[window] = nil
  state.diagnostic_announcements[window] = nil
end

local function create_autocmd(events, callback)
  vim.api.nvim_create_autocmd(events, {
    group = group_name,
    callback = callback,
  })
end

local function autocmd_supported(name)
  return vim.fn.exists("##" .. name) == 1
end

function M.health_info()
  return {
    ui_send_available = protocol.available(),
    enabled = state.enabled,
    active = state.active,
    terminal_fallback = state.terminal_fallback,
    text_put_post = autocmd_supported("TextPutPost"),
    search_wrapped = autocmd_supported("SearchWrapped"),
  }
end

local function invalidate_deferred_work()
  cancel_deferred_timers()
  state.lifecycle_generation = state.lifecycle_generation + 1
  completion:invalidate()
  providers:reset()
  state.fold_observation_generation = state.fold_observation_generation + 1
  state.buffer_announcement_generation = state.buffer_announcement_generation + 1
  state.cursor_announcement_generation = state.cursor_announcement_generation + 1
  state.window_scan_generation = state.window_scan_generation + 1
  state.closed_announcement_generation = state.closed_announcement_generation + 1
  state.command_lines = {}
  state.command_line_active = false
  state.command_line_level = 0
  edits:reset()
  state.pending_insert_diagnostics = {}
  state.suppress_next_cursor = nil
  state.suppress_prompt_mode_return = nil
  state.recent_list_destination = nil
  state.terminal_fallback = false
  state.terminal_command_line = false
  state.command_output_fallback = false
  state.discard_pending_messages = false
  state.message_poll_scheduled = false
end

function M.setup(options)
  if not protocol.available() then
    return false
  end
  local previous_instance = instance_registry[instance_registry_key]
  if previous_instance ~= nil
    and previous_instance ~= M
    and type(previous_instance.teardown) == "function"
  then
    pcall(previous_instance.teardown)
  end
  instance_registry[instance_registry_key] = M
  cancel_deferred_timers()
  state.lifecycle_generation = state.lifecycle_generation + 1
  detach_input_listener()
  state.options = vim.tbl_extend("force", defaults, options or {})
  state.enabled = true
  state.windows = {}
  state.text_windows = {}
  state.known_windows = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    state.known_windows[window] = true
  end
  state.command_lines = {}
  state.command_line_active = false
  state.command_line_level = 0
  providers:reset()
  edits:reset()
  state.pending_insert_diagnostics = {}
  state.suppress_next_cursor = nil
  close_all_menus()
  state.last_mode = nil
  state.last_buffer_announcement = nil
  state.terminal_fallback = false
  state.terminal_command_line = false
  state.command_output_fallback = false
  state.discard_pending_messages = false
  state.suppress_prompt_mode_return = nil
  state.last_spelling = nil
  state.diagnostic_announcements = {}
  state.recent_list_destination = nil
  state.list_selections = {}
  state.fold_observation_generation = state.fold_observation_generation + 1
  state.message_poll_scheduled = false
  state.message_history = read_message_history()
  state.buffer_announcement_generation = state.buffer_announcement_generation + 1
  state.cursor_announcement_generation = state.cursor_announcement_generation + 1
  state.closed_announcement_generation = state.closed_announcement_generation + 1

  vim.api.nvim_create_augroup(group_name, { clear = true })
  create_autocmd({ "VimEnter", "UIEnter", "VimResume", "FocusGained" }, function()
    M.activate()
  end)
  create_autocmd("ShellCmdPost", function()
    if not state.command_output_fallback then
      M.activate()
    end
  end)
  create_autocmd({ "VimSuspend", "ExitPre", "VimLeavePre" }, function()
    close_all_menus()
    M.deactivate()
  end)
  create_autocmd("BufLeave", prepare_to_leave_terminal)
  create_autocmd({ "BufEnter", "WinEnter" }, schedule_buffer_announcement)
  create_autocmd("WinNew", announce_new_floating_windows)
  create_autocmd("WinClosed", function(event)
    forget_window(event)
    schedule_closed_announcement()
  end)
  create_autocmd({ "CursorMoved", "CursorMovedI" }, function(event)
    schedule_cursor_announcement(event.event)
  end)
  create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, function(event)
    edits:announce_text_change(event)
    completion:schedule_blink_refresh()
  end)
  create_autocmd("CompleteChanged", function() completion:refresh_native() end)
  create_autocmd({ "CompleteDonePre", "CompleteDone" }, function()
    completion:close_native()
  end)
  create_autocmd("ModeChanged", announce_mode)
  create_autocmd("TextYankPost", function(event) edits:announce_operator(event) end)
  if autocmd_supported("TextPutPost") then
    create_autocmd("TextPutPost", function(event) edits:announce_put_event(event) end)
  end
  if autocmd_supported("SearchWrapped") then
    create_autocmd("SearchWrapped", function() providers:announce_search_wrapped() end)
  end
  create_autocmd("RecordingEnter", function()
    if state.options.announce_recording then
      M.say("recording " .. vim.fn.reg_recording())
    end
  end)
  create_autocmd("RecordingLeave", function()
    if state.options.announce_recording then
      M.say("recording stopped")
    end
  end)
  create_autocmd("QuickFixCmdPost", function()
    local lifecycle_generation = state.lifecycle_generation
    vim.schedule(function()
      if lifecycle_is_current(lifecycle_generation) then
        local current = snapshot()
        if current then
          announce_selected_list_destination(current)
        end
      end
    end)
  end)
  create_autocmd("MenuPopup", function(event) context_menu:open(event) end)
  create_autocmd("DiagnosticChanged", announce_diagnostics)
  create_autocmd("CmdlineEnter", announce_command_line)
  create_autocmd("CmdlineChanged", function()
    M.activate()
    completion:refresh_command_line()
    announce_current_command_line(state.command_line_level)
  end)
  if autocmd_supported("CursorMovedC") then
    create_autocmd("CursorMovedC", function()
      announce_current_command_line(state.command_line_level)
    end)
  end
  create_autocmd("CmdlineLeave", function(event)
    local event_level = event and event.data and event.data.cmdlevel
    local level = tonumber(event_level) or state.command_line_level
    local command_type = event and (event.match or (event.data and event.data.cmdtype))
    local aborted = event and event.data and event.data.abort
    local command_executed = state.options.announce_messages
      and command_type == ":"
      and not aborted
    local search_executed = state.options.announce_search
      and (command_type == "/" or command_type == "?")
      and not aborted
    state.command_lines[level] = nil
    state.command_line_level = math.max(0, level - 1)
    state.command_line_active = state.command_line_level > 0
    completion:close_command_line()
    local restore_terminal_fallback = state.terminal_command_line
      and not state.command_line_active
    if restore_terminal_fallback then
      local lifecycle_generation = state.lifecycle_generation
      vim.schedule(function()
        if not lifecycle_is_current(lifecycle_generation) then
          return
        end
        state.terminal_command_line = false
        M.activate()
      end)
    elseif command_executed and not state.command_line_active then
      state.command_output_fallback = true
      M.deactivate()
    else
      M.activate()
    end
    schedule_message_poll()
    if search_executed then
      providers:suppress_cursor()
      providers:schedule_search_announcement()
    end
    if state.command_line_active then
      local lifecycle_generation = state.lifecycle_generation
      vim.schedule(function()
        if lifecycle_is_current(lifecycle_generation) then
          remember_command_line(state.command_line_level)
        end
      end)
    end
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = "BlinkCmpMenuOpen",
    callback = function() completion:open_blink() end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = "BlinkCmpMenuClose",
    callback = function() completion:close_blink() end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = { "BlinkCmpListSelect", "BlinkCmpShow" },
    callback = function() completion:schedule_blink_event_refresh() end,
  })
  create_autocmd("SafeState", schedule_message_poll)

  attach_input_listener()

  pcall(vim.api.nvim_create_user_command, "LectorSay", function(command)
    M.say(command.args)
  end, { nargs = "+", force = true })
  pcall(vim.api.nvim_create_user_command, "LectorAccessibilityEnable", function()
    state.message_history = read_message_history()
    state.enabled = true
    M.activate()
  end, { force = true })
  pcall(vim.api.nvim_create_user_command, "LectorAccessibilityDisable", function()
    state.enabled = false
    invalidate_deferred_work()
    close_all_menus()
    M.deactivate()
  end, { force = true })
  pcall(vim.api.nvim_create_user_command, "LectorCompletionDocumentation", function()
    completion:refresh_documentation(state.command_line_active)
    M.read_menu_documentation()
  end, { force = true })
  pcall(vim.api.nvim_create_user_command, "LectorStatus", function()
    M.announce_status()
  end, { force = true })

  local lifecycle_generation = state.lifecycle_generation
  vim.schedule(function()
    if lifecycle_is_current(lifecycle_generation) then
      M.activate()
      announce_buffer()
    end
  end)
  return true
end

function M.teardown()
  local owns_registrations = instance_registry[instance_registry_key] == M
  state.enabled = false
  invalidate_deferred_work()
  close_all_menus()
  M.deactivate()
  if not owns_registrations then
    return
  end
  detach_input_listener()
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
  for _, name in ipairs(user_command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  instance_registry[instance_registry_key] = nil
end

return M
