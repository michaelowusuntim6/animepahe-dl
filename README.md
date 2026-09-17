# gogoanime-dl
Download anime episodes from [gogoanime](https://gogoanime.by) mirrors directly on your Android device using Termux — **no Cloudflare cookie, no headless browser, no JS unpacking**.
The script searches the mirror's server-rendered pages, resolves the episode list, and extracts **direct MP4 links** from each episode's download page (plain per-quality anchors). Only when an episode offers no MP4 does it fall back to the HLS player stream via `yt-dlp`, remuxing the result into a clean MP4. Finished files land in your Android Downloads folder.
> This is the successor to `animepahe-dl`. Same CLI, same `fzf` picker, same batch grammar — but ~80% less machinery: `refresh_cookie.sh`, `get_cookie.py`, Chromium, Xvfb, `undetected-chromedriver` and `pycryptodomex` are gone, because gogoanime mirrors serve their pages and files without a Cloudflare Turnstile wall.
## Features
- Search by anime name (`-a`) with an interactive `fzf` picker, or use a slug directly (`-s`)
- Single, comma-separated, ranged, and "all episodes" batch downloads (`-e 1,2,5-7,*`)
- Resolution selection (`-r 1080/720/480/360`) with **graceful fallback**: requested → default 720 → highest available
- Audio selection (`-o eng` = dub, `-o jpn` = sub) with **graceful fallback** to whichever entry (dub/sub) actually exists
- Print the direct video link without downloading (`-l`) to stream in a media player
- Direct MP4 downloads via plain resumable `curl`; HLS fallback via `yt-dlp` + `ffmpeg` remux
- Re-runs skip already-downloaded (non-empty) episodes, so interrupted batches resume cleanly
- Domain-rotation proof: the mirror host lives in `config.json` — one line to change when a domain is seized
- Per-anime episode cache (`.source.json`) so episode re-selection is instant and works offline
## How a download is resolved
1. **Search / list** — `search.html?keyword=...` or `anime-list.html` is parsed for `/category/<slug>` entries.
2. **Audio pick** — dub and sub are separate entries on gogoanime (`<slug>` vs `<slug>-dub`); `-o` probes the variant with a live HTTP check and falls back with a warning if missing.
3. **Episode list** — scraped from the category page; if the mirror loads episodes via AJAX, the script automatically retries against `ajax.gogocdn.com` and `ajax.gogo-play.com`.
4. **Video link** — the episode page's `download?id=...` page lists direct `.mp4` anchors labelled `(360p)…(1080p)`; the requested/default/highest quality is chosen. Fallback: player iframe → embed page → `.m3u8` → `yt-dlp`.
## Requirements
Target platform: Termux (Android arm64/aarch64).

| Component | Purpose |
| :--- | :--- |
| `curl`, `jq`, `fzf` | Page requests, HTML/JSON parsing, interactive anime picker |
| `ffmpeg` | *Only* for remuxing the rare HLS fallback into MP4 |
| `yt-dlp` | *Only* for the rare HLS fallback (episodes without direct MP4 links) |

**No longer required** (compared to `animepahe-dl`): `chromium`, `xorg-server-xvfb`, `python3.11` + `pip`, `undetected-chromedriver`, `pycryptodomex`, `yt-dlp[curl-cffi]`.
You can download the Termux app from the release page or by using this link:
https://github.com/michaelowusuntim6/animepahe-dl/releases/download/V1.00/Termux.0.119.0-beta.3.apk
## Installation (Termux)
1. Grant storage access
```bash
termux-setup-storage
```
2. Install system packages
```bash
pkg update && pkg upgrade -y
```
```bash
pkg install -y jq fzf git curl ffmpeg yt-dlp
```
3. Clone the downloader on your Android phone
```bash
git clone https://github.com/michaelowusuntim6/animepahe-dl.git -b gogo
```
4. Move into the directory
```bash
cd ~/animepahe-dl
```
5. Give the script proper permissions
```bash
chmod +x gogoanime-dl.sh
```
6. First run — **there is no cookie step**. Unlike animepahe, gogoanime mirrors answer plain HTTP requests, so the tool works out of the box:
```bash
./gogoanime-dl.sh -a "one punch man" -e 1
```
## Configuration (`config.json`)
```json
{
  "host": "[https://gogoanime.by](https://gogoanime.by)",
  "ua": ""
}
```

| Key | Meaning |
| :--- | :--- |
| `host` | Base URL of the mirror. When a domain is seized or parked, change **only this line**. Known-good alternates: `https://gogoanime.by`, `https://gogoanime3.cc`, `https://anitaku.com.ro` |
| `ua` | Optional User-Agent. Leave empty (`""`) to use the built-in Chrome UA |

Optional environment variable: `_CONCURRENT_FRAGMENTS` (default `32`) — parallel fragments for the HLS fallback path only.
## Usage
```
Usage:
  ./gogoanime-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-o <audio>] [-l] [-d]
Options:
  -a <name>               anime name (opens an fzf picker)
  -s <slug>               anime slug (category id) from anime.list; ignored when -a is set
  -e <num1,num3-num4...>  episode numbers: comma list, range with "-", all with "*"
  -r <resolution>         resolution: "1080", "720", "480", "360"
                          graceful fallback: default 720 -> highest available
  -o <language>           audio: "eng" (dub) or "jpn" (sub); graceful fallback to whichever exists
  -l                      print the direct video link only, do not download
  -d                      debug mode
  -h | --help             show this help
```
## Examples
```bash
# Search and pick an anime interactively, then download everything
./gogoanime-dl.sh -a "one punch man" -e '*'
# Single episode
./gogoanime-dl.sh -a "attack on titan" -e 3
# Batch: comma list and range
./gogoanime-dl.sh -a "jujutsu" -e 2,5-7
# English dub, 1080p, with graceful fallbacks if either is unavailable
./gogoanime-dl.sh -a "re monster" -e 12 -r 1080 -o eng
# Japanese sub batch by slug
./gogoanime-dl.sh -s remonster -e 1,3-5 -o jpn
# List the direct MP4 URL without downloading (handy for streaming)
./gogoanime-dl.sh -a "samurai 7" -e 1 -l
# Stream it directly with mpv (install mpv via pkg first)
mpv --http-header-fields="Referer: [https://gogoanime.by/](https://gogoanime.by/)" \
    "$(./gogoanime-dl.sh -a "samurai 7" -e 1 -l)"
```
Downloads are saved to `~/storage/downloads/Anime/<Anime Name>/<episode>.mp4`, which is accessible from your Android file manager under Internal Storage → Download → Anime.
## Graceful fallback behaviour

| Situation | What happens |
| :--- | :--- |
| `-r 1080` not offered | `[WARNING] Selected video resolution is not available, fallback to default 720p.` |
| 720 also not offered | `[WARNING] Default resolution unavailable too; using highest available.` |
| No `-r` given | `[INFO] Using highest available resolution: <top>p` |
| `-o eng` but no dub entry | `[WARNING] Selected audio language (eng) is not available, fallback to default (jpn/sub).` |
| `-o jpn` but only dub exists | `[WARNING] ... fallback to default (dub entry).` |
| Episode number not in cache | `[WARNING] Episode N not found!` — batch continues |
| Episode has no MP4 anchors | HLS iframe extraction → `yt-dlp` download + remux |
| HLS stream unextractable | `[WARNING] Missing video list! Skip downloading episode N!` — batch continues |
| File already downloaded | `[INFO] Episode N already downloaded, skipping.` |

## Troubleshooting
**`403 Forbidden` while downloading an MP4**
The script already sends the required `Referer` and browser UA to the CDN. A persistent 403 usually means the mirror rotated or the CDN changed hotlink rules — switch `host` in `config.json` to an alternate mirror and re-run (completed episodes are skipped automatically).
**`No episodes found for '<slug>'`**
Both the server-rendered episode list and the AJAX endpoints (`ajax.gogocdn.com`, `ajax.gogo-play.com`) came back empty — the mirror changed domain or layout. Update `host` in `config.json`.
**Search returns nothing / fzf picker is empty**
The domain is likely parked or seized (a "coming soon" page). Change `host` in `config.json`. You can also bypass search entirely with `-s <slug>` using a slug from `anime.list`.
**`yt-dlp not installed; cannot use HLS fallback`**
Only affects the rare episode without direct MP4 links. Install it with `pkg install yt-dlp` (or `pip install yt-dlp`). Normal MP4 downloads never touch yt-dlp.
**The picker selects the wrong anime**
Search terms match multiple titles. Pick the exact title in the fzf picker, or find the stable slug in `anime.list` and use `-s`.
**Migrating from `animepahe-dl`**
Delete the old `anime.list` and any per-anime `.source.json` caches — their formats changed (the new cache stores `{episode, slug}` pairs). `refresh_cookie.sh` and `get_cookie.py` are obsolete and can be deleted, along with Chromium/Xvfb/undetected-chromedriver/pycryptodomex.
## File layout

| File | Purpose |
| :--- | :--- |
| `gogoanime-dl.sh` | Main downloader |
| `config.json` | Mirror `host` + optional `ua` |
| `anime.list` | Local cache of anime slugs (git-ignored) |
| `.source.json` | Per-anime episode cache (stored inside the anime folder) |

Notes:
- `anime.list` and the per-anime `.source.json` caches are local and git-ignored; slugs on gogoanime mirrors can change over time.
- If a batch stops after an error, re-run it — already-downloaded episodes are skipped and the remaining ones continue.
## Support
If you find this project useful and would like to support its development, you can send a donation via USDT (Tether) to one of the following addresses:
· TRC‑20 (Tron network): TXAYrPatZEeHUzjMzY7EsP4zbkJicqT5Tk
· ERC‑20 (Ethereum network): 0x5f259fb64f3f76aa33959b3c8e6a7f1b2ffe8e24
## Credits
This project is a PC animepahe-dl bash script, enhanced for Android, Cloudflare bypass, and native AES‑128 decryption — and now reborn as a gogoanime-network downloader that needs none of that bypass machinery at all.
## Disclaimer
The purpose of this script is to download anime episodes in order to watch them later in case when Internet is not available. Please do NOT copy or distribute downloaded anime episodes to any third party. Watch them and delete them afterwards. Please use this script at your own responsibility.
