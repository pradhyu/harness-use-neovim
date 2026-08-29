local M = {}

local active_subscriptions = {}

--- Subscribe a channel to Neovim autocmd events
---@param chan number
---@param events string[]|string
---@param opts table?
---@return boolean
function M.subscribe(chan, events, opts)
  opts = opts or {}
  if type(events) == "string" then
    events = { events }
  end
  if not events or #events == 0 then
    events = { "BufWritePost", "BufEnter", "CursorMoved", "ModeChanged", "User" }
  end

  local group_name = "HarnessNvimEvents_" .. tostring(chan)
  local group_id = vim.api.nvim_create_augroup(group_name, { clear = true })

  for _, ev in ipairs(events) do
    local event_name = ev
    local pattern = opts.pattern or "*"
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
            -- Channel is likely closed, cleanup
            M.unsubscribe(chan)
          end
        end,
      })
    end)
  end

  active_subscriptions[chan] = group_id
  return true
end

--- Unsubscribe a channel and clean up its autocmds
---@param chan number
---@return boolean
function M.unsubscribe(chan)
  local group_id = active_subscriptions[chan]
  if group_id then
    pcall(vim.api.nvim_del_augroup_by_id, group_id)
    active_subscriptions[chan] = nil
    return true
  end
  return false
end

--- Clean up all active event subscriptions (used during hot reload)
---@return boolean
function M.unsubscribe_all()
  for chan, group_id in pairs(active_subscriptions) do
    pcall(vim.api.nvim_del_augroup_by_id, group_id)
    active_subscriptions[chan] = nil
  end
  return true
end

--- Emit a custom event inside Neovim
---@param pattern string
---@param data any
---@return boolean
function M.emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern or "NvimCLI",
    data = data,
    modeline = false,
  })
  return true
end

return M
