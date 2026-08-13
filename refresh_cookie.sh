#!/bin/bash

# On Pop!_OS, we can use xvfb-run (more reliable)
# If you prefer manual Xvfb, uncomment the alternative section.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the virtualenv created by setup.sh; otherwise use the system
# python3 (works on machines that have undetected_chromedriver installed).
if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python"
else
    PYTHON=python3
fi

# Use xvfb-run if available
if command -v xvfb-run &> /dev/null; then
    OUTPUT=$(xvfb-run -a "$PYTHON" "$SCRIPT_DIR/get_cookie.py")
else
    # Fallback to manual Xvfb
    XVFB_DISPLAY=":${RANDOM}"
    XVFB_LOCK="/tmp/.X${XVFB_DISPLAY#:}-lock"
    [ -f "$XVFB_LOCK" ] && rm -f "$XVFB_LOCK"
    Xvfb "$XVFB_DISPLAY" -screen 0 1280x900x24 2>/dev/null &
    XVFB_PID=$!
    export DISPLAY="$XVFB_DISPLAY"
    sleep 2
    OUTPUT=$("$PYTHON" "$SCRIPT_DIR/get_cookie.py")
    kill $XVFB_PID 2>/dev/null
    rm -f "$XVFB_LOCK" 2>/dev/null
fi

# Check for error
if echo "$OUTPUT" | grep -q "error"; then
    echo "Failed to get cookie: $OUTPUT"
    exit 1
fi

CF=$(echo "$OUTPUT" | jq -r '.cf')
UA=$(echo "$OUTPUT" | jq -r '.ua')

# Update config.json in the same directory as the script
CONFIG_FILE="$SCRIPT_DIR/config.json"

jq --arg cf "$CF" --arg ua "$UA" '.cf = $cf | .ua = $ua' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
echo "Cookie and user-agent updated."
