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

--- RPC helper: call API function with fallback
local function rpc_api(chan, method_name, args)
  local wrapped = string.format([[
    local has_plugin, plugin = pcall(require, "harness_neovim")
    if has_plugin and plugin.api and plugin.api.%s then
      return plugin.api.%s(unpack(...))
    end
    error("API method %s not found. Is harness_neovim plugin loaded?")
  ]], method_name, method_name, method_name)

  local ok, res = pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", wrapped, { args or {} })
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
-- CLI Dispatcher
--------------------------------------------------------------------------------

local function main(args)
  local global_opts = {
    server = nil,
    json = false,
    quiet = false,
    help = false,
    version = false,
  }

  local cmd = nil
  local sub_args = {}

  local i = 1
  while i <= #args do
    local arg = args[i]
    if not cmd then
      if arg == "-s" or arg == "--server" then
        i = i + 1
        global_opts.server = args[i]
      elseif arg == "-j" or arg == "--json" then
        global_opts.json = true
      elseif arg == "-q" or arg == "--quiet" then
        global_opts.quiet = true
      elseif arg == "-v" or arg == "--version" then
        global_opts.version = true
      elseif arg == "-h" or arg == "--help" then
        global_opts.help = true
      elseif arg:sub(1, 1) == "-" and arg ~= "-" then
        print_err("Unknown global option: " .. arg)
        return 1
      else
        cmd = arg
      end
    else
      table.insert(sub_args, arg)
    end
    i = i + 1
  end

  if global_opts.version then
    print_out("nvim-cli version " .. VERSION)
    return 0
  end

  if global_opts.help or not cmd then
    print_help()
    return 0
  end

  -- Find server
  local socket = find_socket(global_opts.server)
  if not socket then
    if cmd == "server" then
      print_err("No active Neovim server found. (Is $NVIM set?)")
      return 1
    end
    print_err("Could not find active Neovim instance. Make sure Neovim is running with a socket or $NVIM is set.")
    return 1
  end

  if cmd == "server" then
    print_out(socket)
    return 0
  end

  -- Connect
  local chan = connect_rpc(socket)

  local function output_val(val)
    if global_opts.quiet then return end
    if global_opts.json then
      print_out(vim.json.encode(val))
    else
      if type(val) == "table" then
        if #val > 0 then
          local all_strings = true
          for _, it in ipairs(val) do
            if type(it) ~= "string" then all_strings = false; break end
          end
          if all_strings then
            print_out(table.concat(val, "\n"))
            return
          end
        end
        print_out(vim.json.encode(val))
      else
        print_out(tostring(val))
      end
    end
  end

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
      local events_mod = require("harness_neovim.events")
      return events_mod.subscribe(chan, events)
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
      pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", "require('harness_neovim.events').unsubscribe(...)", { chan })
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

local exit_code = main(_G.arg or {})
os.exit(exit_code or 0)
