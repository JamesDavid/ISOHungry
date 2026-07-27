#!/bin/bash
# Starts the web UI in the background, then runs the terminal display in the
# foreground. The TUI remains the primary interface; the web server is purely
# additive and reads the same state files.
set -uo pipefail

if [ "${WEB_UI:-1}" = "1" ]; then
  python3 /opt/isohungry/server.py &
  WEB_PID=$!
  trap 'kill "$WEB_PID" 2>/dev/null' EXIT
fi

exec /usr/local/bin/isohungry "$@"
