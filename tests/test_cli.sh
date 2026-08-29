#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PROJECT_DIR/bin/nvim-cli"
SOCKET="/tmp/test_nvim_cli_suite_$$.sock"

echo "Starting headless Neovim server on $SOCKET..."
NVIM_APPNAME="" nvim --headless --clean -u NONE \
  --cmd "set runtimepath^=$PROJECT_DIR" \
  --cmd "lua require('harness_neovim').setup()" \
  --listen "$SOCKET" &
NVIM_PID=$!

cleanup() {
  echo "Cleaning up Neovim process $NVIM_PID..."
  nvim --server "$SOCKET" --remote-send ":qa!<CR>" 2>/dev/null || true
  wait $NVIM_PID 2>/dev/null || true
  rm -f "$SOCKET"
}
trap cleanup EXIT

sleep 0.4
export NVIM="$SOCKET"

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  echo -n "  Testing: $name ... "
  if output=$("$@" 2>&1); then
    echo "OK"
    PASSED=$((PASSED + 1))
  else
    echo "FAILED"
    echo "    Command: $*"
    echo "    Output: $output"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Running CLI Integration Tests ==="

run_test "CLI Help" $BIN --help
run_test "CLI Version" $BIN --version
run_test "Server Socket" $BIN server
run_test "Status Command" $BIN status
run_test "Status JSON" $BIN status --json
run_test "Lua Eval simple" $BIN eval "2 * 21"
run_test "Lua Eval JSON table" $BIN eval "return { foo = 'bar' }" --json
run_test "Vim Expr" $BIN expr "10 + 15"
run_test "Ex Command" $BIN exec "set wrap"
run_test "Keys" $BIN keys "<Esc>"
run_test "Buffer List" $BIN buffer list
run_test "Buffer New" $BIN buffer new "cli_buf.txt"
run_test "Buffer Set text" $BIN buffer set "hello from test"
run_test "Buffer Get text" $BIN buffer get
run_test "Buffer Append text" $BIN buffer append "appended row"
run_test "Cursor Get" $BIN cursor get
run_test "Cursor Set" $BIN cursor set 1 3
run_test "Cursor Text" $BIN cursor text
run_test "Window List" $BIN window list
run_test "Tab List" $BIN tab list
run_test "Notify" $BIN notify "Automated test notification" --level info
run_test "Float Popup" $BIN float "Title" "Floating content body"
run_test "Quickfix Set JSON" $BIN quickfix set '[{"filename": "test.txt", "lnum": 1, "col": 1, "text": "error"}]'
run_test "Quickfix List" $BIN quickfix list
run_test "Quickfix Clear" $BIN quickfix clear
run_test "Plugin Hot Reload" $BIN reload

echo ""
echo "=== CLI Test Results: $PASSED passed, $FAILED failed ==="
if [ $FAILED -gt 0 ]; then
  exit 1
fi
