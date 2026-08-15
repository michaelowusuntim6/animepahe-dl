# animepahe-dl

Download anime episodes from [animepahe](https://animepahe.pw) directly on your Android device using Termux.

The script resolves the anime's episode list from the animepahe API, unpacks the kwik player page to find the real HLS playlist, downloads every fragment with `yt-dlp`, decrypts AES‑128 streams natively, and remuxes the finished file into a clean MP4.

## Features

- Search by anime name (`-a`) with an interactive `fzf` picker, or use a slug directly (`-s`)
- Single, comma‑separated, ranged, and "all episodes" batch downloads (`-e 1,2,5-7,*`)
- Resolution (`-r`) and audio‑language (`-o`) selection
- Print the m3u8 URL without downloading (`-l`) to stream directly in a media player
- Automatic Cloudflare `cf_clearance` refresh via `./refresh_cookie.sh`
- AES‑128‑encrypted HLS handled natively over HTTP/2; output remuxed to MP4
- Concurrent fragment downloads for faster speed

## Requirements

Target platform: **Termux** (Android arm64/aarch64).

| Component | Purpose |
| :--- | :--- |
| `curl`, `jq`, `fzf` | API requests, JSON parsing, interactive anime picker |
| `ffmpeg` | Remuxing the downloaded stream into MP4 |
| `chromium` | Headless browser for solving Cloudflare Turnstile |
| `xorg-server-xvfb` | Virtual display for headless Chromium |
| `python3.11` + `pip` | Runs `get_cookie.py` and the local JS unpacker |
| `undetected-chromedriver` | Bypasses Cloudflare detection in headless Chromium |
| `yt-dlp[curl-cffi]` | Downloads HLS streams with browser impersonation |
| `pycryptodomex` | Native AES‑128 decryption (avoids ffmpeg HTTP/1.1 limitations) |

> **Why `pycryptodomex` is essential**: the CDN that hosts the episodes (e.g. `vault-*.uwucdn.top`) rejects **HTTP/1.1** requests with 403 Forbidden. `ffmpeg`'s downloader is HTTP/1.1‑only, so `yt-dlp` must decrypt AES‑128 streams natively (over HTTP/2) using `pycryptodomex`. Never add `--downloader ffmpeg` to `yt-dlp`.

You can download the Termux app from the release page or by using this link:
https://github.com/michaelowusuntim6/animepahe-dl/releases/download/V1.00/Termux.0.119.0-beta.3.apk

## Installation (Termux)

### 1. Grant storage access

```bash
termux-setup-storage
```

### 2. Install system packages

```bash
pkg update && pkg upgrade -y
```

```bash
pkg install x11-repo tur-repo -y
```

```bash
pkg update
```

```bash
pkg install -y jq fzf curl ffmpeg chromium xorg-server-xvfb python3.11 wget git
```

### 3. Install Python packages

```bash
pip3.11 install --upgrade pip wheel -y
```

```bash
pip3.11 install setuptools selenium undetected-chromedriver pycryptodomex "yt-dlp[curl-cffi]" -y
```

### 4. Create a symlink for chromedriver

`undetected-chromedriver` may expect `chromedriver.exe` on some platforms. Create a symlink:

```bash
ln -s /data/data/com.termux/files/usr/bin/chromedriver /data/data/com.termux/files/usr/bin/chromedriver.exe
```

### 5. Clone the downloader on your Android phone

```bash
git clone https://github.com/michaelowusuntim6/animepahe-dl.git -b android
```

### 6. Move into the directory
```bash
cd ~/animepahe-dl
```

### 7. Give the scripts proper permissions

```bash
chmod +x refresh_cookie.sh animepahe-dl.sh get_cookie.py
```

### 8. First run: refresh the cookie

Animepahe is behind Cloudflare, so you need a fresh `cf_clearance` cookie. Run the refresher once:

```bash
./refresh_cookie.sh
```

This will launch a headless Chromium browser via Xvfb, solve the Turnstile challenge automatically, and write the cookie to `config.json`. If you get an error, you can manually enter the cookie (the script will prompt you).

## Usage

```
Usage:
  ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-l] [-d]

Options:
  -a <name>               anime name (opens an fzf picker)
  -s <slug>               anime slug/uuid from anime.list; ignored when -a is set
  -e <num1,num3-num4...>  episode numbers: comma list, range with "-", all with "*"
  -r <resolution>         resolution: "1080", "720"... (default: 720)
  -o <language>           audio language: "eng", "jpn"...
  -l                      print the m3u8 link only, do not download
  -d                      debug mode
  -h | --help             show this help
```

## Examples

```bash
# Search and pick an anime interactively, then download everything
./animepahe-dl.sh -a "one punch man" -e '*'

# Single episode
./animepahe-dl.sh -a "attack on titan" -e 3

# Batch: comma list and range
./animepahe-dl.sh -a "jujutsu" -e 2,5-7

# Specific resolution and audio track
./animepahe-dl.sh -a "samurai 7" -e 1 -r 720 -o eng

# List the m3u8 URL without downloading (handy for streaming)
./animepahe-dl.sh -a "samurai 7" -e 1 -l

# Stream it directly with mpv (install mpv via pkg first)
mpv --http-header-fields="Referer: https://kwik.cx/" \
    "$(./animepahe-dl.sh -a "samurai 7" -e 1 -l)"
```

Downloads are saved to `~/storage/downloads/Anime/<Anime Name>/<episode>.mp4`, which is accessible from your Android file manager under **Internal Storage → Download → Anime**.

## Troubleshooting

**`ERROR: ffmpeg exited with code 8` / `Server returned 403 Forbidden from vault-*.uwucdn.top`**

The CDN only accepts HTTP/2; ffmpeg's downloader is HTTP/1.1‑only. Make sure `pycryptodomex` is installed and `yt-dlp` uses its native downloader (do not add `--downloader ffmpeg`).

```bash
pip3.11 install pycryptodomex
```

**Invalid API response (likely expired cookie) / Need a new `cf` value in `config.json`**

The `cf_clearance` cookie expired (usually after ~30 minutes). Run `./refresh_cookie.sh` (or use the `anime-dl` wrapper). Refresh the cookie before large batch downloads.

**Failed to get cookie**

- Check that Chromium is installed: `pkg install chromium`
- Ensure `undetected-chromedriver` is installed: `pip3.11 install undetected-chromedriver`
- Verify the symlink exists: `ls -l /data/data/com.termux/files/usr/bin/chromedriver.exe`
- If you still get errors, you can manually enter the cookie (the script will prompt you after the automated attempt fails).

**The picker selects the wrong anime**

Search terms match multiple titles. Use the exact title in the fzf picker, or find the stable slug in `anime.list` and use `-s`.

## File layout

| File | Purpose |
| :--- | :--- |
| `animepahe-dl.sh` | Main downloader |
| `refresh_cookie.sh` | Solves Cloudflare and updates `config.json` |
| `get_cookie.py` | `undetected_chromedriver` automation used by `refresh_cookie.sh` |
| `config.json` | Current `cf_clearance` + user‑agent (auto‑generated, git‑ignored) |
| `anime.list` | Local cache of anime slugs (git‑ignored) |
| `.source.json` | Per‑anime episode cache (stored inside the anime folder) |

**Notes:**

- `anime.list` and the per‑anime `.source.json` caches are local and git‑ignored; anime slugs on animepahe can change over time.
- If a batch stops after an error, re‑run it — already‑downloaded episodes are skipped and the remaining ones continue.

## Credits

This project is a PC animepahe-dl bash script, with enhancements for Android, Cloudflare bypass, and native AES‑128 decryption.

## Disclaimer

The purpose of this script is to download anime episodes in order to watch them later in case when Internet is not available. Please do NOT copy or distribute downloaded anime episodes to any third party. Watch them and delete them afterwards. Please use this script at your own responsibility.
