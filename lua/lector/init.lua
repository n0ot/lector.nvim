-- SPDX-License-Identifier: MIT

local M = {}

local protocol_prefix = "Lector;A11y;1;"
local maximum_speech_bytes = 2000
local floating_window_scan_interval_ms = 50
local floating_window_scan_duration_ms = 1000
local group_name = "LectorApplicationAccessibility"

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
  pending_command_navigation = nil,
  pending_cursor_motion = nil,
  cursor_motion_prefix = nil,
  pending_value_change = nil,
  pending_text_change = nil,
  pending_put = nil,
  put_prefix = nil,
  structured_edit_ticks = {},
  edit_destination_ticks = {},
  put_announcement_ticks = {},
  pending_insert_diagnostics = {},
  suppress_next_cursor = nil,
  suppress_edit_cursor = false,
  suppress_visual_delete_mode_return = nil,
  menu_states = {},
  current_menu_id = nil,
  popup_menu = nil,
  blink_menu_open = false,
  blink_refresh_generation = 0,
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
  search_announcement_generation = 0,
  search_wrapped = false,
  list_selections = {},
  fold_observation_generation = 0,
  input_namespace = nil,
  message_history = nil,
  message_poll_scheduled = false,
  buffer_announcement_generation = 0,
  window_scan_generation = 0,
  speech_generation = 0,
  closed_announcement_generation = 0,
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

local function send(payload)
  if type(vim.api.nvim_ui_send) ~= "function" then
    return false
  end
  return pcall(vim.api.nvim_ui_send, "\27_" .. protocol_prefix .. payload .. "\27\\")
end

local function normalize_speech(text)
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

local function hex_encode(text)
  return (text:gsub(".", function(character)
    return string.format("%02x", string.byte(character))
  end))
end

local function send_speech(text)
  if not state.active then
    return false
  end
  text = normalize_speech(text)
  if not text then
    return false
  end
  local sent = send("say;" .. hex_encode(text))
  if sent then
    state.speech_generation = state.speech_generation + 1
  end
  return sent
end

local function send_line(text, indentation)
  if not state.active then
    return false
  end
  text = normalize_speech(text)
  if not text then
    return false
  end
  indentation = math.max(0, math.min(65535, math.floor(tonumber(indentation) or 0)))
  local sent = send("line;indent=" .. indentation .. ";" .. hex_encode(text))
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
      local sent = send("set;auto=0;cursor=0")
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
  local sent = send("set;auto=0;cursor=0")
  state.active = sent
  return sent
end

function M.deactivate()
  if state.active then
    send("end")
  end
  state.active = false
end

function M.say(text)
  if not M.activate() then
    return false
  end
  return send_speech(text)
end

local function schedule_closed_announcement()
  if not state.enabled then
    return
  end
  state.closed_announcement_generation = state.closed_announcement_generation + 1
  local generation = state.closed_announcement_generation
  local speech_generation = state.speech_generation
  -- Give announcements caused by the close, including a scheduled buffer
  -- announcement, a complete event-loop turn to run first.
  vim.schedule(function()
    vim.schedule(function()
      if state.enabled
        and generation == state.closed_announcement_generation
        and speech_generation == state.speech_generation
      then
        M.say("closed")
      end
    end)
  end)
end

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
  kind = normalize_speech(kind)
  if not kind then
    return nil
  end
  if native_completion_kinds[kind] then
    return native_completion_kinds[kind]
  end
  return kind:gsub("(%l)(%u)", "%1 %2"):lower()
end

local function menu_count_text(count)
  return count == 1 and "1 item" or (count .. " items")
end

local function menu_announcement(menu)
  local parts = { menu.label }
  if state.options.completion_include_kind and menu.kind then
    table.insert(parts, menu.kind)
  end
  if state.options.completion_include_source and menu.source then
    table.insert(parts, menu.source)
  end
  if state.options.completion_include_position and menu.index and menu.count > 0 then
    table.insert(parts, menu.index .. " of " .. menu.count)
  end
  return table.concat(parts, ", ")
end

local function menu_is_open()
  return state.current_menu_id ~= nil
end

--- Present one selected item from an application-owned menu.
---
--- This is intentionally provider-neutral. Optional Neovim-plugin adapters can
--- report their resulting menu state without replacing mappings or transferring
--- ownership of the visible menu to Lector.
local function publish_menu(menu, announce)
  if not state.enabled or not announce or type(menu) ~= "table" then
    return false
  end
  local id = type(menu.id) == "string" and menu.id or nil
  local name = normalize_speech(menu.name) or "menu"
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
    M.close_menu(id)
    return true
  end

  local label = index and normalize_speech(menu.label) or nil
  if index and not label then
    return false
  end
  local current = {
    name = name,
    count = count,
    index = index,
    label = label,
    kind = readable_completion_kind(menu.kind),
    source = normalize_speech(menu.source),
    documentation = normalize_speech(menu.documentation),
  }
  current.key = table.concat({
    current.index or "",
    current.count,
    current.label or "",
    current.kind or "",
    current.source or "",
  }, "\0")

  local previous = state.menu_states[id]
  state.menu_states[id] = current
  state.current_menu_id = id
  if current.index then
    if not previous or previous.key ~= current.key then
      return M.say(menu_announcement(current))
    end
    return true
  end
  if not previous then
    return M.say(name .. ", " .. menu_count_text(count) .. ", no selection")
  end
  if previous.index then
    return M.say(name .. ", no selection")
  end
  return true
end

function M.update_menu(menu)
  return publish_menu(menu, state.options.announce_completions)
end

function M.close_menu(id)
  if type(id) ~= "string" then
    return false
  end
  state.menu_states[id] = nil
  if state.current_menu_id == id then
    state.current_menu_id = next(state.menu_states)
  end
  return true
end

function M.read_menu_documentation(id)
  id = id or state.current_menu_id
  local menu = id and state.menu_states[id] or nil
  if not menu or not menu.index then
    return M.say("no completion selected")
  end
  if not menu.documentation then
    return M.say("no completion documentation")
  end
  return M.say(menu.documentation)
end

local function close_all_menus()
  state.menu_states = {}
  state.current_menu_id = nil
  state.popup_menu = nil
  state.blink_menu_open = false
  state.blink_refresh_generation = state.blink_refresh_generation + 1
end

local function word_at(line, column)
  local search_from = 0
  while search_from <= #line do
    local match = vim.fn.matchstrpos(line, [[\k\+]], search_from)
    local start_column = match[2]
    local end_column = match[3]
    if start_column < 0 or start_column > column then
      return nil, nil
    end
    if column < end_column then
      return match[1], start_column
    end
    search_from = end_column
  end
  return nil, nil
end

local function word_at_or_after(line, column)
  local word = select(1, word_at(line, column))
  if word then
    return word
  end
  local match = vim.fn.matchstrpos(line, [[\k\+]], math.max(0, column))
  if type(match) == "table"
    and type(match[1]) == "string"
    and match[1] ~= ""
  then
    return match[1]
  end
  return nil
end

local function character_distance(text, first_column, second_column)
  if first_column == second_column then
    return 0
  end
  local first = math.min(first_column, second_column)
  local last = math.max(first_column, second_column)
  local between = text:sub(first + 1, last)
  local ok, distance = pcall(vim.fn.strchars, between, true)
  if ok then
    return distance
  end
  return last - first
end

local function fallback_motion_word(line, column, big_word)
  if not big_word then
    return select(1, word_at(line, column))
  end
  local search_from = 0
  while search_from <= #line do
    local match = vim.fn.matchstrpos(line, [[\S\+]], search_from)
    local start_column = match[2]
    local end_column = match[3]
    if start_column < 0 or start_column > column then
      return nil
    end
    if column < end_column then
      return match[1]
    end
    search_from = end_column
  end
  return nil
end

local function motion_word_at(line, column, big_word)
  if type(vim.fn.charclass) ~= "function" then
    return fallback_motion_word(line, column, big_word)
  end
  local characters = {}
  local byte_offset = 0
  local current_index
  for _, text in ipairs(vim.fn.split(line, "\\zs")) do
    local character = {
      text = text,
      first_byte = byte_offset,
      last_byte = byte_offset + #text,
      class = vim.fn.charclass(text),
    }
    table.insert(characters, character)
    if character.first_byte <= column and column < character.last_byte then
      current_index = #characters
    end
    byte_offset = character.last_byte
  end
  if not current_index or characters[current_index].class == 0 then
    return nil
  end

  local class = characters[current_index].class
  local function belongs(character)
    if big_word then
      return character.class ~= 0
    end
    return character.class == class
  end

  local first = current_index
  while first > 1 and belongs(characters[first - 1]) do
    first = first - 1
  end
  local last = current_index
  while last < #characters and belongs(characters[last + 1]) do
    last = last + 1
  end
  local parts = {}
  for index = first, last do
    table.insert(parts, characters[index].text)
  end
  return table.concat(parts)
end

local function snapshot()
  local window = vim.api.nvim_get_current_win()
  local buffer = vim.api.nvim_win_get_buf(window)
  if not vim.api.nvim_win_is_valid(window) or not vim.api.nvim_buf_is_valid(buffer) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local ok, line = pcall(vim.api.nvim_get_current_line)
  if not ok then
    return nil
  end
  local word, word_start = word_at(line, cursor[2])
  local indentation = vim.fn.indent(cursor[1])
  local fold_start = vim.fn.foldclosed(cursor[1])
  local fold_end = fold_start >= 0 and vim.fn.foldclosedend(cursor[1]) or -1
  return {
    window = window,
    buffer = buffer,
    row = cursor[1],
    column = cursor[2],
    line = line,
    indentation = math.max(0, indentation),
    word = word,
    word_start = word_start,
    fold_start = fold_start,
    fold_end = fold_end,
    line_count = vim.api.nvim_buf_line_count(buffer),
  }
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

local function spoken_line(current)
  local line = current.line
  if line:match("^%s*$") then
    line = "blank"
  end
  return line
end

local function spoken_character(character)
  if character == "" then
    return "blank"
  end
  if character == " " then
    return "space"
  end
  if character == "\t" then
    return "tab"
  end
  if character:match("^%s$") then
    return "blank"
  end
  return character
end

local function character_at_cursor(current)
  local tail = current.line:sub(current.column + 1)
  local character = vim.fn.strcharpart(tail, 0, 1)
  return spoken_character(character)
end

local function fold_line_count(current)
  if not current or current.fold_start < 0 or current.fold_end < current.fold_start then
    return nil
  end
  return current.fold_end - current.fold_start + 1
end

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
    key = table.concat({ current.window, current.buffer, current.row, start_column, word, kind }, "\0"),
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

local function visual_selection_summary(current)
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode ~= "v" and mode ~= "V" and mode ~= "\22"
    and mode ~= "s" and mode ~= "S" and mode ~= "\19"
  then
    return nil
  end
  local anchor = vim.fn.getpos("v")
  local anchor_row = tonumber(anchor[2]) or current.row
  local anchor_column = math.max(0, (tonumber(anchor[3]) or 1) - 1)
  local rows = math.abs(current.row - anchor_row) + 1
  if mode == "V" or mode == "S" then
    return rows .. (rows == 1 and " line selected" or " lines selected")
  end
  if mode == "\22" or mode == "\19" then
    local columns = math.abs(current.column - anchor_column) + 1
    return "block, " .. rows .. (rows == 1 and " line by " or " lines by ")
      .. columns .. (columns == 1 and " column selected" or " columns selected")
  end
  if rows == 1 then
    local characters = character_distance(current.line, current.column, anchor_column) + 1
    return characters .. (characters == 1 and " character selected" or " characters selected")
  end
  return rows .. " lines selected"
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
  local motion = state.pending_cursor_motion
  state.pending_cursor_motion = nil
  local current = snapshot()
  if not current then
    return
  end
  if state.suppress_next_cursor then
    state.suppress_next_cursor = nil
    remember(current)
    return
  end
  if state.suppress_edit_cursor then
    state.suppress_edit_cursor = false
    remember(current)
    return
  end
  if menu_is_open() then
    remember(current)
    return
  end
  local announced_list_destination = announce_selected_list_destination(current)
  local spelling = spell_error_at_cursor(current)
  local new_spelling = spelling and state.last_spelling ~= spelling.key
  local previous = state.windows[current.window]
  if not announced_list_destination
    and state.options.announce_cursor
    and previous
    and previous.buffer == current.buffer
  then
    if motion and motion.kind == "character" then
      if not new_spelling then
        send_speech(character_at_cursor(current))
      end
    elseif motion and motion.kind == "word" then
      if motion.spelling or not new_spelling then
        local word = motion_word_at(current.line, current.column, false)
        send_speech(word or character_at_cursor(current))
      end
    elseif motion and motion.kind == "WORD" then
      if not new_spelling then
        local word = motion_word_at(current.line, current.column, true)
        send_speech(word or character_at_cursor(current))
      end
    elseif motion and motion.kind == "line" then
      if not announce_list_window_entry(current) then
        send_line(spoken_line(current), current.indentation)
      end
      announce_closed_fold(current)
      announce_current_line_diagnostic(current)
    elseif previous.row ~= current.row then
      if not announce_list_window_entry(current) then
        send_line(spoken_line(current), current.indentation)
      end
      announce_closed_fold(current)
      announce_current_line_diagnostic(current)
    elseif event == "CursorMoved" and previous.column ~= current.column then
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
  if announced_list_destination or (motion and motion.spelling) then
    state.last_spelling = spelling and spelling.key or nil
  else
    announce_spelling(current, spelling)
  end
  remember(current)
end

local function changedtick(buffer)
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, buffer)
  return ok and tick or nil
end

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
  return normalize_speech(text) or "blank"
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

local function mark_structured_edit(buffer)
  local tick = changedtick(buffer)
  if tick then
    state.structured_edit_ticks[buffer] = tick
  end
end

local function schedule_edit_destination(buffer, destination_kind, previous)
  if not state.options.announce_deletions then
    state.suppress_edit_cursor = false
    return
  end
  local tick = changedtick(buffer)
  if not tick or state.edit_destination_ticks[buffer] == tick then
    return
  end
  state.edit_destination_ticks[buffer] = tick
  vim.schedule(function()
    if not state.enabled then
      return
    end
    local current = snapshot()
    if not current or current.buffer ~= buffer then
      return
    end
    M.activate()
    local moved_lines = previous
      and previous.buffer == current.buffer
      and (previous.row ~= current.row or previous.line_count ~= current.line_count)
    if destination_kind == "line" or moved_lines then
      send_line(spoken_line(current), current.indentation)
    elseif destination_kind == "word" then
      local word = word_at_or_after(current.line, current.column)
      send_speech(word or character_at_cursor(current))
    else
      send_speech(character_at_cursor(current))
    end
    state.suppress_edit_cursor = false
    remember(current)
    remember_text(current)
  end)
end

local function announce_operator_edit(event)
  local data = structured_event_data(event)
  local operator = data and data.operator
  if operator ~= "d" and operator ~= "c" then
    return
  end
  local buffer = event.buf or vim.api.nvim_get_current_buf()
  local pending_change = state.pending_text_change
  local previous = pending_change and pending_change.snapshot or nil
  mark_structured_edit(buffer)
  state.pending_text_change = nil
  if state.pending_put then
    return
  end
  local regtype = tostring(data.regtype or ""):sub(1, 1)
  local destination_kind = pending_change and pending_change.destination_kind or nil
  if regtype == "V" or regtype == "\22" then
    destination_kind = "line"
  elseif data.visual then
    -- TextYankPost identifies a Visual operator independently of the key or
    -- mapping that invoked it. A characterwise Visual deletion lands on a
    -- character even when its selected contents span multiple characters.
    destination_kind = "character"
    if operator == "d" and state.options.announce_deletions then
      local suppression = {}
      state.suppress_visual_delete_mode_return = suppression
      vim.schedule(function()
        if state.suppress_visual_delete_mode_return == suppression then
          state.suppress_visual_delete_mode_return = nil
        end
      end)
    end
  end
  schedule_edit_destination(buffer, destination_kind or "character", previous)
  local current = snapshot()
  remember_text(current)
end

local function announce_put(data, buffer)
  mark_structured_edit(buffer)
  state.pending_put = nil
  state.pending_text_change = nil
  local tick = changedtick(buffer)
  local already_announced = tick and state.put_announcement_ticks[buffer] == tick
  if tick then
    state.put_announcement_ticks[buffer] = tick
  end
  if state.options.announce_puts and not menu_is_open() and not already_announced then
    M.activate()
    send_speech(edit_announcement("pasted", data.regcontents, data.regtype))
  end
  local current = snapshot()
  state.suppress_edit_cursor = false
  remember(current)
  remember_text(current)
end

local function announce_put_event(event)
  local data = structured_event_data(event)
  if not data or (data.operator ~= "p" and data.operator ~= "P") then
    return
  end
  announce_put(data, event.buf or vim.api.nvim_get_current_buf())
end

local function finish_pending_put(pending, current)
  if state.pending_put ~= pending then
    return false
  end
  current = current or snapshot()
  if not current or current.buffer ~= pending.buffer then
    state.pending_put = nil
    return false
  end
  local tick = changedtick(current.buffer)
  if not tick or tick == pending.changedtick then
    return false
  end
  announce_put({
    regcontents = pending.regcontents,
    regtype = pending.regtype,
  }, current.buffer)
  return true
end

local numeric_value_patterns = {
  "0[xX][0-9a-fA-F]+",
  "0[bB][01]+",
  "%-?%d+",
}

local function numeric_value_at_or_after(line, column)
  local containing
  local following
  for _, pattern in ipairs(numeric_value_patterns) do
    local search_from = 1
    while search_from <= #line do
      local first, last = line:find(pattern, search_from)
      if not first then
        break
      end
      local candidate = {
        text = line:sub(first, last),
        first_column = first - 1,
        last_column = last,
      }
      if candidate.first_column <= column and column < candidate.last_column then
        if not containing or #candidate.text > #containing.text then
          containing = candidate
        end
      elseif candidate.first_column >= column
        and (not following or candidate.first_column < following.first_column)
      then
        following = candidate
      end
      search_from = first + 1
    end
  end
  local value = containing or following
  return value and value.text or nil
end

local function changed_value_at_cursor(current)
  local value = numeric_value_at_or_after(current.line, current.column)
  if value then
    return value
  end
  return character_at_cursor(current)
end

local function announce_text_change()
  M.activate()
  local value_change = state.pending_value_change
  state.pending_value_change = nil
  local pending_change = state.pending_text_change
  state.pending_text_change = nil
  local current = snapshot()
  if not current then
    return
  end
  if state.pending_put and finish_pending_put(state.pending_put, current) then
    return
  end
  local current_tick = changedtick(current.buffer)
  local structured = current_tick
    and state.structured_edit_ticks[current.buffer] == current_tick
  if structured then
    state.structured_edit_ticks[current.buffer] = nil
  end
  if menu_is_open() and not (pending_change and pending_change.direct_deletion) then
    remember(current)
    remember_text(current)
    return
  end
  local previous = state.text_windows[current.window]
  local pending = pending_change and pending_change.snapshot
  if (not previous or previous.buffer ~= current.buffer or previous.row ~= current.row)
    and pending
    and pending.window == current.window
    and pending.buffer == current.buffer
    and pending.row == current.row
  then
    previous = pending
  end
  if value_change then
    state.suppress_edit_cursor = false
    if state.options.announce_value_changes then
      send_speech(changed_value_at_cursor(current))
    end
  elseif not structured
    and pending_change
    and (pending_change.direct_deletion or pending_change.operator_candidate)
  then
    schedule_edit_destination(
      current.buffer,
      pending_change.destination_kind or "character",
      pending or previous
    )
  elseif not structured then
    state.suppress_edit_cursor = false
  end
  remember(current)
  remember_text(current)
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
  if state.suppress_visual_delete_mode_return
    and left_visual
    and mode_kind == "n"
  then
    state.suppress_visual_delete_mode_return = nil
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
      if state.suppress_next_cursor == suppression then
        state.suppress_next_cursor = nil
      end
    end)
    announce_pending_insert_diagnostics()
  end
end

local function announce_buffer()
  M.activate()
  state.pending_cursor_motion = nil
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

local vertical_command_navigation = {
  ["<Up>"] = true,
  ["<Down>"] = true,
  ["<C-P>"] = true,
  ["<C-N>"] = true,
  ["<PageUp>"] = true,
  ["<PageDown>"] = true,
}

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

local function announce_current_command_line(navigation, level)
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
  if previous and previous.text == current.text then
    announce_command_line_position(level, current.position)
    return
  end
  state.command_lines[level] = current
  if previous and vertical_command_navigation[navigation] then
    send_speech(current.text == "" and "blank" or current.text)
  end
end

local native_completion_menu_id = "neovim-insert-completion"
local command_line_completion_menu_id = "neovim-command-line-completion"
local blink_completion_menu_id = "blink-completion"

local function native_completion_item_label(item)
  if type(item) ~= "table" then
    return nil
  end
  local abbreviation = type(item.abbr) == "string" and item.abbr or ""
  if abbreviation ~= "" then
    return abbreviation
  end
  return item.word
end

local function refresh_native_completion()
  if not state.enabled or not state.options.announce_completions then
    M.close_menu(native_completion_menu_id)
    return
  end
  local ok, info = pcall(vim.fn.complete_info, { "pum_visible", "items", "selected" })
  if not ok
    or type(info) ~= "table"
    or tonumber(info.pum_visible) ~= 1
    or type(info.items) ~= "table"
  then
    M.close_menu(native_completion_menu_id)
    return
  end

  local selected = tonumber(info.selected)
  local index = selected and selected >= 0 and selected + 1 or nil
  local item = index and info.items[index] or nil
  M.update_menu({
    id = native_completion_menu_id,
    name = "completion menu",
    count = #info.items,
    index = index,
    label = native_completion_item_label(item),
    kind = item and item.kind,
    source = item and item.menu,
    documentation = item and item.info,
  })
end

local function refresh_command_line_completion()
  if not state.enabled
    or not state.options.announce_completions
    or vim.fn.exists("*cmdcomplete_info") ~= 1
  then
    M.close_menu(command_line_completion_menu_id)
    return
  end
  local ok, info = pcall(vim.fn.cmdcomplete_info)
  if not ok
    or type(info) ~= "table"
    or tonumber(info.pum_visible) ~= 1
    or type(info.matches) ~= "table"
  then
    M.close_menu(command_line_completion_menu_id)
    return
  end

  local selected = tonumber(info.selected)
  local index = selected and selected >= 0 and selected + 1 or nil
  M.update_menu({
    id = command_line_completion_menu_id,
    name = "command completion menu",
    count = #info.matches,
    index = index,
    label = index and info.matches[index] or nil,
  })
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

local function refresh_blink_completion()
  if not state.enabled or not state.blink_menu_open or not state.options.announce_completions then
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
  M.update_menu({
    id = blink_completion_menu_id,
    name = "completion menu",
    count = #items,
    index = index,
    label = blink_item_label(item),
    kind = kind,
    source = source,
    documentation = blink_documentation(item),
  })
end

local function schedule_blink_completion_refresh()
  if not state.enabled or not state.blink_menu_open or not state.options.announce_completions then
    return
  end
  state.blink_refresh_generation = state.blink_refresh_generation + 1
  local generation = state.blink_refresh_generation
  for _, delay in ipairs({ 0, 20, 100, 250 }) do
    vim.defer_fn(function()
      if state.enabled
        and state.blink_menu_open
        and generation == state.blink_refresh_generation
      then
        refresh_blink_completion()
      end
    end, delay)
  end
end

local function open_blink_completion()
  state.blink_menu_open = true
  M.close_menu(native_completion_menu_id)
  M.close_menu(command_line_completion_menu_id)
  schedule_blink_completion_refresh()
end

local function close_blink_completion()
  state.blink_menu_open = false
  state.blink_refresh_generation = state.blink_refresh_generation + 1
  M.close_menu(blink_completion_menu_id)
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
  vim.schedule(function()
    state.message_poll_scheduled = false
    poll_messages()
  end)
end

local direct_cursor_motions = {
  h = "character",
  l = "character",
  ["|"] = "character",
  [";"] = "character",
  [","] = "character",
  w = "word",
  b = "word",
  e = "word",
  W = "WORD",
  B = "WORD",
  E = "WORD",
  j = "line",
  k = "line",
  ["+"] = "line",
  ["-"] = "line",
  ["_"] = "line",
  G = "line",
}

local g_cursor_motions = {
  e = "word",
  E = "WORD",
  j = "line",
  k = "line",
  g = "line",
  ["0"] = "character",
  ["^"] = "character",
  ["$"] = "character",
  ["_"] = "character",
  m = "character",
  M = "character",
}

local function accepts_normal_motion()
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

local function bracket_motion_direction(prefix)
  if prefix == "bracket-previous" then
    return "previous"
  end
  if prefix == "bracket-next" then
    return "next"
  end
  return nil
end

local function typed_bracket_motion_direction(typed_key)
  if type(typed_key) ~= "string" or #typed_key < 2 then
    return nil
  end
  local prefix = typed_key:sub(1, 1)
  if prefix == "[" then
    return "previous"
  end
  if prefix == "]" then
    return "next"
  end
  return nil
end

local function schedule_failed_cursor_motion(motion)
  vim.schedule(function()
    vim.schedule(function()
      if state.pending_cursor_motion ~= motion then
        return
      end
      state.pending_cursor_motion = nil
      if not state.enabled
        or not state.options.announce_cursor
        or state.command_line_active
        or menu_is_open()
        or motion.speech_generation ~= state.speech_generation
        or not accepts_normal_motion()
      then
        return
      end
      local current = snapshot()
      local previous = motion.snapshot
      if not current
        or not previous
        or current.window ~= previous.window
        or current.buffer ~= previous.buffer
        or current.row ~= previous.row
        or current.column ~= previous.column
        or changedtick(current.buffer) ~= motion.changedtick
      then
        return
      end
      M.say("no " .. motion.direction .. " item")
    end)
  end)
end

local function record_cursor_motion(
  key,
  typed_key,
  special_cursor_motions,
  window_command_key
)
  state.pending_cursor_motion = nil
  if state.command_line_active then
    state.cursor_motion_prefix = nil
    return
  end

  local full_mode = vim.api.nvim_get_mode().mode
  local mode = full_mode:sub(1, 1)
  if mode == "o" or full_mode:sub(1, 2) == "no" then
    state.cursor_motion_prefix = nil
    return
  end
  if mode == "i" or mode == "R" then
    state.cursor_motion_prefix = nil
    local kind = special_cursor_motions[key]
    if kind then
      state.pending_cursor_motion = { kind = kind }
    end
    return
  end
  if not accepts_normal_motion() then
    state.cursor_motion_prefix = nil
    return
  end

  local prefix = state.cursor_motion_prefix
  state.cursor_motion_prefix = nil
  local kind
  local spelling_motion = false
  local direction
  if prefix == "window" then
    return
  elseif bracket_motion_direction(prefix) then
    direction = bracket_motion_direction(prefix)
    if key ~= "p" and key ~= "P" then
      kind = key == "s" and "word" or "line"
      spelling_motion = key == "s"
    end
  elseif prefix == "g" then
    kind = g_cursor_motions[key]
  elseif prefix == "find" then
    if key ~= "\27" then
      kind = "character"
    end
  elseif key == window_command_key then
    state.cursor_motion_prefix = "window"
    return
  elseif key == "[" then
    state.cursor_motion_prefix = "bracket-previous"
    return
  elseif key == "]" then
    state.cursor_motion_prefix = "bracket-next"
    return
  elseif key == "g" then
    state.cursor_motion_prefix = "g"
    return
  elseif key == "f" or key == "F" or key == "t" or key == "T" then
    state.cursor_motion_prefix = "find"
    return
  elseif key:match("^%d$") then
    return
  else
    kind = direct_cursor_motions[key] or special_cursor_motions[key]
  end

  if not kind then
    -- Lua callback mappings are represented by an opaque resolved key. Their
    -- complete typed bracket command still preserves the navigation family.
    direction = typed_bracket_motion_direction(typed_key)
    if direction then
      kind = "line"
    end
  end

  if kind then
    local motion = {
      kind = kind,
      spelling = spelling_motion,
      direction = direction,
    }
    if direction then
      motion.snapshot = snapshot()
      motion.changedtick = motion.snapshot and changedtick(motion.snapshot.buffer) or nil
      motion.speech_generation = state.speech_generation
    end
    state.pending_cursor_motion = motion
    if motion.snapshot then
      schedule_failed_cursor_motion(motion)
    end
  end
end

local function record_value_change(key, value_change_keys)
  state.pending_value_change = nil
  if state.command_line_active or not accepts_normal_motion() then
    return
  end
  if value_change_keys[key] then
    state.pending_value_change = true
  end
end

local function schedule_search_announcement()
  if not state.enabled or not state.options.announce_search then
    state.search_wrapped = false
    return
  end
  state.search_announcement_generation = state.search_announcement_generation + 1
  local generation = state.search_announcement_generation
  vim.schedule(function()
    if not state.enabled or generation ~= state.search_announcement_generation then
      return
    end
    local wrapped = state.search_wrapped
    state.search_wrapped = false
    local ok, count = pcall(vim.fn.searchcount, {
      recompute = 1,
      maxcount = 100000,
      timeout = 50,
    })
    if not ok or type(count) ~= "table" then
      return
    end
    local current = tonumber(count.current) or 0
    local total = tonumber(count.total) or 0
    if current < 1 or total < 1 then
      return
    end
    M.activate()
    local announcement = current .. " of " .. total
    if tonumber(count.incomplete) and tonumber(count.incomplete) ~= 0 then
      announcement = announcement .. ", count incomplete"
    end
    if wrapped then
      announcement = announcement .. ", wrapped"
    end
    send_speech(announcement)
  end)
end

local function announce_search_wrapped()
  state.search_wrapped = true
  schedule_search_announcement()
end

local schedule_floating_window_scan

local popup_menu_id = "nvim-popup-menu"

local function popup_mode(event_mode)
  if event_mode == "tl" then
    return "t"
  end
  return event_mode
end

local function popup_menu_component(name)
  return name:gsub("\\", "\\\\"):gsub("%.", "\\.")
end

local function popup_menu_items(event_mode)
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
    local name = normalize_speech(item.name)
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
          and ("PopUp." .. popup_menu_component(item.name))
          or nil,
      })
    end
  end
  return items
end

local function close_popup_menu()
  state.popup_menu = nil
  M.close_menu(popup_menu_id)
end

local function open_popup_menu(event)
  if not state.enabled or not state.options.announce_popup_menus then
    return
  end
  local popup = {
    event_mode = event.match,
    index = nil,
    items = {},
  }
  state.popup_menu = popup
  popup.items = popup_menu_items(popup.event_mode)
  if #popup.items == 0 then
    close_popup_menu()
    return
  end
  M.say("context menu")
  vim.schedule(function()
    if state.popup_menu == popup then
      local activation_path = popup.activation_path
      close_popup_menu()
      schedule_closed_announcement()
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
      M.activate()
    end
  end)
end

local word_edit_motion_keys = {
  b = true,
  B = true,
  e = true,
  E = true,
  w = true,
  W = true,
}

local line_edit_motion_keys = {
  c = true,
  d = true,
  G = true,
  j = true,
  k = true,
  ["+"] = true,
  ["-"] = true,
  ["_"] = true,
  ["{"] = true,
  ["}"] = true,
}

local function edit_destination_kind(
  key,
  direct_deletion_keys,
  operator_edit_keys,
  bracket_command
)
  local full_mode = vim.api.nvim_get_mode().mode
  local mode = full_mode:sub(1, 1)
  local operator_pending = mode == "o" or full_mode:sub(1, 2) == "no"
  if bracket_command and key ~= "p" and key ~= "P" then
    return nil
  end
  if direct_deletion_keys[key] then
    return "character"
  end
  if operator_pending then
    if word_edit_motion_keys[key] then
      return "word"
    end
    if line_edit_motion_keys[key] then
      return "line"
    end
    return "character"
  end
  if not operator_edit_keys[key] then
    return nil
  end
  if mode == "V"
    or mode == "S"
    or mode == "\22"
    or mode == "\19"
    or key == "S"
  then
    return "line"
  end
  if mode == "v" or mode == "s" or key == "x" or key == "X" or key == "s"
    or key == "D" or key == "C"
  then
    return "character"
  end
  return nil
end

local function record_text_change_baseline(
  key,
  direct_deletion_keys,
  operator_edit_keys,
  bracket_command
)
  local full_mode = vim.api.nvim_get_mode().mode
  local operator_pending = full_mode:sub(1, 1) == "o"
    or full_mode:sub(1, 2) == "no"
  local pending = {
    direct_deletion = direct_deletion_keys[key] == true,
    operator_candidate = operator_pending or operator_edit_keys[key] == true,
    destination_kind = edit_destination_kind(
      key,
      direct_deletion_keys,
      operator_edit_keys,
      bracket_command
    ),
    snapshot = snapshot(),
  }
  state.pending_text_change = pending
  if pending.snapshot then
    vim.schedule(function()
      if state.pending_text_change == pending then
        state.pending_text_change = nil
      end
    end)
  end
end

local function record_pending_put(key, put_keys)
  if state.command_line_active or not accepts_normal_motion() then
    state.put_prefix = nil
    return
  end
  local prefix = state.put_prefix
  state.put_prefix = nil
  if (key == "g" or key == "[" or key == "]") and not prefix then
    state.put_prefix = key
    return
  end
  if not put_keys[key] or (prefix and prefix ~= "g" and prefix ~= "[" and prefix ~= "]") then
    return
  end
  local buffer = vim.api.nvim_get_current_buf()
  local register = vim.v.register
  if type(register) ~= "string" or register == "" then
    register = '"'
  end
  local ok_contents, contents = pcall(vim.fn.getreg, register, 1, true)
  local ok_type, regtype = pcall(vim.fn.getregtype, register)
  if not ok_contents or type(contents) ~= "table" or not ok_type then
    return
  end
  local pending = {
    buffer = buffer,
    changedtick = changedtick(buffer),
    regcontents = contents,
    regtype = regtype,
  }
  state.pending_put = pending
  vim.schedule(function()
    if state.pending_put == pending and not finish_pending_put(pending) then
      state.pending_put = nil
    end
  end)
end

local function record_edit_cursor_suppression(
  key,
  direct_edit_keys,
  escape,
  bracket_command
)
  local full_mode = vim.api.nvim_get_mode().mode
  local mode = full_mode:sub(1, 1)
  local operator_pending = mode == "o" or full_mode:sub(1, 2) == "no"
  if state.suppress_edit_cursor and not operator_pending then
    state.suppress_edit_cursor = false
  end
  if key == escape then
    state.suppress_edit_cursor = false
  elseif operator_pending
    or (accepts_normal_motion()
      and direct_edit_keys[key]
      and (not bracket_command or key == "p" or key == "P"))
  then
    state.suppress_edit_cursor = true
  end
end

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
  local navigation_keys = {}
  for _, name in ipairs({
    "<Left>", "<Right>", "<Up>", "<Down>", "<Home>", "<End>",
    "<C-B>", "<C-F>", "<C-P>", "<C-N>", "<PageUp>", "<PageDown>",
  }) do
    navigation_keys[vim.api.nvim_replace_termcodes(name, true, false, true)] = name
  end
  local special_cursor_motions = {}
  for name, kind in pairs({
    ["<Left>"] = "character",
    ["<Right>"] = "character",
    ["<Up>"] = "line",
    ["<Down>"] = "line",
    ["<S-Left>"] = "word",
    ["<S-Right>"] = "word",
    ["<C-Left>"] = "WORD",
    ["<C-Right>"] = "WORD",
    ["<C-B>"] = "line",
    ["<C-D>"] = "line",
    ["<C-F>"] = "line",
    ["<C-U>"] = "line",
    ["<C-Y>"] = "line",
    ["<C-E>"] = "line",
    ["<PageUp>"] = "line",
    ["<PageDown>"] = "line",
    ["<CR>"] = "line",
  }) do
    special_cursor_motions[vim.api.nvim_replace_termcodes(name, true, false, true)] = kind
  end
  local value_change_keys = {
    [vim.api.nvim_replace_termcodes("<C-A>", true, false, true)] = true,
    [vim.api.nvim_replace_termcodes("<C-X>", true, false, true)] = true,
  }
  local direct_deletion_keys = {
    ["\b"] = true,
    ["\127"] = true,
    [vim.api.nvim_replace_termcodes("<BS>", true, false, true)] = true,
    [vim.api.nvim_replace_termcodes("<Del>", true, false, true)] = true,
  }
  local direct_edit_keys = {
    c = true,
    C = true,
    d = true,
    D = true,
    s = true,
    S = true,
    x = true,
    X = true,
    p = true,
    P = true,
  }
  local operator_edit_keys = {
    c = true,
    C = true,
    d = true,
    D = true,
    s = true,
    S = true,
    x = true,
    X = true,
  }
  local put_keys = {
    p = true,
    P = true,
  }
  local search_keys = {
    n = true,
    N = true,
    ["*"] = true,
    ["#"] = true,
  }
  local escape = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  local window_command = vim.api.nvim_replace_termcodes("<C-W>", true, false, true)
  local popup_enter_keys = {
    [vim.api.nvim_replace_termcodes("<CR>", true, false, true)] = true,
    [vim.api.nvim_replace_termcodes("<kEnter>", true, false, true)] = true,
  }
  local popup_submenu_keys = vim.tbl_extend("force", {}, popup_enter_keys)
  popup_submenu_keys[vim.api.nvim_replace_termcodes("<Right>", true, false, true)] = true
  local popup_navigation_keys = {
    [vim.api.nvim_replace_termcodes("<Down>", true, false, true)] = 1,
    [vim.api.nvim_replace_termcodes("<Up>", true, false, true)] = -1,
  }

  local function handle_popup_menu_key(key)
    local popup = state.popup_menu
    if not popup then
      return false, false
    end
    if popup.fallback then
      return false, false
    end
    local direction = popup_navigation_keys[key]
    if direction and #popup.items > 0 then
      if not popup.index then
        popup.index = direction > 0 and 1 or #popup.items
      else
        popup.index = ((popup.index - 1 + direction) % #popup.items) + 1
      end
      publish_menu({
        id = popup_menu_id,
        name = "context menu",
        count = #popup.items,
        index = popup.index,
        label = popup.items[popup.index].label
          .. (popup.items[popup.index].submenu and ", submenu" or ""),
      }, true)
    end
    if popup_submenu_keys[key]
      and popup.index
      and popup.items[popup.index].submenu
    then
      popup.fallback = true
      M.close_menu(popup_menu_id)
      M.deactivate()
      return true, false
    end
    if popup_enter_keys[key] and popup.index then
      local activation_path = popup.items[popup.index].activation_path
      if activation_path then
        local ok, written = pcall(vim.api.nvim_input, escape)
        if ok and written == #escape then
          popup.activation_path = activation_path
          return true, true
        end
      end
    end
    return true, false
  end

  local function suppress_prompt_return()
    local suppression = {}
    state.suppress_prompt_mode_return = suppression
    vim.schedule(function()
      if state.suppress_prompt_mode_return == suppression then
        state.suppress_prompt_mode_return = nil
      end
    end)
  end

  local function restore_command_output_fallback(key)
    if not state.command_output_fallback then
      return false
    end
    local ok, current_mode = pcall(vim.api.nvim_get_mode)
    local mode = ok and current_mode and current_mode.mode or ""
    local closes_prompt = mode == "r" or mode == "r?"
      or (mode == "rm" and (key == "q" or key == escape or key == "\3"))
    if closes_prompt then
      state.discard_pending_messages = true
      suppress_prompt_return()
      M.activate()
      return true
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

  local function begin_input_output_fallback()
    if not state.options.announce_messages
      or not state.active
      or state.command_line_active
      or state.terminal_fallback
      or menu_is_open()
    then
      return
    end
    local ok, current_mode = pcall(vim.api.nvim_get_mode)
    local mode = ok and current_mode and current_mode.mode or ""
    local kind = mode:sub(1, 1)
    if kind == "i" or kind == "R" or kind == "r" or kind == "!" or kind == "c" then
      return
    end
    state.command_output_fallback = true
    M.deactivate()
  end

  -- Prefer the mapping-expanded command input so mappings retain the behavior
  -- of their actions. The typed key is used only when an opaque Lua callback
  -- otherwise hides a conventional bracket-navigation action.
  vim.on_key(function(resolved_key, typed_key)
    if not state.enabled then
      return
    end
    local popup_handled, popup_consumed = handle_popup_menu_key(resolved_key)
    if popup_handled then
      schedule_message_poll()
      if popup_consumed then
        return ""
      end
      return
    end
    local prompt_key = restore_command_output_fallback(resolved_key)
    if not prompt_key then
      begin_input_output_fallback()
    end
    local bracket_command = bracket_motion_direction(state.cursor_motion_prefix) ~= nil
    record_edit_cursor_suppression(
      resolved_key,
      direct_edit_keys,
      escape,
      bracket_command
    )
    record_pending_put(resolved_key, put_keys)
    record_text_change_baseline(
      resolved_key,
      direct_deletion_keys,
      operator_edit_keys,
      bracket_command
    )
    record_cursor_motion(
      resolved_key,
      typed_key,
      special_cursor_motions,
      window_command
    )
    record_value_change(resolved_key, value_change_keys)
    if search_keys[resolved_key] and accepts_normal_motion() then
      schedule_search_announcement()
    end
    if state.command_line_active then
      local navigation = navigation_keys[resolved_key]
      if navigation then
        local pending = {
          navigation = navigation,
          level = state.command_line_level,
        }
        state.pending_command_navigation = pending
        vim.schedule(function()
          if state.enabled then
            announce_current_command_line(pending.navigation, pending.level)
          end
          if state.pending_command_navigation == pending then
            state.pending_command_navigation = nil
          end
        end)
      end
    end
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
  vim.schedule(function()
    if not state.enabled or not state.options.announce_floating_windows then
      return
    end
    if state.blink_menu_open then
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
    vim.defer_fn(scan, floating_window_scan_interval_ms)
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
    ui_send_available = type(vim.api.nvim_ui_send) == "function",
    enabled = state.enabled,
    active = state.active,
    terminal_fallback = state.terminal_fallback,
    text_put_post = autocmd_supported("TextPutPost"),
    search_wrapped = autocmd_supported("SearchWrapped"),
  }
end

function M.setup(options)
  if type(vim.api.nvim_ui_send) ~= "function" then
    return false
  end
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
  state.pending_command_navigation = nil
  state.pending_cursor_motion = nil
  state.cursor_motion_prefix = nil
  state.pending_value_change = nil
  state.pending_text_change = nil
  state.pending_put = nil
  state.put_prefix = nil
  state.structured_edit_ticks = {}
  state.edit_destination_ticks = {}
  state.put_announcement_ticks = {}
  state.pending_insert_diagnostics = {}
  state.suppress_next_cursor = nil
  state.suppress_edit_cursor = false
  state.suppress_visual_delete_mode_return = nil
  state.menu_states = {}
  state.current_menu_id = nil
  state.popup_menu = nil
  state.blink_menu_open = false
  state.blink_refresh_generation = state.blink_refresh_generation + 1
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
  state.search_announcement_generation = 0
  state.search_wrapped = false
  state.list_selections = {}
  state.fold_observation_generation = 0
  state.message_poll_scheduled = false
  state.message_history = read_message_history()
  state.buffer_announcement_generation = state.buffer_announcement_generation + 1
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
    announce_cursor(event.event)
  end)
  create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, function()
    announce_text_change()
    schedule_blink_completion_refresh()
  end)
  create_autocmd("CompleteChanged", refresh_native_completion)
  create_autocmd({ "CompleteDonePre", "CompleteDone" }, function()
    M.close_menu(native_completion_menu_id)
  end)
  create_autocmd("ModeChanged", announce_mode)
  create_autocmd("TextYankPost", announce_operator_edit)
  if autocmd_supported("TextPutPost") then
    create_autocmd("TextPutPost", announce_put_event)
  end
  if autocmd_supported("SearchWrapped") then
    create_autocmd("SearchWrapped", announce_search_wrapped)
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
    vim.schedule(function()
      if state.enabled then
        local current = snapshot()
        if current then
          announce_selected_list_destination(current)
        end
      end
    end)
  end)
  create_autocmd("MenuPopup", open_popup_menu)
  create_autocmd("DiagnosticChanged", announce_diagnostics)
  create_autocmd("CmdlineEnter", announce_command_line)
  create_autocmd("CmdlineChanged", function()
    M.activate()
    refresh_command_line_completion()
    if not state.pending_command_navigation then
      remember_command_line(state.command_line_level)
    end
  end)
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
    state.pending_command_navigation = nil
    M.close_menu(command_line_completion_menu_id)
    local restore_terminal_fallback = state.terminal_command_line
      and not state.command_line_active
    if restore_terminal_fallback then
      vim.schedule(function()
        state.terminal_command_line = false
        if state.enabled then
          M.activate()
        end
      end)
    elseif command_executed and not state.command_line_active then
      state.command_output_fallback = true
      M.deactivate()
    else
      M.activate()
    end
    schedule_message_poll()
    if search_executed then
      schedule_search_announcement()
    end
    if state.command_line_active then
      vim.schedule(function()
        remember_command_line(state.command_line_level)
      end)
    end
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = "BlinkCmpMenuOpen",
    callback = open_blink_completion,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = "BlinkCmpMenuClose",
    callback = close_blink_completion,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group_name,
    pattern = { "BlinkCmpListSelect", "BlinkCmpShow" },
    callback = function()
      vim.schedule(function()
        if state.enabled and state.blink_menu_open then
          refresh_blink_completion()
        end
      end)
    end,
  })
  create_autocmd("SafeState", schedule_message_poll)

  attach_input_listener()

  pcall(vim.api.nvim_create_user_command, "LectorSay", function(command)
    M.say(command.args)
  end, { nargs = "+" })
  pcall(vim.api.nvim_create_user_command, "LectorAccessibilityEnable", function()
    state.message_history = read_message_history()
    state.enabled = true
    M.activate()
  end, {})
  pcall(vim.api.nvim_create_user_command, "LectorAccessibilityDisable", function()
    close_all_menus()
    M.deactivate()
    state.enabled = false
  end, {})
  pcall(vim.api.nvim_create_user_command, "LectorCompletionDocumentation", function()
    if state.blink_menu_open then
      refresh_blink_completion()
    elseif state.command_line_active then
      refresh_command_line_completion()
    else
      refresh_native_completion()
    end
    M.read_menu_documentation()
  end, {})
  pcall(vim.api.nvim_create_user_command, "LectorStatus", function()
    M.announce_status()
  end, {})

  vim.schedule(function()
    if state.enabled then
      M.activate()
      announce_buffer()
    end
  end)
  return true
end

function M.teardown()
  state.closed_announcement_generation = state.closed_announcement_generation + 1
  close_all_menus()
  M.deactivate()
  state.enabled = false
  detach_input_listener()
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

return M
