#!/usr/bin/env bash
#
# One-shot installer for animepahe-dl on Debian / Ubuntu / Pop!_OS.
# Idempotent: safe to re-run; it only installs what is missing.
#
# What it sets up (mirrors the working dev machine):
#   - system packages: curl, jq, fzf, ffmpeg, xvfb, python3, pip
#   - Google Chrome (if no Chrome/Chromium binary is found)
#   - pipx + yt-dlp[default], with pycryptodomex injected into the yt-dlp venv
#     (required for AES-128 HLS over HTTP/2; without it the CDN 403s)
#   - a repo-local .venv with undetected_chromedriver for refresh_cookie.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APT_PACKAGES=(curl jq fzf ffmpeg xvfb gnupg ca-certificates python3 python3-venv python3-pip)

say()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m WARNING: %s\n' "$*"; }
die()  { printf '\033[1;31m[setup]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" > /dev/null 2>&1; }

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "root access is required to install system packages: $*"
    fi
}

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
if have apt-get; then
    say "Installing system packages: ${APT_PACKAGES[*]}"
    run_as_root apt-get update -qq
    run_as_root apt-get install -y "${APT_PACKAGES[@]}"
else
    warn "apt-get not found - install these yourself: ${APT_PACKAGES[*]}"
fi

# ---------------------------------------------------------------------------
# 2. Browser (Google Chrome preferred; Chromium also works via $CHROME_BIN)
# ---------------------------------------------------------------------------
if have google-chrome-stable || have google-chrome || have chromium || have chromium-browser; then
    say "Browser found: $(command -v google-chrome-stable || command -v google-chrome || command -v chromium || command -v chromium-browser)"
elif have apt-get; then
    if [[ "$(dpkg --print-architecture 2>/dev/null || echo unknown)" != "amd64" ]]; then
        warn "Google Chrome auto-install only supports amd64; install Chromium and set CHROME_BIN."
    else
        say "Installing Google Chrome from the official repository..."
        run_as_root bash -c '
            set -e
            install -d -m 755 /usr/share/keyrings
            curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
                | gpg --dearmor --yes -o /usr/share/keyrings/googlechrome-linux-keyring.gpg
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/googlechrome-linux-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
                > /etc/apt/sources.list.d/google-chrome.list
            apt-get update -qq
            apt-get install -y google-chrome-stable
        '
    fi
else
    warn "No browser found; install Chrome or Chromium manually."
fi

# ---------------------------------------------------------------------------
# 3. pipx (yt-dlp runs from its own pipx venv)
# ---------------------------------------------------------------------------
if ! have pipx; then
    say "Installing pipx..."
    if ! python3 -m pip install --user pipx > /dev/null 2>&1; then
        warn "pip install was blocked (PEP 668); retrying with --break-system-packages"
        python3 -m pip install --user --break-system-packages pipx > /dev/null
    fi
    export PATH="$HOME/.local/bin:$PATH"
    python3 -m pipx ensurepath > /dev/null 2>&1 || true
fi
have pipx || die "pipx is unavailable; install it manually and re-run this script"

# ---------------------------------------------------------------------------
# 4. yt-dlp with impersonation + native AES-128 support
# ---------------------------------------------------------------------------
if have yt-dlp; then
    say "yt-dlp already installed: $(yt-dlp --version)"
else
    say "Installing yt-dlp via pipx..."
    pipx install "yt-dlp[default]"
fi

# pycryptodomex must live inside the yt-dlp venv. Without it, yt-dlp hands
# AES-128 HLS streams to ffmpeg, which speaks HTTP/1.1 - and the animepahe
# CDN returns 403 Forbidden to any HTTP/1.1 request.
if ! pipx runpip yt-dlp list 2>/dev/null | grep -qi pycryptodomex; then
    say "Injecting pycryptodomex into the yt-dlp venv..."
    pipx inject yt-dlp pycryptodomex \
        || warn "pipx inject failed; run it manually: pipx inject yt-dlp pycryptodomex"
fi
if ! pipx runpip yt-dlp list 2>/dev/null | grep -qi curl_cffi; then
    say "Injecting curl_cffi into the yt-dlp venv (for --impersonate chrome)..."
    pipx inject yt-dlp curl_cffi \
        || warn "pipx inject failed; run it manually: pipx inject yt-dlp curl_cffi"
fi

# ---------------------------------------------------------------------------
# 5. Cookie-refresher virtualenv (undetected_chromedriver)
# ---------------------------------------------------------------------------
if [[ ! -x .venv/bin/python ]]; then
    say "Creating .venv for the cookie refresher..."
    python3 -m venv .venv
fi
say "Installing cookie-refresher dependencies..."
.venv/bin/python -m pip install --upgrade pip -q
.venv/bin/python -m pip install -r requirements.txt -q

# ---------------------------------------------------------------------------
# 6. Verification
# ---------------------------------------------------------------------------
echo
say "Verification:"
printf '  yt-dlp:      %s\n' "$(yt-dlp --version 2>/dev/null || echo MISSING)"
printf '  ffmpeg:      %s\n' "$(ffmpeg -version 2>/dev/null | head -1 || echo MISSING)"
printf '  browser:     %s\n' "$(google-chrome-stable --version 2>/dev/null || chromium --version 2>/dev/null || echo MISSING)"
if .venv/bin/python -c 'import undetected_chromedriver; print("  cookie venv: undetected_chromedriver OK")' 2>/dev/null; then
    :
else
    warn "undetected_chromedriver could not be imported from .venv"
fi

echo
say "Installation complete."
say "Next steps:"
echo "  1. ./refresh_cookie.sh                         # solves the Cloudflare challenge, fills config.json"
echo "  2. ./animepahe-dl.sh -a \"Naruto\" -e 1         # download episode 1"
echo "  3. ./anime-dl -a \"Naruto\" -e 1                # same, but refreshes the cookie first"

if [[ -t 0 ]]; then
    read -r -p "[setup] Refresh the cookie now? [Y/n] " answer
    case "${answer:-y}" in
        y|Y|"")
            ./refresh_cookie.sh
            ;;
        *)
            say "Skipped. Run ./refresh_cookie.sh whenever the cookie expires."
            ;;
    esac
fi
