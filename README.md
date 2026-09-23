# harness-use-neovim ⚡

A high-performance, 100% Lua-based Neovim plugin that enables terminal subshells, scripts, and AI harnesses to seamlessly interact with and control the host Neovim instance.

---

## ✨ Features

- **🚀 Zero External Dependencies**: 100% written in Lua using Neovim's built-in LuaJIT and LibUV runtime. No Python (`pynvim`), Node, or Ruby gems required.
- **🔄 Hot-Reloadable**: Reload the plugin dynamically on the fly (`:NvimCLIReload` or via Lua API) without restarting Neovim!
- **🔌 Full RPC Execution**: Execute arbitrary Lua snippets, Vimscript expressions, or Ex commands with structured return values.
- **📄 Buffer & Window Manipulation**: Create, read, edit, append, save, and wipe buffers from Lua or stdin pipes.
- **🎯 Cursor & Selection Inspection**: Get/set cursor position, read active visual selections, and inspect viewport state.
- **🪟 UI Popups & Floating Windows**: Display floating markdown/code windows, toasts (`vim.notify`), and side-by-side diffs directly in Neovim.
- **⏳ Seamless `$EDITOR` / Git Commit Integration**: Open files and block until the user finishes editing (`:wq` / `:bd`), eliminating annoying nested Neovim sessions inside `:terminal`.
- **🔍 LSP & Quickfix Integration**: Query LSP diagnostics and populate Neovim's quickfix list directly from compiler/linter outputs.
- **📡 Event Streaming (Pub/Sub)**: Stream Neovim autocmd events (`BufWritePost`, `CursorMoved`, `User`, etc.) in real time.

---

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "pkshrestha/harness-use-neovim",
  lazy = false,
  config = function()
    require("harness_neovim").setup({
      -- Options (optional)
      auto_start_server = true,
      set_terminal_env = true,
      bin_install_dir = vim.fn.expand("~/.local/bin"),
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "pkshrestha/harness-use-neovim",
  config = function()
    require("harness_neovim").setup()
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'pkshrestha/harness-use-neovim'
```

---

## ⚙️ Configuration & Options

Pass options to `require("harness_neovim").setup(opts)`:

| Option | Type | Default | Description |
|---|---|---|---|
| `auto_start_server` | `boolean` | `true` | Ensure Neovim server socket is listening |
| `server_name` | `string` | `nil` | Custom socket path (defaults to `$NVIM` / temp socket) |
| `set_terminal_env` | `boolean` | `true` | Export `$NVIM` to Neovim `:terminal` subshells |
| `bin_install_dir` | `string` | `"~/.local/bin"` | Directory for optional CLI helper installation |

---

## 🔄 Hot-Reloading

You can hot-reload the plugin code during development or at runtime without restarting Neovim:

- **Command**:
  ```vim
  :NvimCLIReload
  " or
  :NvimCLI reload
  ```

- **Lua API**:
  ```lua
  require("harness_neovim").reload()
  ```

This purges cached modules from `package.loaded`, cleans up active event listeners, and safely re-initializes the plugin with your preserved settings.

---

## 💻 Lua API Reference

The plugin provides a comprehensive, structured Lua API under `require("harness_neovim.api")`:

```lua
local api = require("harness_neovim.api")

-- 1. Buffer Operations
local bufs = api.list_buffers()
local new_buf = api.create_buffer({ name = "scratch.lua", lines = { "-- Hello world" }, focus = true })
local content = api.get_buffer(new_buf.bufnr)
api.set_buffer(new_buf.bufnr, { "print('Updated content')" })
api.append_buffer(new_buf.bufnr, { "print('Appended line')" })
api.write_buffer(new_buf.bufnr, "/tmp/scratch.lua")
api.delete_buffer(new_buf.bufnr, { force = true })

-- 2. Windows & Cursor
local cursor = api.get_cursor() -- returns { line, col, text, bufnr, win_id, file }
api.set_cursor(10, 1)
local wins = api.list_windows()
api.focus_window(wins[1].win_id)

-- 3. Selections
local selection = api.get_selection() -- returns selected text, line/col ranges, and visual mode

-- 4. Floating Windows & UI
local float = api.show_float("Notification", { "Line 1", "Line 2" }, { border = "rounded" })
api.notify("Build completed successfully!", "info", { title = "Harness" })
api.show_diff("Comparison", { "old line" }, { "new line" })

-- 5. LSP & Diagnostics
local diags = api.get_diagnostics()
local counts = api.get_diagnostic_counts()
local clients = api.get_lsp_clients()
api.format_buffer()

-- 6. Quickfix
api.set_quickfix({
  { filename = "src/main.rs", lnum = 12, col = 4, text = "syntax error", type = "E" }
}, { open = true })
local qf_items = api.get_quickfix()
api.clear_quickfix()

-- 7. Editor State
local state = api.get_state()
-- returns { version, pid, servername, cwd, mode, current_buf, current_win, cursor, counts... }
```

---

## 📡 Event Pub/Sub Streaming

Subscribe to autocmd events programmatically:

```lua
local events = require("harness_neovim.events")

-- Subscribe RPC channel or callback to events
events.subscribe(channel_id, { "BufWritePost", "CursorMoved", "User" })

-- Unsubscribe
events.unsubscribe(channel_id)

-- Emit custom events
events.emit("HarnessTaskDone", { status = "ok" })
```

---

## 🪟 Windows Support

`harness-use-neovim` is fully cross-platform:

- **Zero Extra Dependencies**: Uses Neovim's built-in LuaJIT and LibUV runtime on Windows.
- **Named Pipes RPC**: Connects seamlessly over Windows Named Pipes (`\\.\pipe\nvim-*`) without extra configuration.

---

## 🧪 Testing

Run the automated test suite:

```bash
./tests/run_tests.sh
```

---

## 📄 License

MIT License. Copyright (c) 2026.
