#!/bin/sh
# ============================================================================
#  tests/run_tests.sh -- play the game headlessly and check the frames.
#
#  Every case drives the real binary with a scripted key sequence (one key per
#  frame), dumps the rendered 80x24 screen and asserts on what is on it.
#  Nothing here is mocked: this is the shipped game running its normal loop.
# ============================================================================
set -e
cd "$(dirname "$0")/.."

echo "== building =="
make -s

echo
echo "== headless playthroughs =="
python3 tests/run_tests.py "$@"
