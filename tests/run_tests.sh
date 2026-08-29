#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "========================================="
echo " running harness-use-neovim test suite  "
echo "========================================="

echo ""
echo "--- 1. Running Lua API Unit Tests ---"
nvim --headless --clean -u NONE \
  --cmd "set runtimepath^=$PROJECT_DIR" \
  -l "$PROJECT_DIR/tests/test_api.lua"

echo ""
echo "--- 2. Running CLI Integration Tests ---"
chmod +x "$PROJECT_DIR/tests/test_cli.sh"
"$PROJECT_DIR/tests/test_cli.sh"

echo ""
echo "========================================="
echo " ALL TESTS PASSED SUCCESSFULLY!          "
echo "========================================="
