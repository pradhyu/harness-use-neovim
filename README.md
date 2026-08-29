# harness-use-neovim ⚡

A high-performance, 100% Lua-based Neovim plugin and companion CLI (`nvim-cli`) that enables CLI tools, terminal subshells, scripts, and AI harnesses running inside Neovim to seamlessly talk to and control the host Neovim instance.

---

## ✨ Features

- **🚀 Zero External Dependencies**: 100% written in Lua using Neovim's built-in LuaJIT and LibUV runtime (`nvim -l`). No Python (`pynvim`), Node, or Ruby gems required.
- **🔄 Hot-Reloadable**: Reload the plugin dynamically on the fly (`:NvimCLIReload` or `nvim-cli reload`) without restarting Neovim!
- **🔌 Full RPC Execution**: Execute arbitrary Lua snippets, Vimscript expressions, or Ex commands with formatted JSON or raw text return values.
- **📄 Buffer & Window Manipulation**: Create, read, edit, append, save, and wipe buffers from CLI or stdin pipes.
- **🎯 Cursor & Selection Inspection**: Get/set cursor position, read active visual selections, and inspect viewport state.
- **🪟 UI Popups & Floating Windows**: Display floating markdown/code windows, toasts (`vim.notify`), and side-by-side diffs directly in the parent Neovim.
- **⏳ Seamless `$EDITOR` / Git Commit Integration**: Open files and block until the user finishes editing (`:wq` / `:bd`), eliminating annoying nested Neovim sessions inside `:terminal`.
- **🔍 LSP & Quickfix Integration**: Query LSP diagnostics and populate Neovim's quickfix list directly from compiler/linter outputs.
- **📡 Event Streaming (Pub/Sub)**: Stream Neovim autocmd events (`BufWritePost`, `CursorMoved`, `User`, etc.) directly to your terminal or background processes.

---

## 📦 Installation

### 1. Install the Neovim Plugin

#### Using [lazy.nvim](https://github.com/folke/lazy.nvim):

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

#### Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "pkshrestha/harness-use-neovim",
  config = function()
    require("harness_neovim").setup()
  end
}
```

#### Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'pkshrestha/harness-use-neovim'
```

---

### 2. Install the `nvim-cli` Executable

Inside Neovim, run:

```vim
:NvimCLIInstall
```

This copies the standalone `nvim-cli` launcher (and `nvim-cli.cmd` / `nvim-cli.ps1` on Windows) to `~/.local/bin` (or your configured `bin_install_dir`). Ensure the install folder is in your `$PATH` / `%PATH%`.

Alternatively, you can symlink or copy it directly from your terminal:

**Linux / macOS:**
```bash
ln -s /path/to/harness-use-neovim/bin/nvim-cli ~/.local/bin/nvim-cli
```

**Windows (PowerShell / CMD):**
```powershell
# Copy scripts to a directory in your PATH (e.g., C:\Users\<user>\bin)
Copy-Item bin\nvim-cli* C:\Users\$env:USERNAME\bin\
```

---

## 🔄 Hot-Reloading

You can hot-reload the plugin code during development or at runtime without restarting Neovim:

- **From inside Neovim**:
  ```vim
  :NvimCLIReload
  " or
  :NvimCLI reload
  ```

- **From Lua**:
  ```lua
  require("harness_neovim").reload()
  ```

- **From the terminal / CLI**:
  ```bash
  nvim-cli reload
  ```

This purges cached modules from `package.loaded`, cleans up existing event listeners, and safely re-initializes the plugin with preserved settings.

---

## 🛠️ CLI Quickstart (`nvim-cli`)

`nvim-cli` automatically connects to the parent Neovim instance using `$NVIM` (or auto-discovers running sockets / named pipes).

### 1. Evaluate Lua & Commands

```bash
# Evaluate arbitrary Lua expression
nvim-cli eval "10 * 42"
# Output: 420

# Run Lua and return JSON
nvim-cli eval "return { cwd = vim.fn.getcwd(), pid = vim.fn.getpid() }" --json

# Execute Ex command
nvim-cli exec "set number"

# Evaluate Vimscript expression
nvim-cli expr "expand('%:p')"
```

---

### 2. Buffer Operations

```bash
# List open buffers
nvim-cli buffer list

# Get current buffer contents
nvim-cli buffer get

# Replace current buffer contents from stdin
cat report.txt | nvim-cli buffer set

# Append lines to current buffer
echo "New log entry" | nvim-cli buffer append

# Create a new buffer
nvim-cli buffer new "my_notes.txt"

# Save buffer
nvim-cli buffer write
```

---

### 3. Open Files & `$EDITOR` Integration

```bash
# Open file in active window
nvim-cli open src/main.rs

# Open file with cursor jumped to line 42, col 10
nvim-cli open src/main.rs --line 42 --col 10

# Open in horizontal / vertical split or new tab
nvim-cli split src/lib.rs
nvim-cli vsplit src/config.rs
nvim-cli tabopen README.md

# Open and block until closed ($EDITOR mode)
nvim-cli edit --wait /tmp/msg.txt
```

#### Setup as `$EDITOR` for Neovim's `:terminal`:

**Linux / macOS (`~/.bashrc` or `~/.zshrc`):**
```bash
if [ -n "$NVIM" ]; then
  export EDITOR="nvim-cli edit --wait"
  export VISUAL="nvim-cli edit --wait"
  export GIT_EDITOR="nvim-cli edit --wait"
fi
```

**Windows PowerShell (`$PROFILE`):**
```powershell
if ($env:NVIM) {
  $env:EDITOR = "nvim-cli.cmd edit --wait"
  $env:VISUAL = "nvim-cli.cmd edit --wait"
  $env:GIT_EDITOR = "nvim-cli.cmd edit --wait"
}
```

**Windows Command Prompt (`cmd.exe`):**
```cmd
if defined NVIM (
  set "EDITOR=nvim-cli.cmd edit --wait"
  set "VISUAL=nvim-cli.cmd edit --wait"
  set "GIT_EDITOR=nvim-cli.cmd edit --wait"
)
```

Now running `git commit` or `git rebase -i` inside a Neovim `:terminal` opens the commit buffer in your outer Neovim window!

---

### 4. Floating Windows & Notifications

```bash
# Send a toast notification
nvim-cli notify "Build completed in 2.4s!" --level info

# Display a floating window from command output
git diff | nvim-cli float "Git Diff (Staged)"
cargo check 2>&1 | nvim-cli float "Compiler Output"

# Show side-by-side diff in Neovim
nvim-cli diff original.txt modified.txt
```

---

### 5. Cursor & Selections

```bash
# Get cursor position and current line text
nvim-cli cursor get

# Move cursor to line 25, column 5
nvim-cli cursor set 25 5

# Get the text currently selected in visual mode
nvim-cli selection get
```

---

### 6. Quickfix & LSP

```bash
# Populate quickfix list from JSON
nvim-cli quickfix set '[{"filename": "src/main.rs", "lnum": 12, "col": 4, "text": "syntax error", "type": "E"}]'

# List active LSP diagnostics
nvim-cli diagnostics list
nvim-cli diagnostics count

# Trigger LSP format
nvim-cli lsp format
```

---

### 7. Real-Time Event Streaming

Stream autocmd events from Neovim to your CLI:

```bash
nvim-cli listen BufWritePost CursorMoved TextChanged
```

---

## 💻 Lua API

You can also use the Lua API directly inside Neovim or via plugins:

```lua
local api = require("harness_neovim.api")

-- Buffers
local bufs = api.list_buffers()
local buf = api.create_buffer({ name = "scratch.lua", lines = { "-- Hello world" } })
local text = api.get_buffer(buf.bufnr)

-- Windows & Cursor
local cursor = api.get_cursor()
api.set_cursor(10, 1)

-- Floating window & UI
local float = api.show_float("Quick Note", { "Line 1", "Line 2" }, { border = "rounded" })
api.notify("Process done!", "info")

-- Hot-reload plugin
api.reload()
```

---

## 🪟 Windows Support

`harness-use-neovim` is fully compatible with Windows:

- **Zero Extra Dependencies**: Uses Neovim's built-in LuaJIT and LibUV runtime on Windows.
- **Named Pipes RPC**: Neovim on Windows communicates via Windows Named Pipes (e.g. `\\.\pipe\nvim-12345-0`). The plugin and CLI connect seamlessly over named pipes without any extra configuration.
- **Native Shells Supported**:
  - **PowerShell / CMD**: Use the provided `nvim-cli.cmd` batch script or `nvim-cli.ps1` script.
  - **Git Bash / MSYS2 / WSL**: Use the standard `nvim-cli` script.
  - **Direct Invocation**: You can also invoke `nvim-cli.lua` directly with `nvim -l bin/nvim-cli.lua <command>`.

---

## 🧪 Testing

Run the automated test suite (Lua API unit tests + CLI integration tests):

```bash
./tests/run_tests.sh
```

---

## 📄 License

MIT License. Copyright (c) 2026.
