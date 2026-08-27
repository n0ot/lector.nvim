-- SPDX-License-Identifier: MIT

local M = {}

local numeric_value_patterns = {
  "0[xX][0-9a-fA-F]+",
  "0[bB][01]+",
  "%-?%d+",
}

function M.word_at(line, column)
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

function M.word_at_or_after(line, column)
  local word = select(1, M.word_at(line, column))
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

function M.character_distance(text, first_column, second_column)
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

function M.snapshot()
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
  local word, word_start = M.word_at(line, cursor[2])
  local indentation = vim.fn.indent(cursor[1])
  local fold_start = vim.fn.foldclosed(cursor[1])
  local fold_end = fold_start >= 0 and vim.fn.foldclosedend(cursor[1]) or -1
  local ok_tick, changedtick = pcall(vim.api.nvim_buf_get_changedtick, buffer)
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
    changedtick = ok_tick and changedtick or nil,
  }
end

function M.spoken_line(current)
  return current.line:match("^%s*$") and "blank" or current.line
end

function M.spoken_character(character)
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

function M.spoken_deletion(text)
  text = tostring(text or "")
  local ok, size = pcall(vim.fn.strchars, text, true)
  size = ok and size or #text
  if size <= 1 then
    return M.spoken_character(text)
  end
  if text:match("^ +$") then
    return size .. " spaces"
  end
  if text:match("^\t+$") then
    return size .. " tabs"
  end
  if text:match("^%s+$") then
    return size .. " whitespace characters"
  end
  return text
end

function M.character_at_cursor(current)
  local tail = current.line:sub(current.column + 1)
  return M.spoken_character(vim.fn.strcharpart(tail, 0, 1))
end

function M.fold_line_count(current)
  if not current or current.fold_start < 0 or current.fold_end < current.fold_start then
    return nil
  end
  return current.fold_end - current.fold_start + 1
end

function M.visual_selection_summary(current)
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
    local characters = M.character_distance(current.line, current.column, anchor_column) + 1
    return characters .. (characters == 1 and " character selected" or " characters selected")
  end
  return rows .. " lines selected"
end

function M.changedtick(buffer)
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, buffer)
  return ok and tick or nil
end

function M.numeric_value_at_or_after(line, column)
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

function M.line_change(previous, current)
  if not previous or previous.buffer ~= current.buffer then
    return "unknown", "", ""
  end
  if previous.line_count < current.line_count then
    return "insertion", "", current.line
  end
  if previous.line_count > current.line_count then
    return "deletion", previous.line, ""
  end
  if previous.row ~= current.row then
    return "unknown", "", ""
  end
  local old = previous.line
  local new = current.line
  local first = 0
  local limit = math.min(#old, #new)
  while first < limit and old:byte(first + 1) == new:byte(first + 1) do
    first = first + 1
  end
  local suffix = 0
  while suffix < #old - first
    and suffix < #new - first
    and old:byte(#old - suffix) == new:byte(#new - suffix)
  do
    suffix = suffix + 1
  end
  local removed = old:sub(first + 1, #old - suffix)
  local added = new:sub(first + 1, #new - suffix)
  if #removed > #added then
    return "deletion", removed, added
  end
  if #added > #removed then
    return "insertion", removed, added
  end
  if removed ~= added then
    return "replacement", removed, added
  end
  return "unchanged", removed, added
end

function M.current_register()
  local register = vim.v.register
  if type(register) ~= "string" or register == "" then
    register = '"'
  end
  local ok_contents, contents = pcall(vim.fn.getreg, register, 1, true)
  local ok_type, regtype = pcall(vim.fn.getregtype, register)
  if not ok_contents or type(contents) ~= "table" or not ok_type then
    return nil
  end
  return {
    regcontents = contents,
    regtype = regtype,
  }
end

function M.changed_region_matches_register(input)
  local register = input and input.register or nil
  if not register or type(register.regcontents) ~= "table" then
    return false
  end
  local first = vim.fn.getpos("'[")
  local last = vim.fn.getpos("']")
  if type(first) ~= "table"
    or type(last) ~= "table"
    or tonumber(first[2]) == 0
    or tonumber(last[2]) == 0
  then
    return false
  end
  local ok, region = pcall(vim.fn.getregion, first, last, {
    type = register.regtype,
  })
  return ok and vim.deep_equal(region, register.regcontents)
end

return M
