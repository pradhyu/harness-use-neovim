local M = {}

--- Encode a Lua value to JSON string
---@param val any
---@return string
function M.json_encode(val)
  if vim.json and vim.json.encode then
    return vim.json.encode(val)
  end
  return vim.fn.json_encode(val)
end

--- Decode a JSON string to a Lua value
---@param str string
---@return any
function M.json_decode(str)
  if not str or str == "" then
    return nil
  end
  if vim.json and vim.json.decode then
    return vim.json.decode(str)
  end
  return vim.fn.json_decode(str)
end

--- Normalize buffer identifier (number, string, or nil for current)
---@param buf any
---@return number bufnr
function M.resolve_bufnr(buf)
  if buf == nil or buf == 0 or buf == "" then
    return vim.api.nvim_get_current_buf()
  end
  if type(buf) == "number" then
    if vim.api.nvim_buf_is_valid(buf) then
      return buf
    end
    error("Invalid buffer number: " .. tostring(buf))
  end
  if type(buf) == "string" then
    local num = tonumber(buf)
    if num and vim.api.nvim_buf_is_valid(num) then
      return num
    end
    -- Try finding by name
    local target = vim.fn.fnamemodify(buf, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name == buf or name == target or vim.fn.fnamemodify(name, ":t") == buf then
        return b
      end
    end
    error("Buffer not found: " .. buf)
  end
  return vim.api.nvim_get_current_buf()
end

--- Normalize window identifier (number or nil for current)
---@param win any
---@return number win_id
function M.resolve_winid(win)
  if win == nil or win == 0 or win == "" then
    return vim.api.nvim_get_current_win()
  end
  local num = tonumber(win)
  if num and vim.api.nvim_win_is_valid(num) then
    return num
  end
  error("Invalid window ID: " .. tostring(win))
end

--- Find active Neovim sockets on the system
---@return string[]
function M.find_sockets()
  local sockets = {}
  -- 1. Check $NVIM
  local nvim_env = vim.env.NVIM
  if nvim_env and nvim_env ~= "" then
    table.insert(sockets, nvim_env)
  end

  -- 2. Check $NVIM_LISTEN_ADDRESS (legacy)
  local legacy_env = vim.env.NVIM_LISTEN_ADDRESS
  if legacy_env and legacy_env ~= "" and legacy_env ~= nvim_env then
    table.insert(sockets, legacy_env)
  end

  -- 3. Search common runtime dirs (/tmp/nvim*, $XDG_RUNTIME_DIR/nvim*)
  local search_dirs = { "/tmp", vim.env.XDG_RUNTIME_DIR }
  for _, dir in ipairs(search_dirs) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      local matches = vim.fn.globpath(dir, "nvim*/*", true, true)
      for _, p in ipairs(matches) do
        local stat = (vim.uv or vim.loop).fs_stat(p)
        if stat and stat.type == "socket" then
          local exists = false
          for _, s in ipairs(sockets) do
            if s == p then exists = true; break end
          end
          if not exists then
            table.insert(sockets, p)
          end
        end
      end
    end
  end

  return sockets
end

--- Format output for CLI (handles tables, numbers, strings)
---@param val any
---@param json_format boolean?
---@return string
function M.format_output(val, json_format)
  if json_format then
    return M.json_encode(val)
  end
  if val == nil then
    return ""
  end
  if type(val) == "string" then
    return val
  end
  if type(val) == "number" or type(val) == "boolean" then
    return tostring(val)
  end
  if type(val) == "table" then
    -- If it's a list of strings, join with newlines
    local is_list_of_strings = true
    if #val > 0 then
      for _, item in ipairs(val) do
        if type(item) ~= "string" then
          is_list_of_strings = false
          break
        end
      end
    else
      is_list_of_strings = false
    end

    if is_list_of_strings then
      return table.concat(val, "\n")
    end

    return M.json_encode(val)
  end
  return vim.inspect(val)
end

return M
