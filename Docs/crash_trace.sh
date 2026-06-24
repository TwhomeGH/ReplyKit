#!/bin/bash
# crash_trace.sh ? macOS/Linux wrapper for crash_trace.py
# Usage: ./crash_trace.sh <crash.ips> [--dsym-dir <dir>]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/crash_trace.py" "$@"