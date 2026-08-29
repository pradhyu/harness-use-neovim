-- Test suite for harness_neovim Lua API
local api = require("harness_neovim.api")
local ui = require("harness_neovim.ui")
local wait = require("harness_neovim.wait")
local events = require("harness_neovim.events")

local failed = 0
local passed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  [PASS] " .. name)
  else
    failed = failed + 1
    print("  [FAIL] " .. name .. ": " .. tostring(err))
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s (expected: %s, got: %s)", msg or "Assertion failed", tostring(expected), tostring(actual)))
  end
end

print("Starting harness_neovim API tests...")

-- 1. Eval tests
test("eval_lua returns expression results", function()
  local res = api.eval_lua("10 + 20")
  assert_eq(res.success, true)
  assert_eq(res.result, 30)
end)

test("eval_lua handles multiline code with arguments", function()
  local res = api.eval_lua([[
    local a, b = ...
    return { sum = a + b, mult = a * b }
  ]], { 4, 5 })
  assert_eq(res.success, true)
  assert_eq(res.result.sum, 9)
  assert_eq(res.result.mult, 20)
end)

test("eval_vim evaluates vim expressions", function()
  local res = api.eval_vim("1 + 1")
  assert_eq(res.success, true)
  assert_eq(res.result, 2)
end)

test("call_function resolves and invokes functions", function()
  local res = api.call_function("math.max", { 10, 50, 25 })
  assert_eq(res.success, true)
  assert_eq(res.result, 50)
end)

-- 2. Buffer tests
test("buffer creation, set, append, get", function()
  local created = api.create_buffer({ name = "test_doc.txt" })
  local bufnr = created.bufnr
  assert_eq(vim.api.nvim_buf_is_valid(bufnr), true)

  local set_res = api.set_buffer(bufnr, "line 1\nline 2\nline 3")
  assert_eq(set_res.success, true)

  local get_res = api.get_buffer(bufnr)
  assert_eq(#get_res.lines, 3)
  assert_eq(get_res.lines[1], "line 1")
  assert_eq(get_res.lines[3], "line 3")

  local app_res = api.append_buffer(bufnr, "line 4")
  assert_eq(app_res.success, true)

  local get2 = api.get_buffer(bufnr)
  assert_eq(#get2.lines, 4)
  assert_eq(get2.lines[4], "line 4")

  local del_res = api.delete_buffer(bufnr, { force = true })
  assert_eq(del_res.success, true)
  assert_eq(vim.api.nvim_buf_is_valid(bufnr), false)
end)

-- 3. Cursor & Selection tests
test("cursor get and set", function()
  local cur = api.get_cursor()
  assert_eq(type(cur.line), "number")
  assert_eq(type(cur.col), "number")

  local set_c = api.set_cursor(1, 1)
  assert_eq(set_c.success, true)
  assert_eq(set_c.line, 1)
  assert_eq(set_c.col, 1)
end)

-- 4. Window & Tab tests
test("window listing and focus", function()
  local wins = api.list_windows()
  assert_eq(#wins >= 1, true)
  assert_eq(wins[1].current, true)
end)

test("tab listing", function()
  local tabs = api.list_tabs()
  assert_eq(#tabs >= 1, true)
  assert_eq(tabs[1].tabnr, 1)
end)

-- 5. Quickfix tests
test("quickfix get, set, clear", function()
  local set_ok = api.set_quickfix({
    { filename = "main.lua", lnum = 5, col = 2, text = "test error", type = "E" }
  })
  assert_eq(set_ok, true)

  local qf = api.get_quickfix()
  assert_eq(#qf, 1)
  assert_eq(qf[1].text, "test error")

  local clr_ok = api.clear_quickfix()
  assert_eq(clr_ok, true)
  local qf2 = api.get_quickfix()
  assert_eq(#qf2, 0)
end)

-- 6. State & Info tests
test("get_state returns complete editor status", function()
  local st = api.get_state()
  assert_eq(type(st.version), "string")
  assert_eq(type(st.pid), "number")
  assert_eq(type(st.mode), "string")
  assert_eq(type(st.buffer_count), "number")
end)

-- 7. Hot Reload test
test("reload re-initializes plugin modules without errors", function()
  local res = api.reload()
  assert_eq(res.success, true)
  -- Verify api functions are intact after reload
  local post_reload_api = require("harness_neovim.api")
  local test_eval = post_reload_api.eval_lua("100 + 200")
  assert_eq(test_eval.success, true)
  assert_eq(test_eval.result, 300)
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
