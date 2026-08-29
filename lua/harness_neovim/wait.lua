local M = {}

local active_waiters = {}

--- Register a buffer for waiting
---@param bufnr number
---@param opts table?
---@return string token
function M.register_waiter(bufnr, opts)
  opts = opts or {}
  local token = tostring(bufnr) .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
  active_waiters[token] = {
    bufnr = bufnr,
    opts = opts,
    created_at = os.time(),
    done = false,
  }

  -- Set buffer options or highlight if requested
  if opts.notify_on_open ~= false then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local shortname = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
    vim.notify("Waiting on buffer: " .. shortname .. " (close buffer with :wq or :bd to finish)", vim.log.levels.INFO, {
      title = "Nvim-CLI Wait",
    })
  end

  -- Set up autocmd on BufDelete / BufWipeout
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      if active_waiters[token] then
        active_waiters[token].done = true
      end
    end,
  })

  return token
end

--- Check if a waiter token is still active / buffer is valid
---@param token string
---@return boolean is_active
function M.is_waiting(token)
  local waiter = active_waiters[token]
  if not waiter then
    return false
  end
  if waiter.done then
    active_waiters[token] = nil
    return false
  end
  if not vim.api.nvim_buf_is_valid(waiter.bufnr) then
    active_waiters[token] = nil
    return false
  end
  return true
end

--- Explicitly finish waiting on a token or bufnr
---@param token_or_bufnr string|number
---@return boolean
function M.finish_wait(token_or_bufnr)
  if type(token_or_bufnr) == "number" then
    for token, waiter in pairs(active_waiters) do
      if waiter.bufnr == token_or_bufnr then
        waiter.done = true
        active_waiters[token] = nil
        return true
      end
    end
  elseif type(token_or_bufnr) == "string" then
    if active_waiters[token_or_bufnr] then
      active_waiters[token_or_bufnr].done = true
      active_waiters[token_or_bufnr] = nil
      return true
    end
  end
  return false
end

return M
