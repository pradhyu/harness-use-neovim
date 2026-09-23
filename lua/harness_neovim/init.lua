local M = {}

M.api = require("harness_neovim.api")
M.ui = require("harness_neovim.ui")
M.wait = require("harness_neovim.wait")
M.events = require("harness_neovim.events")
M.utils = require("harness_neovim.utils")

M.config = {
  auto_start_server = true,
  set_terminal_env = true,
  bin_install_dir = vim.fn.expand("~/.local/bin"),
  default_float_border = "rounded",
}

M._saved_config = nil

--- Hot-reload all modules of harness_neovim without restarting Neovim
---@param opts table?
---@return boolean, string
function M.reload(opts)
  local config = opts or M._saved_config or {}

  -- Clean up event subscriptions
  pcall(function()
    local ev = package.loaded["harness_neovim.events"]
    if ev and ev.unsubscribe_all then
      ev.unsubscribe_all()
    end
  end)

  -- Unload all cached Lua modules for this plugin
  for k, _ in pairs(package.loaded) do
    if k:match("^harness_neovim") or k:match("^nvim_cli") then
      package.loaded[k] = nil
    end
  end

  -- Re-require root module
  local ok, new_M = pcall(require, "harness_neovim")
  if not ok then
    local err = "Failed to reload harness_neovim: " .. tostring(new_M)
    pcall(vim.notify, err, vim.log.levels.ERROR, { title = "Nvim-CLI Reload" })
    return false, err
  end

  -- Re-initialize plugin
  new_M.setup(config)
  pcall(vim.notify, "⚡ harness_neovim hot-reloaded successfully!", vim.log.levels.INFO, { title = "Nvim-CLI" })
  return true, "harness_neovim hot-reloaded successfully"
end

--- RPC handler for evaluating Lua code remotely
---@param code string
---@param args any[]?
---@return table
function M.rpc_eval(code, args)
  return M.api.eval_lua(code, args)
end

--- RPC handler for calling an API function
---@param fn_name string
---@param args any[]?
---@return table
function M.rpc_call(fn_name, args)
  return M.api.call_function(fn_name, args)
end

--- Install the nvim-cli binary to the target directory
---@param target_dir string?
---@return boolean, string
function M.install_cli(target_dir)
  target_dir = target_dir or M.config.bin_install_dir
  if not target_dir or target_dir == "" then
    return false, "Target directory not specified"
  end

  -- Find the plugin root directory
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(script_path, ":p:h:h:h")
  local bin_lua = plugin_root .. "/bin/nvim-cli.lua"

  if vim.fn.filereadable(bin_lua) == 0 then
    return false, "Source file not found at " .. bin_lua
  end

  -- Create target directory if needed
  if vim.fn.isdirectory(target_dir) == 0 then
    vim.fn.mkdir(target_dir, "p")
  end

  local dest_bin = target_dir .. "/nvim-cli"
  local dest_lua = target_dir .. "/nvim-cli.lua"

  -- Copy files
  local uv = vim.uv or vim.loop
  local function copy_file(src, dst)
    local in_f = io.open(src, "rb")
    if not in_f then return false, "Cannot open " .. src end
    local content = in_f:read("*all")
    in_f:close()

    local out_f = io.open(dst, "wb")
    if not out_f then return false, "Cannot write to " .. dst end
    out_f:write(content)
    out_f:close()

    pcall(uv.fs_chmod, dst, 493) -- 0755
    return true
  end

  local ok1, err1 = copy_file(bin_lua, dest_bin)
  if not ok1 then return false, err1 end
  copy_file(bin_lua, dest_lua)

  return true, "Successfully installed nvim-cli to " .. dest_bin
end

--- Initialize and configure the plugin
---@param opts table?
function M.setup(opts)
  if opts then
    M._saved_config = vim.deepcopy(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end

  -- Ensure server is listening
  if M.config.auto_start_server then
    if not vim.v.servername or vim.v.servername == "" then
      pcall(vim.fn.serverstart)
    end
  end

  -- Set NVIM environment variable for all child processes and terminal buffers
  if M.config.set_terminal_env and vim.v.servername and vim.v.servername ~= "" then
    vim.env.NVIM = vim.v.servername
  end

  -- User commands (idempotent, replaces existing commands on reload)
  vim.api.nvim_create_user_command("NvimCLI", function(cmd_opts)
    local sub = cmd_opts.fargs[1] or "info"
    if sub == "info" or sub == "status" then
      local state = M.api.get_state()
      local msg = string.format("Nvim-CLI Server\nSocket: %s\nPID: %d\nVersion: %s",
        state.servername or "none", state.pid, state.version)
      vim.notify(msg, vim.log.levels.INFO, { title = "Nvim-CLI" })
    elseif sub == "socket" then
      local s = vim.v.servername or ""
      vim.fn.setreg("+", s)
      vim.fn.setreg('"', s)
      vim.notify("Socket path copied to clipboard:\n" .. s, vim.log.levels.INFO, { title = "Nvim-CLI Socket" })
    elseif sub == "reload" then
      M.reload()
    elseif sub == "install" then
      local dir = cmd_opts.fargs[2] or M.config.bin_install_dir
      local ok, res = M.install_cli(dir)
      if ok then
        vim.notify(res, vim.log.levels.INFO, { title = "Nvim-CLI Install" })
      else
        vim.notify("Install failed: " .. tostring(res), vim.log.levels.ERROR, { title = "Nvim-CLI Install" })
      end
    else
      vim.notify("Unknown subcommand: " .. sub .. "\nAvailable: info, socket, reload, install", vim.log.levels.WARN)
    end
  end, {
    nargs = "*",
    complete = function(_, line)
      local parts = vim.split(line, "%s+")
      if #parts <= 2 then
        return vim.tbl_filter(function(s)
          return vim.startswith(s, parts[2] or "")
        end, { "info", "socket", "reload", "install", "status" })
      end
      return {}
    end,
    desc = "Nvim-CLI management command",
  })

  vim.api.nvim_create_user_command("NvimCLIReload", function()
    M.reload()
  end, { desc = "Hot-reload harness_neovim plugin" })

  vim.api.nvim_create_user_command("NvimCLISocket", function()
    local s = vim.v.servername or ""
    vim.fn.setreg("+", s)
    vim.fn.setreg('"', s)
    print(s)
  end, { desc = "Print and copy Neovim server socket" })

  vim.api.nvim_create_user_command("NvimCLIInstall", function(cmd_opts)
    local dir = cmd_opts.args ~= "" and cmd_opts.args or nil
    local ok, res = M.install_cli(dir)
    if ok then
      vim.notify(res, vim.log.levels.INFO)
    else
      vim.notify("Install failed: " .. tostring(res), vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "dir", desc = "Install nvim-cli executable" })
end

return M
