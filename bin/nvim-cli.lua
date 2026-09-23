#!/usr/bin/env -S nvim -l

local VERSION = "1.0.0"

--------------------------------------------------------------------------------
-- Utilities & Argument Parsing
--------------------------------------------------------------------------------

local function print_err(msg)
  io.stderr:write("nvim-cli error: " .. tostring(msg) .. "\n")
end

local function print_out(msg)
  io.stdout:write(tostring(msg) .. "\n")
end

local function read_stdin()
  local content = io.stdin:read("*all")
  return content or ""
end

local function parse_value(v)
  if v == "true" then return true end
  if v == "false" then return false end
  if v == "nil" or v == "null" then return nil end
  local num = tonumber(v)
  if num then return num end
  if type(v) == "string" and ((v:sub(1, 1) == "{" and v:sub(-1) == "}") or (v:sub(1, 1) == "[" and v:sub(-1) == "]")) then
    local ok, decoded = pcall(vim.json.decode, v)
    if ok then return decoded end
  end
  return v
end

--- Find active Neovim socket
local function find_socket(specified_server)
  if specified_server and specified_server ~= "" then
    return specified_server
  end

  if vim.env.NVIM and vim.env.NVIM ~= "" then
    return vim.env.NVIM
  end

  if vim.env.NVIM_LISTEN_ADDRESS and vim.env.NVIM_LISTEN_ADDRESS ~= "" then
    return vim.env.NVIM_LISTEN_ADDRESS
  end

  local search_dirs = { "/tmp", vim.env.XDG_RUNTIME_DIR }
  local uv = vim.uv or vim.loop
  for _, dir in ipairs(search_dirs) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      local matches = vim.fn.globpath(dir, "nvim*/*", true, true)
      for _, p in ipairs(matches) do
        local stat = uv.fs_stat(p)
        if stat and stat.type == "socket" then
          return p
        end
      end
    end
  end

  return nil
end

--- Connect to Neovim server via RPC
local function connect_rpc(server_path)
  local chan = vim.fn.sockconnect("pipe", server_path, { rpc = true })
  if chan <= 0 then
    print_err("Could not connect to Neovim at: " .. server_path)
    os.exit(1)
  end
  return chan
end

--- RPC helper: call remote lua code
local function rpc_lua(chan, code, args)
  local wrapped = [[
    local has_plugin, plugin = pcall(require, "harness_neovim")
    local code, args = ...
    if has_plugin and plugin.api then
      return plugin.api.eval_lua(code, args)
    end
    -- Fallback if plugin is not in runtimepath
    local chunk, err = loadstring("local args = ...; " .. code)
    if not chunk then
      chunk, err = loadstring("local args = ...; return " .. code)
    end
    if not chunk then
      return { success = false, error = tostring(err) }
    end
    local ok, res = pcall(chunk, args)
    if not ok then
      return { success = false, error = tostring(res) }
    end
    return { success = true, result = res }
  ]]
  return vim.fn.rpcrequest(chan, "nvim_exec_lua", wrapped, { code, args or {} })
end

--- Remote pure Lua API fallback bundle
local REMOTE_API_LUA = [=[
local method_name, args = ...

local has_plugin, plugin = pcall(require, "harness_neovim")
if has_plugin and plugin.api and plugin.api[method_name] then
  return plugin.api[method_name](unpack(args or {}))
end

-- Pure Lua fallback implementation (zero dependencies, works on any Neovim)
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
        for _, s in ipairs(sub) do table.insert(res, s) end
      else
        table.insert(res, tostring(l))
      end
    end
    return res
  end
  return { tostring(lines) }
end

local function resolve_bufnr(buf)
  if buf == nil or buf == 0 or buf == "" then
    return vim.api.nvim_get_current_buf()
  end
  local num = tonumber(buf)
  if num and vim.api.nvim_buf_is_valid(num) then
    return num
  end
  local target = vim.fn.fnamemodify(tostring(buf), ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name == buf or name == target or vim.fn.fnamemodify(name, ":t") == buf then
      return b
    end
  end
  error("Buffer not found: " .. tostring(buf))
end

local function resolve_winid(win)
  if win == nil or win == 0 or win == "" then
    return vim.api.nvim_get_current_win()
  end
  local num = tonumber(win)
  if num and vim.api.nvim_win_is_valid(num) then
    return num
  end
  error("Invalid window ID: " .. tostring(win))
end

local function parse_level(level)
  if type(level) == "number" then return level end
  if type(level) == "string" then
    local l = level:lower()
    if l == "debug" or l == "trace" then return vim.log.levels.DEBUG
    elseif l == "info" then return vim.log.levels.INFO
    elseif l == "warn" or l == "warning" then return vim.log.levels.WARN
    elseif l == "error" or l == "err" then return vim.log.levels.ERROR
    end
  end
  return vim.log.levels.INFO
end

local fallback_api = {}

function fallback_api.exec_cmd(cmd, opts)
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

function fallback_api.feedkeys(keys, mode)
  mode = mode or "m"
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, mode, false)
  return true
end

function fallback_api.call_function(fn_path, fn_args)
  fn_args = fn_args or {}
  local parts = vim.split(fn_path, ".", { plain = true })
  local curr = _G
  for i, part in ipairs(parts) do
    if type(curr) ~= "table" then
      return { success = false, error = "Cannot resolve function path: " .. fn_path }
    end
    local next_val = curr[part]
    if next_val == nil and i == 1 then
      local req_ok, req_val = pcall(require, part)
      if req_ok then next_val = req_val end
    end
    if next_val == nil then
      return { success = false, error = "Symbol not found: " .. part .. " in " .. fn_path }
    end
    curr = next_val
  end
  if type(curr) ~= "function" then
    return { success = false, error = fn_path .. " is not a function (type: " .. type(curr) .. ")" }
  end
  local ok, res = pcall(curr, unpack(fn_args))
  if not ok then
    return { success = false, error = tostring(res) }
  end
  return { success = true, result = res }
end

function fallback_api.list_buffers()
  local bufs = vim.api.nvim_list_bufs()
  local cur_buf = vim.api.nvim_get_current_buf()
  local result = {}
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      local is_loaded = vim.api.nvim_buf_is_loaded(b)
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

function fallback_api.get_buffer(bufnr, start_line, end_line)
  local b = resolve_bufnr(bufnr)
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

function fallback_api.set_buffer(bufnr, lines, start_line, end_line)
  local b = resolve_bufnr(bufnr)
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

function fallback_api.append_buffer(bufnr, lines, after_line)
  local b = resolve_bufnr(bufnr)
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

function fallback_api.create_buffer(opts)
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

function fallback_api.delete_buffer(bufnr, opts)
  opts = opts or {}
  local b = resolve_bufnr(bufnr)
  vim.api.nvim_buf_delete(b, { force = opts.force or false, unload = opts.unload or false })
  return { success = true, bufnr = b }
end

function fallback_api.write_buffer(bufnr, filepath)
  local b = resolve_bufnr(bufnr)
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

function fallback_api.open_file(filepath, opts)
  opts = opts or {}
  local fullpath = vim.fn.fnamemodify(filepath, ":p")
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
  return {
    bufnr = cur_buf,
    win_id = cur_win,
    file = fullpath,
  }
end

function fallback_api.get_cursor(win_id)
  local w = resolve_winid(win_id)
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

function fallback_api.set_cursor(line, col, win_id)
  local w = resolve_winid(win_id)
  local b = vim.api.nvim_win_get_buf(w)
  local total = vim.api.nvim_buf_line_count(b)
  local l = math.min(math.max(tonumber(line) or 1, 1), total)
  local c = math.max(0, (tonumber(col) or 1) - 1)
  vim.api.nvim_win_set_cursor(w, { l, c })
  return { success = true, line = l, col = c + 1 }
end

function fallback_api.get_selection()
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

function fallback_api.list_windows()
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

function fallback_api.focus_window(win_id)
  local w = resolve_winid(win_id)
  vim.api.nvim_set_current_win(w)
  return true
end

function fallback_api.close_window(win_id, force)
  local w = resolve_winid(win_id)
  vim.api.nvim_win_close(w, force or false)
  return true
end

function fallback_api.list_tabs()
  local tabs = vim.api.nvim_list_tabpages()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local result = {}
  for _, t in ipairs(tabs) do
    if vim.api.nvim_tabpage_is_valid(t) then
      local nr = vim.api.nvim_tabpage_get_number(t)
      local wins = vim.api.nvim_tabpage_list_wins(t)
      local win_ids = {}
      for _, w in ipairs(wins) do table.insert(win_ids, w) end
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

function fallback_api.focus_tab(tabnr)
  local num = tonumber(tabnr) or 1
  vim.cmd("tabnext " .. tostring(num))
  return true
end

function fallback_api.notify(msg, level, opts)
  opts = opts or {}
  local lvl = parse_level(level)
  local title = opts.title or "Nvim-CLI"
  vim.notify(tostring(msg), lvl, { title = title, timeout = opts.timeout })
  return true
end

function fallback_api.show_float(title, lines, opts)
  opts = opts or {}
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = opts.modifiable or false
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  local max_line_len = 0
  for _, line in ipairs(lines) do
    if #line > max_line_len then max_line_len = #line end
  end
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local width = opts.width or math.min(math.max(max_line_len + 4, 40), math.floor(editor_width * 0.85))
  local height = opts.height or math.min(math.max(#lines, 1), math.floor(editor_height * 0.75))
  local row = opts.row or math.floor((editor_height - height) / 2)
  local col = opts.col or math.floor((editor_width - width) / 2)
  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "center" or nil,
  }
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = opts.wrap ~= nil and opts.wrap or true
  vim.wo[win].cursorline = opts.cursorline or false
  local close_keys = { "q", "<Esc>" }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "Close floating window" })
  end
  return { win_id = win, bufnr = buf }
end

function fallback_api.show_diff(title, original_lines, modified_lines, opts)
  opts = opts or {}
  vim.cmd("tabnew")
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(orig_buf, (title or "Diff") .. " (Original)")
  vim.cmd("diffthis")
  vim.cmd("vsplit")
  local mod_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(mod_buf)
  vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, modified_lines)
  vim.bo[mod_buf].buftype = "nofile"
  vim.bo[mod_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(mod_buf, (title or "Diff") .. " (Modified)")
  vim.cmd("diffthis")
  return { orig_buf = orig_buf, mod_buf = mod_buf }
end

function fallback_api.get_quickfix()
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

function fallback_api.set_quickfix(items, opts)
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

function fallback_api.clear_quickfix()
  vim.fn.setqflist({}, "r")
  return true
end

function fallback_api.get_diagnostics(opts)
  opts = opts or {}
  local bufnr = opts.bufnr and resolve_bufnr(opts.bufnr) or nil
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

function fallback_api.get_diagnostic_counts(bufnr)
  local b = bufnr and resolve_bufnr(bufnr) or nil
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

function fallback_api.get_lsp_clients(bufnr)
  local b = bufnr and resolve_bufnr(bufnr) or nil
  local clients = {}
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = b })
  elseif vim.lsp.get_active_clients then
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

function fallback_api.format_buffer(bufnr)
  local b = resolve_bufnr(bufnr)
  vim.lsp.buf.format({ bufnr = b, async = false })
  return true
end

function fallback_api.get_state()
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

function fallback_api.reload(opts)
  local has_p, p = pcall(require, "harness_neovim")
  if has_p and p.reload then
    local ok, res = p.reload(opts)
    return { success = ok, message = tostring(res) }
  end
  return { success = true, message = "No harness_neovim plugin loaded to reload" }
end

if fallback_api[method_name] then
  return fallback_api[method_name](unpack(args or {}))
end

error("API method " .. tostring(method_name) .. " not found")
]=]

--- RPC helper: call API function with pure Lua fallback
local function rpc_api(chan, method_name, args)
  local ok, res = pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", REMOTE_API_LUA, { method_name, args or {} })
  if not ok then
    return false, res
  end
  return true, res
end

--------------------------------------------------------------------------------
-- Global Help
--------------------------------------------------------------------------------

local function print_help()
  local help = [[
nvim-cli - Control and interact with a running Neovim instance from the command line

USAGE:
  nvim-cli [global options] <command> [command options] [arguments...]

GLOBAL OPTIONS:
  -s, --server <path>   Neovim RPC socket path (default: $NVIM or auto-detected)
  -j, --json            Output results as formatted JSON
  -q, --quiet           Suppress standard output
  -v, --version         Show version information
  -h, --help            Show this help text

COMMANDS:
  lua, eval <code...>   Execute arbitrary Lua code in Neovim
  vim, expr <expr>      Evaluate a Vimscript expression
  exec, cmd <cmd...>    Execute a Vim Ex command (e.g. "write", "set number")
  keys, send <keys>     Send keystrokes (e.g. "<Esc>:w<CR>")
  call <fn> [args...]   Call a Lua function with arguments

  open <file>           Open a file in the active Neovim window
  split <file>          Open a file in a horizontal split
  vsplit <file>         Open a file in a vertical split
  tabopen <file>        Open a file in a new tab
  edit [-w|--wait] <f>  Open file and optionally wait until closed ($EDITOR mode)

  buffer, buf           Manage buffers:
    buffer list         List all active buffers
    buffer get [buf]    Get buffer lines
    buffer set [buf]    Replace buffer content (from args or stdin)
    buffer append [buf] Append lines to buffer (from args or stdin)
    buffer new [name]   Create a new buffer
    buffer delete [buf] Delete a buffer
    buffer write [buf]  Save buffer to disk

  cursor                Inspect and move cursor:
    cursor get [win]    Get line and column of cursor
    cursor set <l> <c>  Move cursor to line and column
    cursor text         Get text of the current line

  selection, sel        Visual selection:
    selection get       Get text of current or last visual selection
    selection range     Get start and end positions of selection

  window, win           Manage windows:
    window list         List open windows and layout
    window focus <id>   Focus a window
    window close <id>   Close a window

  tab                   Manage tabs:
    tab list            List open tabpages
    tab focus <nr>      Focus tabpage
    tab new [file]      Open new tabpage

  notify <msg...>       Show a notification popup in Neovim (--level info|warn|error)
  float <title> [body]  Display floating window (reads body from args or stdin)
  diff <file1> <file2>  Open side-by-side diff in Neovim
  quickfix, qf          Manage quickfix list (list, set, clear)
  diagnostics, diag     Query LSP diagnostics (list, count)
  lsp                   Query LSP clients (list, format)

  reload                Hot-reload harness_neovim plugin Lua modules in Neovim
  status, info          Display Neovim editor status, PID, cwd, version
  server                Print the active Neovim server socket path
  listen [events...]    Stream Neovim autocmd events in real time

EXAMPLES:
  # Evaluate Lua
  nvim-cli eval "return vim.api.nvim_get_current_buf()"

  # Hot reload plugin
  nvim-cli reload

  # Set current buffer content from stdin
  cat data.txt | nvim-cli buffer set

  # Display floating output in Neovim
  git diff | nvim-cli float "Git Diff"

  # Use as $EDITOR for git commit inside Neovim terminal
  nvim-cli edit --wait COMMIT_EDITMSG
]]
  print_out(help)
end

--------------------------------------------------------------------------------
-- Main CLI Entry Point
--------------------------------------------------------------------------------

local function main()
  local args = _G.arg or {}
  if #args == 0 then
    print_help()
    return 0
  end

  local global_opts = {
    server = nil,
    json = false,
    quiet = false,
  }

  local cmd = nil
  local sub_args = {}
  local i = 1

  while i <= #args do
    local a = args[i]
    if not cmd then
      if a == "-h" or a == "--help" or a == "help" then
        print_help()
        return 0
      elseif a == "-v" or a == "--version" or a == "version" then
        print_out("nvim-cli version " .. VERSION)
        return 0
      elseif a == "-j" or a == "--json" then
        global_opts.json = true
      elseif a == "-q" or a == "--quiet" then
        global_opts.quiet = true
      elseif a == "-s" or a == "--server" then
        i = i + 1
        global_opts.server = args[i]
      elseif a:sub(1, 1) == "-" then
        print_err("Unknown option: " .. a)
        return 1
      else
        cmd = a
      end
    else
      table.insert(sub_args, a)
    end
    i = i + 1
  end

  if not cmd then
    print_help()
    return 0
  end

  -- Output helper
  local function output_val(val)
    if global_opts.quiet then return end
    if global_opts.json then
      if type(val) == "string" and ((val:sub(1, 1) == "{" and val:sub(-1) == "}") or (val:sub(1, 1) == "[" and val:sub(-1) == "]")) then
        print_out(val)
      else
        local ok, encoded = pcall(vim.json.encode, val)
        if ok then
          print_out(encoded)
        else
          print_out(vim.inspect(val))
        end
      end
    else
      if val == nil then return end
      if type(val) == "string" then
        print_out(val)
      elseif type(val) == "number" or type(val) == "boolean" then
        print_out(tostring(val))
      elseif type(val) == "table" then
        local is_list_of_strings = #val > 0
        for _, it in ipairs(val) do
          if type(it) ~= "string" then
            is_list_of_strings = false
            break
          end
        end
        if is_list_of_strings then
          print_out(table.concat(val, "\n"))
        else
          local ok, encoded = pcall(vim.json.encode, val)
          if ok then
            print_out(encoded)
          else
            print_out(vim.inspect(val))
          end
        end
      else
        print_out(tostring(val))
      end
    end
  end

  -- COMMAND: server (does not require connection)
  if cmd == "server" or cmd == "socket" then
    local sock = find_socket(global_opts.server)
    if not sock then
      print_err("No active Neovim server socket found")
      return 1
    end
    output_val(sock)
    return 0
  end

  -- Connect to Neovim
  local server_path = find_socket(global_opts.server)
  if not server_path then
    print_err("No active Neovim instance detected. Set $NVIM or use --server <path>")
    return 1
  end

  local chan = connect_rpc(server_path)

  ------------------------------------------------------------------------------
  -- COMMAND: lua / eval
  ------------------------------------------------------------------------------
  if cmd == "lua" or cmd == "eval" then
    local code
    if #sub_args == 0 or sub_args[1] == "-" then
      code = read_stdin()
    else
      code = table.concat(sub_args, " ")
    end

    if not code or code == "" then
      print_err("No Lua code provided")
      vim.fn.chanclose(chan)
      return 1
    end

    local res = rpc_lua(chan, code, {})
    vim.fn.chanclose(chan)
    if not res.success then
      print_err(res.error or "Lua evaluation failed")
      return 1
    end
    output_val(res.result)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: reload (hot reload)
  ------------------------------------------------------------------------------
  elseif cmd == "reload" then
    local ok, res = rpc_api(chan, "reload", {})
    vim.fn.chanclose(chan)
    if not ok or (res and not res.success) then
      print_err((res and res.error) or (res and res.message) or "Failed to hot-reload plugin")
      return 1
    end
    if global_opts.json then
      output_val(res)
    else
      print_out("⚡ Plugin hot-reloaded successfully!")
    end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: vim / expr
  ------------------------------------------------------------------------------
  elseif cmd == "vim" or cmd == "expr" then
    local expr = table.concat(sub_args, " ")
    if expr == "" then
      print_err("No expression provided")
      vim.fn.chanclose(chan)
      return 1
    end
    local ok, res = pcall(vim.fn.rpcrequest, chan, "nvim_eval", expr)
    vim.fn.chanclose(chan)
    if not ok then
      print_err(res)
      return 1
    end
    output_val(res)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: exec / cmd
  ------------------------------------------------------------------------------
  elseif cmd == "exec" or cmd == "cmd" then
    local ex_cmd = table.concat(sub_args, " ")
    if ex_cmd == "" then
      print_err("No command provided")
      vim.fn.chanclose(chan)
      return 1
    end
    local ok, res = rpc_api(chan, "exec_cmd", { ex_cmd, { output = true } })
    vim.fn.chanclose(chan)
    if not ok or (res and not res.success) then
      print_err((res and res.error) or "Failed to execute command")
      return 1
    end
    if res.output and res.output ~= "" then
      output_val(res.output)
    end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: keys / send
  ------------------------------------------------------------------------------
  elseif cmd == "keys" or cmd == "send" then
    local keys = table.concat(sub_args, " ")
    local ok, res = rpc_api(chan, "feedkeys", { keys, "m" })
    vim.fn.chanclose(chan)
    if not ok then
      print_err(res)
      return 1
    end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: call
  ------------------------------------------------------------------------------
  elseif cmd == "call" then
    local fn_name = sub_args[1]
    if not fn_name then
      print_err("Usage: nvim-cli call <function_name> [args...]")
      vim.fn.chanclose(chan)
      return 1
    end
    table.remove(sub_args, 1)
    local fn_args = {}
    for _, a in ipairs(sub_args) do
      table.insert(fn_args, parse_value(a))
    end
    local ok, res = rpc_api(chan, "call_function", { fn_name, fn_args })
    vim.fn.chanclose(chan)
    if not ok or (res and not res.success) then
      print_err((res and res.error) or "Function call failed")
      return 1
    end
    output_val(res.result)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: open / split / vsplit / tabopen / edit
  ------------------------------------------------------------------------------
  elseif cmd == "open" or cmd == "split" or cmd == "vsplit" or cmd == "tabopen" or cmd == "edit" then
    local file = nil
    local wait_mode = false
    local line_num = nil
    local col_num = nil

    local k = 1
    while k <= #sub_args do
      local a = sub_args[k]
      if a == "-w" or a == "--wait" then
        wait_mode = true
      elseif a == "-l" or a == "--line" then
        k = k + 1
        line_num = tonumber(sub_args[k])
      elseif a == "-c" or a == "--col" then
        k = k + 1
        col_num = tonumber(sub_args[k])
      elseif a:sub(1, 1) ~= "-" and not file then
        file = a
      end
      k = k + 1
    end

    if not file then
      print_err("Usage: nvim-cli " .. cmd .. " [-w|--wait] [--line N] <filename>")
      vim.fn.chanclose(chan)
      return 1
    end

    local split_mode = "none"
    if cmd == "split" then split_mode = "horizontal"
    elseif cmd == "vsplit" then split_mode = "vertical"
    elseif cmd == "tabopen" then split_mode = "tab"
    end

    local ok, res = rpc_api(chan, "open_file", { file, { split = split_mode, line = line_num, col = col_num, wait = wait_mode } })
    if not ok then
      print_err(res)
      vim.fn.chanclose(chan)
      return 1
    end

    if not wait_mode then
      vim.fn.chanclose(chan)
      output_val(res)
      return 0
    end

    -- Blocking wait mode
    local bufnr = res.bufnr
    while true do
      local valid_ok, is_valid = pcall(vim.fn.rpcrequest, chan, "nvim_buf_is_valid", bufnr)
      if not valid_ok or not is_valid then
        break
      end
      vim.uv.sleep(80)
    end
    vim.fn.chanclose(chan)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: buffer / buf
  ------------------------------------------------------------------------------
  elseif cmd == "buffer" or cmd == "buf" then
    local sub = sub_args[1] or "list"
    table.remove(sub_args, 1)

    if sub == "list" or sub == "ls" then
      local ok, res = rpc_api(chan, "list_buffers", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      if global_opts.json then
        output_val(res)
      else
        print_out(string.format("%-5s %-3s %-6s %-12s %s", "BUF", "ACT", "MOD", "FT", "NAME"))
        print_out(string.rep("-", 60))
        for _, b in ipairs(res) do
          local act = b.current and "%" or (b.loaded and "a" or "h")
          local mod = b.modified and "[+]" or ""
          print_out(string.format("%-5d %-3s %-6s %-12s %s", b.bufnr, act, mod, b.filetype, b.shortname))
        end
      end
      return 0

    elseif sub == "get" or sub == "cat" or sub == "read" then
      local target_buf = sub_args[1]
      local ok, res = rpc_api(chan, "get_buffer", { target_buf })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      if global_opts.json then
        output_val(res)
      else
        print_out(table.concat(res.lines, "\n"))
      end
      return 0

    elseif sub == "set" or sub == "write" or sub == "put" then
      local target_buf = nil
      local content = nil

      if #sub_args > 0 then
        if tonumber(sub_args[1]) or sub_args[1]:match("^%d+$") then
          target_buf = sub_args[1]
          table.remove(sub_args, 1)
        end
      end

      if #sub_args > 0 then
        content = table.concat(sub_args, " ")
      else
        content = read_stdin()
      end

      local ok, res = rpc_api(chan, "set_buffer", { target_buf, content })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "append" then
      local target_buf = nil
      local content = nil
      if #sub_args > 0 and (tonumber(sub_args[1]) or sub_args[1]:match("^%d+$")) then
        target_buf = sub_args[1]
        table.remove(sub_args, 1)
      end
      if #sub_args > 0 then
        content = table.concat(sub_args, " ")
      else
        content = read_stdin()
      end
      local ok, res = rpc_api(chan, "append_buffer", { target_buf, content })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "new" or sub == "create" then
      local name = sub_args[1]
      local ok, res = rpc_api(chan, "create_buffer", { { name = name, focus = true } })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "delete" or sub == "del" or sub == "close" then
      local target_buf = sub_args[1]
      local ok, res = rpc_api(chan, "delete_buffer", { target_buf, { force = true } })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "save" or sub == "writefile" then
      local target_buf = sub_args[1]
      local filepath = sub_args[2]
      local ok, res = rpc_api(chan, "write_buffer", { target_buf, filepath })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    else
      print_err("Unknown buffer subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: cursor
  ------------------------------------------------------------------------------
  elseif cmd == "cursor" then
    local sub = sub_args[1] or "get"
    table.remove(sub_args, 1)

    if sub == "get" then
      local win_id = sub_args[1]
      local ok, res = rpc_api(chan, "get_cursor", { win_id })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      if global_opts.json then
        output_val(res)
      else
        print_out(string.format("Line: %d, Col: %d (File: %s)", res.line, res.col, res.file ~= "" and res.file or "[No Name]"))
        print_out("Text: " .. res.text)
      end
      return 0

    elseif sub == "set" then
      local line = tonumber(sub_args[1]) or 1
      local col = tonumber(sub_args[2]) or 1
      local win_id = sub_args[3]
      local ok, res = rpc_api(chan, "set_cursor", { line, col, win_id })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "text" then
      local ok, res = rpc_api(chan, "get_cursor", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      print_out(res.text)
      return 0

    else
      print_err("Unknown cursor subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: selection / sel
  ------------------------------------------------------------------------------
  elseif cmd == "selection" or cmd == "sel" then
    local sub = sub_args[1] or "get"
    local ok, res = rpc_api(chan, "get_selection", {})
    vim.fn.chanclose(chan)
    if not ok then print_err(res); return 1 end

    if sub == "range" or global_opts.json then
      output_val(res)
    else
      print_out(res.text)
    end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: window / win
  ------------------------------------------------------------------------------
  elseif cmd == "window" or cmd == "win" then
    local sub = sub_args[1] or "list"
    table.remove(sub_args, 1)

    if sub == "list" or sub == "ls" then
      local ok, res = rpc_api(chan, "list_windows", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      if global_opts.json then
        output_val(res)
      else
        print_out(string.format("%-8s %-6s %-6s %-12s %s", "WIN_ID", "BUF", "TAB", "DIMENSIONS", "CURRENT"))
        print_out(string.rep("-", 50))
        for _, w in ipairs(res) do
          local dims = string.format("%dx%d", w.width, w.height)
          print_out(string.format("%-8d %-6d %-6d %-12s %s", w.win_id, w.bufnr, w.tabnr, dims, w.current and "yes" or "no"))
        end
      end
      return 0

    elseif sub == "focus" then
      local win_id = sub_args[1]
      local ok, res = rpc_api(chan, "focus_window", { win_id })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true, focused_window = win_id })
      return 0

    elseif sub == "close" then
      local win_id = sub_args[1]
      local ok, res = rpc_api(chan, "close_window", { win_id, true })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true, closed_window = win_id })
      return 0

    else
      print_err("Unknown window subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: tab
  ------------------------------------------------------------------------------
  elseif cmd == "tab" then
    local sub = sub_args[1] or "list"
    table.remove(sub_args, 1)

    if sub == "list" or sub == "ls" then
      local ok, res = rpc_api(chan, "list_tabs", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "focus" then
      local tabnr = tonumber(sub_args[1]) or 1
      local ok, res = rpc_api(chan, "focus_tab", { tabnr })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true, focused_tab = tabnr })
      return 0

    elseif sub == "new" then
      local file = sub_args[1]
      local ok, res = rpc_api(chan, "open_file", { file or "", { split = "tab" } })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    else
      print_err("Unknown tab subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: notify
  ------------------------------------------------------------------------------
  elseif cmd == "notify" then
    local level = "info"
    local title = "Nvim-CLI"
    local msg_parts = {}

    local k = 1
    while k <= #sub_args do
      local a = sub_args[k]
      if a == "--level" or a == "-l" then
        k = k + 1
        level = sub_args[k] or "info"
      elseif a == "--title" or a == "-t" then
        k = k + 1
        title = sub_args[k] or "Nvim-CLI"
      else
        table.insert(msg_parts, a)
      end
      k = k + 1
    end

    local message = table.concat(msg_parts, " ")
    if message == "" then
      message = read_stdin()
    end

    local ok, res = rpc_api(chan, "notify", { message, level, { title = title } })
    vim.fn.chanclose(chan)
    if not ok then print_err(res); return 1 end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: float
  ------------------------------------------------------------------------------
  elseif cmd == "float" or cmd == "popup" then
    local title = sub_args[1] or "Nvim-CLI Output"
    table.remove(sub_args, 1)

    local content
    if #sub_args > 0 then
      content = table.concat(sub_args, " ")
    else
      content = read_stdin()
    end

    local ok, res = rpc_api(chan, "show_float", { title, content, { border = "rounded" } })
    vim.fn.chanclose(chan)
    if not ok then print_err(res); return 1 end
    output_val(res)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: diff
  ------------------------------------------------------------------------------
  elseif cmd == "diff" then
    local f1 = sub_args[1]
    local f2 = sub_args[2]
    if not f1 or not f2 then
      print_err("Usage: nvim-cli diff <file1> <file2>")
      vim.fn.chanclose(chan)
      return 1
    end

    local f1_content = vim.fn.readfile(f1)
    local f2_content = vim.fn.readfile(f2)
    local ok, res = rpc_api(chan, "show_diff", { f1 .. " vs " .. f2, f1_content, f2_content })
    vim.fn.chanclose(chan)
    if not ok then print_err(res); return 1 end
    output_val(res)
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: quickfix / qf
  ------------------------------------------------------------------------------
  elseif cmd == "quickfix" or cmd == "qf" then
    local sub = sub_args[1] or "list"
    table.remove(sub_args, 1)

    if sub == "list" or sub == "ls" then
      local ok, res = rpc_api(chan, "get_quickfix", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "clear" then
      local ok, res = rpc_api(chan, "clear_quickfix", {})
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true })
      return 0

    elseif sub == "set" then
      local payload = #sub_args > 0 and table.concat(sub_args, " ") or read_stdin()
      local items = parse_value(payload)
      if type(items) ~= "table" then
        print_err("Expected JSON array of quickfix items")
        vim.fn.chanclose(chan)
        return 1
      end
      local ok, res = rpc_api(chan, "set_quickfix", { items, { open = true } })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true, count = #items })
      return 0

    else
      print_err("Unknown quickfix subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: diagnostics / diag
  ------------------------------------------------------------------------------
  elseif cmd == "diagnostics" or cmd == "diag" then
    local sub = sub_args[1] or "list"
    if sub == "count" or sub == "counts" then
      local ok, res = rpc_api(chan, "get_diagnostic_counts", { sub_args[2] })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0
    else
      local target_buf = (sub ~= "list" and sub) or sub_args[2]
      local ok, res = rpc_api(chan, "get_diagnostics", { { bufnr = target_buf } })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      if global_opts.json then 
        output_val(res)
      else
        for _, d in ipairs(res) do
          print_out(string.format("[%s] %s:%d:%d: %s (%s)", d.severity, d.file ~= "" and vim.fn.fnamemodify(d.file, ":t") or "buf", d.lnum, d.col, d.message, d.source))
        end
      end
      return 0
    end

  ------------------------------------------------------------------------------
  -- COMMAND: lsp
  ------------------------------------------------------------------------------
  elseif cmd == "lsp" then
    local sub = sub_args[1] or "list"
    table.remove(sub_args, 1)

    if sub == "list" or sub == "ls" then
      local ok, res = rpc_api(chan, "get_lsp_clients", { sub_args[1] })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val(res)
      return 0

    elseif sub == "format" then
      local ok, res = rpc_api(chan, "format_buffer", { sub_args[1] })
      vim.fn.chanclose(chan)
      if not ok then print_err(res); return 1 end
      output_val({ success = true })
      return 0

    else
      print_err("Unknown LSP subcommand: " .. sub)
      vim.fn.chanclose(chan)
      return 1
    end

  ------------------------------------------------------------------------------
  -- COMMAND: status / state / info
  ------------------------------------------------------------------------------
  elseif cmd == "status" or cmd == "state" or cmd == "info" then
    local ok, res = rpc_api(chan, "get_state", {})
    vim.fn.chanclose(chan)
    if not ok then print_err(res); return 1 end
    if global_opts.json then
      output_val(res)
    else
      print_out("Neovim Status:")
      print_out("  Version:    " .. res.version)
      print_out("  PID:        " .. res.pid)
      print_out("  Server:     " .. res.servername)
      print_out("  CWD:        " .. res.cwd)
      print_out("  Mode:       " .. res.mode)
      print_out("  Cur Buffer: #" .. res.current_buf .. " (" .. (res.current_file ~= "" and res.current_file or "[No Name]") .. ")")
      print_out("  Cur Window: #" .. res.current_win .. " @ Line " .. res.cursor.line .. ", Col " .. res.cursor.col)
      print_out(string.format("  Counts:     %d buffers, %d windows, %d tabs", res.buffer_count, res.window_count, res.tab_count))
    end
    return 0

  ------------------------------------------------------------------------------
  -- COMMAND: listen (event streaming)
  ------------------------------------------------------------------------------
  elseif cmd == "listen" then
    local events = #sub_args > 0 and sub_args or { "BufWritePost", "CursorMoved", "User" }
    local wrapped = [[
      local chan, events = ...
      if type(events) == "string" then events = { events } end
      if not events or #events == 0 then events = { "BufWritePost", "BufEnter", "CursorMoved", "ModeChanged", "User" } end
      local group_name = "HarnessNvimEvents_" .. tostring(chan)
      local group_id = vim.api.nvim_create_augroup(group_name, { clear = true })
      for _, ev in ipairs(events) do
        local event_name = ev
        local pattern = "*"
        if ev:match("^User ") then
          event_name = "User"
          pattern = ev:sub(6)
        end
        pcall(function()
          vim.api.nvim_create_autocmd(event_name, {
            group = group_id,
            pattern = pattern,
            callback = function(ev_data)
              local payload = {
                event = ev_data.event,
                buf = ev_data.buf,
                file = ev_data.file,
                match = ev_data.match,
                data = ev_data.data,
                timestamp = os.time(),
              }
              local ok = pcall(function()
                vim.fn.rpcnotify(chan, "harness_event", payload)
              end)
              if not ok then
                pcall(vim.api.nvim_del_augroup_by_id, group_id)
              end
            end,
          })
        end)
      end
      return true
    ]]

    local ok, res = pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", wrapped, { chan, events })
    if not ok then
      print_err("Failed to subscribe to events: " .. tostring(res))
      vim.fn.chanclose(chan)
      return 1
    end

    print_out("Subscribed to events: " .. table.concat(events, ", ") .. " (Press Ctrl+C to stop)")

    local uv = vim.uv or vim.loop
    local sig = uv.new_signal()
    uv.signal_start(sig, "sigint", function()
      print_out("\nUnsubscribing and exiting...")
      local unsub_code = [[
        local chan = ...
        local group_name = "HarnessNvimEvents_" .. tostring(chan)
        pcall(function()
          local gid = vim.api.nvim_create_augroup(group_name, { clear = false })
          vim.api.nvim_del_augroup_by_id(gid)
        end)
      ]]
      pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", unsub_code, { chan })
      vim.fn.chanclose(chan)
      os.exit(0)
    end)

    while true do
      uv.sleep(100)
    end
    return 0

  ------------------------------------------------------------------------------
  -- Unknown Command
  ------------------------------------------------------------------------------
  else
    print_err("Unknown command: " .. cmd)
    print_err("Run 'nvim-cli --help' for usage instructions.")
    vim.fn.chanclose(chan)
    return 1
  end
end

local exit_code = main()
os.exit(exit_code or 0)
