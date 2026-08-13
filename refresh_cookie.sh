#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use Python 3.11 if available
if command -v python3.11 &> /dev/null; then
    PYTHON="python3.11"
else
    PYTHON="python3"
fi

echo "Starting Xvfb for headless browser..."
XVFB_DISPLAY=":${RANDOM}"
XVFB_LOCK="/tmp/.X${XVFB_DISPLAY#:}-lock"
[ -f "$XVFB_LOCK" ] && rm -f "$XVFB_LOCK"
Xvfb "$XVFB_DISPLAY" -screen 0 1280x900x24 2>/dev/null &
XVFB_PID=$!
export DISPLAY="$XVFB_DISPLAY"
sleep 2

echo "Attempting to fetch cookie automatically..."
OUTPUT=$("$PYTHON" "$SCRIPT_DIR/get_cookie.py" 2>&1)

# Kill Xvfb
kill $XVFB_PID 2>/dev/null
rm -f "$XVFB_LOCK" 2>/dev/null

# Check if output contains valid JSON with cf and ua
if echo "$OUTPUT" | grep -q '"cf":' && echo "$OUTPUT" | grep -q '"ua":'; then
    CF=$(echo "$OUTPUT" | jq -r '.cf')
    UA=$(echo "$OUTPUT" | jq -r '.ua')
    if [ -n "$CF" ] && [ "$CF" != "null" ] && [ -n "$UA" ] && [ "$UA" != "null" ]; then
        jq --arg cf "$CF" --arg ua "$UA" '.cf = $cf | .ua = $ua' "$SCRIPT_DIR/config.json" > "$SCRIPT_DIR/config.tmp" && mv "$SCRIPT_DIR/config.tmp" "$SCRIPT_DIR/config.json"
        echo "Cookie and user-agent updated automatically."
        exit 0
    fi
fi

# Fallback to manual
echo "Automated cookie fetch failed."
echo "Please manually obtain the cookie from your browser:"
echo "1. Open https://animepahe.pw in your browser and solve the Cloudflare challenge."
echo "2. Open Developer Tools → Application → Cookies → Copy 'cf_clearance' value."
echo "3. Also copy your User-Agent from Network tab."
echo ""
read -p "Paste cf_clearance: " CF
read -p "Paste user-agent: " UA
if [ -n "$CF" ] && [ -n "$UA" ]; then
    jq --arg cf "$CF" --arg ua "$UA" '.cf = $cf | .ua = $ua' "$SCRIPT_DIR/config.json" > "$SCRIPT_DIR/config.tmp" && mv "$SCRIPT_DIR/config.tmp" "$SCRIPT_DIR/config.json"
    echo "Cookie and user-agent updated manually."
else
    echo "Empty values provided. Cookie not updated."
    exit 1
fi
