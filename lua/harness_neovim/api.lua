local utils = require("harness_neovim.utils")
local ui = require("harness_neovim.ui")
local wait = require("harness_neovim.wait")

local M = {}

--- Normalize lines input into an array of strings
---@param lines string|string[]
---@return string[]
local function normalize_lines(lines)
  if type(lines) == "string" then
    lines = lines:gsub("\r\n", "\n"):gsub("\r", "\n")
    if not lines:find("\n") and lines:find("\\n") then
      lines = lines:gsub("\\n", "\n")
    end
    if lines:sub(-1) == "\n" then
      lines = lines:sub(1, -2)
    end
    return vim.split(lines, "\n", { plain = true })
  elseif type(lines) == "table" then
    local res = {}
    for _, l in ipairs(lines) do
      if type(l) == "string" and l:find("\n") then
        local sub = vim.split(l:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
        for _, s in ipairs(sub) do
          table.insert(res, s)
        end
      else
        table.insert(res, tostring(l))
      end
    end
    return res
  end
  return { tostring(lines) }
end

--------------------------------------------------------------------------------
-- 1. Execution & Evaluation
--------------------------------------------------------------------------------

--- Evaluate a Lua string and return its result
---@param code string
---@param args any[]?
---@return { success: boolean, result: any, error: string? }
function M.eval_lua(code, args)
  args = args or {}
  local chunk, err = loadstring("local args = { ... }; " .. code)
  if not chunk then
    chunk, err = loadstring("local args = { ... }; return " .. code)
  end
  if not chunk then
    return { success = false, error = tostring(err) }
  end

  local ok, res
  if type(args) == "table" then
    ok, res = pcall(chunk, unpack(args))
  else
    ok, res = pcall(chunk, args)
  end

  if not ok then
    return { success = false, error = tostring(res) }
  end
  return { success = true, result = res }
end

--- Evaluate a Vimscript expression
---@param expr string
---@return { success: boolean, result: any, error: string? }
function M.eval_vim(expr)
  local ok, res = pcall(vim.api.nvim_eval, expr)
  if not ok then
    return { success = false, error = tostring(res) }
  end
  return { success = true, result = res }
end

--- Execute a Vim Ex command and optionally capture output
---@param cmd string
---@param opts table?
---@return { success: boolean, output: string, error: string? }
function M.exec_cmd(cmd, opts)
  opts = opts or {}
  local ok, res = pcall(function()
    if vim.api.nvim_exec2 then
      local out = vim.api.nvim_exec2(cmd, { output = opts.output ~= false })
      return out.output or ""
    else
      return vim.api.nvim_exec(cmd, opts.output ~= false)
    end
  end)
  if not ok then
    return { success = false, output = "", error = tostring(res) }
  end
  return { success = true, output = res }
end

--- Send keystrokes to Neovim
---@param keys string
---@param mode string? (default: 'm' for remap, 'n' for no-remap, 't' for terminal)
---@return boolean
function M.feedkeys(keys, mode)
  mode = mode or "m"
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, mode, false)
  return true
end

--- Call a Lua function by dot-separated path (e.g. "vim.api.nvim_get_current_buf")
---@param fn_path string
---@param args any[]?
---@return { success: boolean, result: any, error: string? }
function M.call_function(fn_path, args)
  args = args or {}
  local parts = vim.split(fn_path, ".", { plain = true })
  local curr = _G
  for i, part in ipairs(parts) do
    if type(curr) ~= "table" then
      return { success = false, error = "Cannot resolve function path: " .. fn_path }
    end
    local next_val = curr[part]
    if next_val == nil and i == 1 then
      local req_ok, req_val = pcall(require, part)
      if req_ok then
        next_val = req_val
      end
    end
    if next_val == nil then
      return { success = false, error = "Symbol not found: " .. part .. " in " .. fn_path }
    end
    curr = next_val
  end

  if type(curr) ~= "function" then
    return { success = false, error = fn_path .. " is not a function (type: " .. type(curr) .. ")" }
  end

  local ok, res = pcall(curr, unpack(args))
  if not ok then
    return { success = false, error = tostring(res) }
  end
  return { success = true, result = res }
end

--------------------------------------------------------------------------------
-- 2. Buffer Management
--------------------------------------------------------------------------------

--- List all buffers with detailed information
---@return table[]
function M.list_buffers()
  local bufs = vim.api.nvim_list_bufs()
  local cur_buf = vim.api.nvim_get_current_buf()
  local result = {}

  for _, b in ipairs(bufs) do
    local is_loaded = vim.api.nvim_buf_is_loaded(b)
    local is_valid = vim.api.nvim_buf_is_valid(b)
    if is_valid then
      local name = vim.api.nvim_buf_get_name(b)
      local modified = is_loaded and vim.bo[b].modified or false
      local filetype = is_loaded and vim.bo[b].filetype or ""
      local buftype = is_loaded and vim.bo[b].buftype or ""
      local line_count = is_loaded and vim.api.nvim_buf_line_count(b) or 0
      local is_listed = vim.bo[b].buflisted

      table.insert(result, {
        bufnr = b,
        name = name,
        shortname = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
        loaded = is_loaded,
        modified = modified,
        listed = is_listed,
        filetype = filetype,
        buftype = buftype,
        line_count = line_count,
        current = (b == cur_buf),
      })
    end
  end

  return result
end

--- Get buffer content
---@param bufnr any (bufnr or buffer name or nil for current)
---@param start_line number? (1-indexed, inclusive, default: 1)
---@param end_line number? (1-indexed, inclusive, -1 for end, default: -1)
---@return { bufnr: number, name: string, lines: string[], line_count: number, filetype: string }
function M.get_buffer(bufnr, start_line, end_line)
  local b = utils.resolve_bufnr(bufnr)
  local total = vim.api.nvim_buf_line_count(b)

  start_line = start_line or 1
  end_line = end_line or -1

  local s0 = math.max(0, start_line - 1)
  local e0 = end_line == -1 and -1 or math.min(total, end_line)

  local lines = vim.api.nvim_buf_get_lines(b, s0, e0, false)
  local name = vim.api.nvim_buf_get_name(b)

  return {
    bufnr = b,
    name = name,
    lines = lines,
    line_count = #lines,
    total_lines = total,
    filetype = vim.bo[b].filetype,
  }
end

--- Set buffer lines
---@param bufnr any
---@param lines string[]|string
---@param start_line number? (1-indexed, default 1)
---@param end_line number? (1-indexed, -1 for end, default -1)
---@return { success: boolean, bufnr: number, line_count: number }
function M.set_buffer(bufnr, lines, start_line, end_line)
  local b = utils.resolve_bufnr(bufnr)
  local norm_lines = normalize_lines(lines)

  start_line = start_line or 1
  end_line = end_line or -1

  local s0 = math.max(0, start_line - 1)
  local e0 = end_line == -1 and -1 or end_line

  vim.api.nvim_buf_set_lines(b, s0, e0, false, norm_lines)
  return {
    success = true,
    bufnr = b,
    line_count = vim.api.nvim_buf_line_count(b),
  }
end

--- Append lines to buffer
---@param bufnr any
---@param lines string[]|string
---@param after_line number? (-1 for end of buffer, default: -1)
---@return { success: boolean, bufnr: number, line_count: number }
function M.append_buffer(bufnr, lines, after_line)
  local b = utils.resolve_bufnr(bufnr)
  local norm_lines = normalize_lines(lines)

  after_line = after_line or -1
  local total = vim.api.nvim_buf_line_count(b)
  local at0 = (after_line == -1 or after_line >= total) and total or after_line

  vim.api.nvim_buf_set_lines(b, at0, at0, false, norm_lines)
  return {
    success = true,
    bufnr = b,
    line_count = vim.api.nvim_buf_line_count(b),
  }
end

--- Create a new buffer
---@param opts table? { name: string, filetype: string, lines: string[], listed: boolean, scratch: boolean }
---@return { bufnr: number, name: string }
function M.create_buffer(opts)
  opts = opts or {}
  local listed = opts.listed ~= nil and opts.listed or true
  local scratch = opts.scratch or false
  local buf = vim.api.nvim_create_buf(listed, scratch)

  if opts.name and opts.name ~= "" then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end

  if opts.lines then
    local norm = normalize_lines(opts.lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, norm)
  end

  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  if opts.focus then
    vim.api.nvim_set_current_buf(buf)
  end

  return {
    bufnr = buf,
    name = vim.api.nvim_buf_get_name(buf),
  }
end

--- Delete / wipeout buffer
---@param bufnr any
---@param opts table? { force: boolean, unload: boolean }
---@return { success: boolean, bufnr: number }
function M.delete_buffer(bufnr, opts)
  opts = opts or {}
  local b = utils.resolve_bufnr(bufnr)
  local force = opts.force or false
  vim.api.nvim_buf_delete(b, { force = force, unload = opts.unload or false })
  return { success = true, bufnr = b }
end

--- Write / save buffer
---@param bufnr any
---@param filepath string?
---@return { success: boolean, bufnr: number, file: string }
function M.write_buffer(bufnr, filepath)
  local b = utils.resolve_bufnr(bufnr)
  local cur = vim.api.nvim_get_current_buf()
  local switched = false

  if b ~= cur then
    vim.api.nvim_set_current_buf(b)
    switched = true
  end

  if filepath and filepath ~= "" then
    vim.cmd("write " .. vim.fn.fnameescape(filepath))
  else
    vim.cmd("write")
  end

  if switched and vim.api.nvim_buf_is_valid(cur) then
    vim.api.nvim_set_current_buf(cur)
  end

  return {
    success = true,
    bufnr = b,
    file = vim.api.nvim_buf_get_name(b),
  }
end

--- Open a file in Neovim
---@param filepath string
---@param opts table? { split: string ("horizontal"|"vertical"|"tab"|"none"), line: number, col: number, wait: boolean }
---@return { bufnr: number, win_id: number, wait_token: string? }
function M.open_file(filepath, opts)
  opts = opts or {}
  local fullpath = vim.fn.fnamemodify(filepath, ":p")

  -- Check if file is already open in a window
  local target_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf) == fullpath then
        target_win = win
        break
      end
    end
  end

  if opts.split == "tab" or opts.tab then
    vim.cmd("tabedit " .. vim.fn.fnameescape(fullpath))
  elseif opts.split == "vertical" or opts.split == "vsplit" or opts.vsplit then
    vim.cmd("vsplit " .. vim.fn.fnameescape(fullpath))
  elseif opts.split == "horizontal" or opts.split == "split" or opts.split == true then
    vim.cmd("split " .. vim.fn.fnameescape(fullpath))
  else
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    else
      vim.cmd("edit " .. vim.fn.fnameescape(fullpath))
    end
  end

  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_get_current_buf()

  if opts.line then
    local line = tonumber(opts.line) or 1
    local col = tonumber(opts.col) or 1
    local max_lines = vim.api.nvim_buf_line_count(cur_buf)
    line = math.min(math.max(line, 1), max_lines)
    pcall(vim.api.nvim_win_set_cursor, cur_win, { line, col - 1 })
  end

  local wait_token = nil
  if opts.wait then
    wait_token = wait.register_waiter(cur_buf, opts)
  end

  return {
    bufnr = cur_buf,
    win_id = cur_win,
    file = fullpath,
    wait_token = wait_token,
  }
end

--------------------------------------------------------------------------------
-- 3. Cursor & Selection
--------------------------------------------------------------------------------

--- Get cursor position and current line text
---@param win_id any (win_id or nil for current)
---@return { line: number, col: number, bufnr: number, win_id: number, text: string, file: string }
function M.get_cursor(win_id)
  local w = utils.resolve_winid(win_id)
  local cursor = vim.api.nvim_win_get_cursor(w)
  local b = vim.api.nvim_win_get_buf(w)
  local line_idx = cursor[1]
  local col_idx = cursor[2]
  local line_text = ""
  if line_idx <= vim.api.nvim_buf_line_count(b) then
    local lines = vim.api.nvim_buf_get_lines(b, line_idx - 1, line_idx, false)
    line_text = lines[1] or ""
  end

  return {
    line = line_idx,
    col = col_idx + 1,
    bufnr = b,
    win_id = w,
    text = line_text,
    file = vim.api.nvim_buf_get_name(b),
  }
end

--- Set cursor position
---@param line number
---@param col number
---@param win_id any
---@return { success: boolean, line: number, col: number }
function M.set_cursor(line, col, win_id)
  local w = utils.resolve_winid(win_id)
  local b = vim.api.nvim_win_get_buf(w)
  local total = vim.api.nvim_buf_line_count(b)
  local l = math.min(math.max(tonumber(line) or 1, 1), total)
  local c = math.max(0, (tonumber(col) or 1) - 1)
  vim.api.nvim_win_set_cursor(w, { l, c })
  return { success = true, line = l, col = c + 1 }
end

--- Get visual selection text and range
---@return { text: string, lines: string[], start_pos: { line: number, col: number }, end_pos: { line: number, col: number }, mode: string }
function M.get_selection()
  local mode = vim.fn.mode()
  local is_visual = mode:match("[vV\22]")

  local start_pos, end_pos
  if is_visual then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
  end

  local s_line, s_col = start_pos[2], start_pos[3]
  local e_line, e_col = end_pos[2], end_pos[3]

  if s_line > e_line or (s_line == e_line and s_col > e_col) then
    s_line, e_line = e_line, s_line
    s_col, e_col = e_col, s_col
  end

  local buf = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  if s_line < 1 or s_line > total then
    return { text = "", lines = {}, start_pos = { line = 0, col = 0 }, end_pos = { line = 0, col = 0 }, mode = mode }
  end

  e_line = math.min(e_line, total)
  local raw_lines = vim.api.nvim_buf_get_lines(buf, s_line - 1, e_line, false)
  if #raw_lines == 0 then
    return { text = "", lines = {}, start_pos = { line = 0, col = 0 }, end_pos = { line = 0, col = 0 }, mode = mode }
  end

  local lines = {}
  if #raw_lines == 1 then
    lines = { string.sub(raw_lines[1], s_col, e_col) }
  else
    lines[1] = string.sub(raw_lines[1], s_col)
    for i = 2, #raw_lines - 1 do
      table.insert(lines, raw_lines[i])
    end
    table.insert(lines, string.sub(raw_lines[#raw_lines], 1, e_col))
  end

  return {
    text = table.concat(lines, "\n"),
    lines = lines,
    start_pos = { line = s_line, col = s_col },
    end_pos = { line = e_line, col = e_col },
    mode = is_visual and mode or vim.fn.visualmode(),
  }
end

--------------------------------------------------------------------------------
-- 4. Window & Tabpage Management
--------------------------------------------------------------------------------

--- List all open windows
---@return table[]
function M.list_windows()
  local wins = vim.api.nvim_list_wins()
  local cur_win = vim.api.nvim_get_current_win()
  local result = {}

  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      local tab = vim.api.nvim_win_get_tabpage(w)
      local tabnr = vim.api.nvim_tabpage_get_number(tab)
      local width = vim.api.nvim_win_get_width(w)
      local height = vim.api.nvim_win_get_height(w)
      local pos = vim.api.nvim_win_get_position(w)
      local cursor = vim.api.nvim_win_get_cursor(w)

      table.insert(result, {
        win_id = w,
        bufnr = b,
        buffer_name = vim.api.nvim_buf_get_name(b),
        tabnr = tabnr,
        width = width,
        height = height,
        row = pos[1],
        col = pos[2],
        cursor = { line = cursor[1], col = cursor[2] + 1 },
        current = (w == cur_win),
      })
    end
  end

  return result
end

--- Focus window by ID
---@param win_id any
---@return boolean
function M.focus_window(win_id)
  local w = utils.resolve_winid(win_id)
  vim.api.nvim_set_current_win(w)
  return true
end

--- Close window by ID
---@param win_id any
---@param force boolean?
---@return boolean
function M.close_window(win_id, force)
  local w = utils.resolve_winid(win_id)
  vim.api.nvim_win_close(w, force or false)
  return true
end

--- List tabpages
---@return table[]
function M.list_tabs()
  local tabs = vim.api.nvim_list_tabpages()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local result = {}

  for _, t in ipairs(tabs) do
    if vim.api.nvim_tabpage_is_valid(t) then
      local nr = vim.api.nvim_tabpage_get_number(t)
      local wins = vim.api.nvim_tabpage_list_wins(t)
      local win_ids = {}
      for _, w in ipairs(wins) do
        table.insert(win_ids, w)
      end

      table.insert(result, {
        tabnr = nr,
        tab_id = t,
        windows = win_ids,
        window_count = #win_ids,
        current = (t == cur_tab),
      })
    end
  end

  return result
end

--- Focus tabpage by number
---@param tabnr number
---@return boolean
function M.focus_tab(tabnr)
  local num = tonumber(tabnr) or 1
  vim.cmd("tabnext " .. tostring(num))
  return true
end

--------------------------------------------------------------------------------
-- 5. Diagnostics & LSP
--------------------------------------------------------------------------------

--- Get diagnostics for buffer or workspace
---@param opts table? { bufnr: any, severity: string|number }
---@return table[]
function M.get_diagnostics(opts)
  opts = opts or {}
  local bufnr = opts.bufnr and utils.resolve_bufnr(opts.bufnr) or nil
  local diags = vim.diagnostic.get(bufnr)
  local result = {}

  for _, d in ipairs(diags) do
    local sev_str = "HINT"
    if d.severity == vim.diagnostic.severity.ERROR then sev_str = "ERROR"
    elseif d.severity == vim.diagnostic.severity.WARN then sev_str = "WARN"
    elseif d.severity == vim.diagnostic.severity.INFO then sev_str = "INFO"
    end

    table.insert(result, {
      bufnr = d.bufnr,
      file = vim.api.nvim_buf_get_name(d.bufnr),
      lnum = d.lnum + 1,
      col = d.col + 1,
      end_lnum = (d.end_lnum or d.lnum) + 1,
      end_col = (d.end_col or d.col) + 1,
      severity = sev_str,
      message = d.message,
      source = d.source or "",
      code = d.code or "",
    })
  end

  return result
end

--- Get diagnostic counts
---@param bufnr any
---@return { error: number, warn: number, info: number, hint: number, total: number }
function M.get_diagnostic_counts(bufnr)
  local b = bufnr and utils.resolve_bufnr(bufnr) or nil
  local diags = vim.diagnostic.get(b)
  local counts = { error = 0, warn = 0, info = 0, hint = 0, total = #diags }

  for _, d in ipairs(diags) do
    if d.severity == vim.diagnostic.severity.ERROR then counts.error = counts.error + 1
    elseif d.severity == vim.diagnostic.severity.WARN then counts.warn = counts.warn + 1
    elseif d.severity == vim.diagnostic.severity.INFO then counts.info = counts.info + 1
    elseif d.severity == vim.diagnostic.severity.HINT then counts.hint = counts.hint + 1
    end
  end

  return counts
end

--- Get active LSP clients
---@param bufnr any
---@return table[]
function M.get_lsp_clients(bufnr)
  local b = bufnr and utils.resolve_bufnr(bufnr) or nil
  local clients = {}
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = b })
  else
    clients = vim.lsp.get_active_clients({ bufnr = b })
  end

  local result = {}
  for _, c in ipairs(clients) do
    table.insert(result, {
      id = c.id,
      name = c.name,
      root_dir = c.config.root_dir or "",
      attached_buffers = vim.tbl_keys(c.attached_buffers or {}),
    })
  end

  return result
end

--- Format current buffer using attached LSP
---@param bufnr any
---@return boolean
function M.format_buffer(bufnr)
  local b = utils.resolve_bufnr(bufnr)
  vim.lsp.buf.format({ bufnr = b, async = false })
  return true
end

--------------------------------------------------------------------------------
-- 6. Quickfix & Location List
--------------------------------------------------------------------------------

--- Get quickfix list
---@return table[]
function M.get_quickfix()
  local qf = vim.fn.getqflist()
  local result = {}
  for _, item in ipairs(qf) do
    local filename = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or ""
    table.insert(result, {
      bufnr = item.bufnr,
      filename = filename,
      lnum = item.lnum,
      col = item.col,
      text = item.text,
      type = item.type,
      valid = item.valid == 1,
    })
  end
  return result
end

--- Set quickfix list
---@param items table[]
---@param opts table? { title: string, open: boolean, action: string }
---@return boolean
function M.set_quickfix(items, opts)
  opts = opts or {}
  local qf_items = {}
  for _, it in ipairs(items) do
    table.insert(qf_items, {
      filename = it.filename or it.file,
      lnum = tonumber(it.lnum or it.line) or 1,
      col = tonumber(it.col or it.column) or 1,
      text = it.text or it.message or "",
      type = it.type or (it.severity and it.severity:sub(1, 1):upper() or "E"),
    })
  end

  vim.fn.setqflist(qf_items, opts.action or "r")
  if opts.title then
    vim.fn.setqflist({}, "a", { title = opts.title })
  end
  if opts.open then
    vim.cmd("copen")
  end
  return true
end

--- Clear quickfix list
---@return boolean
function M.clear_quickfix()
  vim.fn.setqflist({}, "r")
  return true
end

--------------------------------------------------------------------------------
-- 7. UI, Prompts & Diffs
--------------------------------------------------------------------------------

--- Show notification
function M.notify(msg, level, opts)
  return ui.notify(msg, level, opts)
end

--- Show floating window
function M.show_float(title, lines, opts)
  return ui.show_float(title, lines, opts)
end

--- Show diff
function M.show_diff(title, orig, mod, opts)
  return ui.show_diff(title, orig, mod, opts)
end

--------------------------------------------------------------------------------
-- 8. General State & Hot-Reload
--------------------------------------------------------------------------------

--- Hot reload the harness_neovim plugin
---@param opts table?
---@return { success: boolean, message: string }
function M.reload(opts)
  local ok, res = require("harness_neovim").reload(opts)
  return { success = ok, message = tostring(res) }
end

--- Get full editor state
---@return table
function M.get_state()
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(cur_win)
  local ver = vim.version()

  return {
    version = string.format("%d.%d.%d", ver.major, ver.minor, ver.patch),
    pid = vim.fn.getpid(),
    servername = vim.v.servername,
    cwd = vim.fn.getcwd(),
    mode = vim.fn.mode(),
    current_buf = cur_buf,
    current_file = vim.api.nvim_buf_get_name(cur_buf),
    current_win = cur_win,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    buffer_count = #vim.api.nvim_list_bufs(),
    window_count = #vim.api.nvim_list_wins(),
    tab_count = #vim.api.nvim_list_tabpages(),
  }
end

return M
