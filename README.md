# animepahe-dl

Download anime episodes from [animepahe](https://animepahe.pw) in the terminal.

The script resolves the anime's episode list from the animepahe API, unpacks the
kwik player page to find the real HLS playlist, and downloads every fragment
with yt-dlp — then remuxes the finished file into a clean MP4.

## Features

- Search by anime name (`-a`) with an interactive `fzf` picker, or use a slug directly (`-s`)
- Single, comma-separated, ranged, and "all episodes" batch downloads (`-e 1,2,5-7,*`)
- Resolution (`-r`) and audio-language (`-o`) selection
- Prints the m3u8 URL without downloading (`-l`) so you can stream it in a media player
- Automatic Cloudflare `cf_clearance` refresh (`./refresh_cookie.sh` or the `anime-dl` wrapper)
- AES-128-encrypted HLS handled natively over HTTP/2; output remuxed to MP4

## Requirements

Target platform: **Debian / Ubuntu / Pop!_OS** (anything with `apt`).

| Component            | Purpose                                                    |
| -------------------- | ---------------------------------------------------------- |
| `curl`, `jq`, `fzf`  | animepahe API requests, JSON parsing, anime picker         |
| `ffmpeg`             | remuxing the downloaded stream into MP4                    |
| `xvfb`               | headless display for the Cloudflare cookie refresher       |
| `python3` + `pip`    | runs `get_cookie.py` (undetected_chromedriver)             |
| Chrome / Chromium    | solves the Cloudflare Turnstile challenge                  |
| `pipx` + `yt-dlp[default]` | downloads the HLS stream (curl_cffi impersonation)    |
| `pycryptodomex` (in the yt-dlp venv) | native AES-128 HLS decryption               |

> Why pycryptodomex matters: the CDN that hosts the episodes (e.g.
> `vault-*.uwucdn.top`) rejects **HTTP/1.1** requests with 403 Forbidden.
> ffmpeg's downloader is HTTP/1.1-only, so yt-dlp must decrypt AES-128 streams
> itself (over HTTP/2) using pycryptodomex. Do **not** add `--downloader ffmpeg`.

## Installation

### Quick (recommended)

Run the setup script. It is idempotent — safe to re-run, and it only installs
what is missing:

```bash
./setup.sh
```

`setup.sh` will:

1. install the system packages with `apt` (asks for your password via `sudo`);
2. install Google Chrome if no Chrome/Chromium binary is found;
3. install `pipx` and `yt-dlp[default]`, then inject `pycryptodomex` and
   `curl_cffi` into the yt-dlp venv;
4. create a repo-local `.venv` with `undetected_chromedriver` for the cookie
   refresher;
5. verify the install and offer to refresh the cookie immediately.

### Manual

```bash
# System packages (Debian/Ubuntu/Pop!_OS)
sudo apt update
sudo apt install -y curl jq fzf ffmpeg xvfb python3 python3-venv python3-pip pipx

# Chrome (or install Chromium; see CHROME_BIN below)
# ... install Google Chrome from https://www.google.com/chrome/ ...

# yt-dlp in its own venv, with AES-128 + impersonation support
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
pipx install "yt-dlp[default]"
pipx inject yt-dlp pycryptodomex

# Cookie refresher dependencies
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## First run: refresh the cookie

animepahe is behind Cloudflare, so requests need a fresh `cf_clearance` cookie.
The refresher launches a real browser headlessly (via `xvfb-run`), waits for the
challenge to pass, and writes the cookie and user-agent into `config.json`:

```bash
./refresh_cookie.sh
```

The `anime-dl` wrapper does this automatically before every download:

```bash
./anime-dl -a "Naruto" -e 1
```

If the auto-detected browser is wrong for your machine, override it with
environment variables:

```bash
CHROME_BIN=/snap/bin/chromium CHROMEDRIVER_BIN=/usr/bin/chromedriver ./refresh_cookie.sh
```

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

### Examples

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

# Stream it directly with mpv
mpv --http-header-fields="Referer: https://kwik.cx/" \
    "$(./animepahe-dl.sh -a "samurai 7" -e 1 -l)"
```

Downloads are saved to `~/Videos/Anime/<Anime Name>/<episode>.mp4`.

## Troubleshooting

**`ERROR: ffmpeg exited with code 8` / `Server returned 403 Forbidden` from
`vault-*.uwucdn.top`**

The CDN only accepts HTTP/2, but ffmpeg's downloader speaks HTTP/1.1. Make sure
yt-dlp uses its native downloader and that `pycryptodomex` is installed inside
the yt-dlp venv so AES-128 streams are decrypted natively:

```bash
pipx inject yt-dlp pycryptodomex
```

**`Invalid API response (likely expired cookie)` / `Need a new cf value in
config.json`**

The `cf_clearance` cookie expired. Run `./refresh_cookie.sh` (or use the
`anime-dl` wrapper). The cookie typically lasts about 30 minutes, so refresh it
before large batch downloads.

**`Failed to get cookie`**

Check that Chrome/Chromium is installed and that `undetected_chromedriver`
can be imported by the interpreter running `get_cookie.py` (`.venv/bin/python`
after `./setup.sh`). Set `CHROME_BIN` / `CHROMEDRIVER_BIN` if your browser or
driver lives somewhere unusual.

**The picker selects the wrong anime**

Search terms match multiple titles. Use the exact title in the fzf picker, or
find the stable slug in `anime.list` and use `-s`.

## File layout

| File                | Purpose                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `animepahe-dl.sh`   | main downloader                                                    |
| `anime-dl`          | wrapper: refreshes the cookie, then downloads                      |
| `refresh_cookie.sh` | solves Cloudflare and updates `config.json`                        |
| `get_cookie.py`     | undetected_chromedriver automation used by `refresh_cookie.sh`     |
| `config.json`       | current `cf_clearance` + user-agent (auto-generated, git-ignored)  |
| `setup.sh`          | one-shot installer (idempotent)                                    |
| `requirements.txt`  | Python deps for the cookie refresher (`undetected-chromedriver`)   |

Notes:

- `anime.list` and the per-anime `.source.json` caches are local and
  git-ignored; anime slugs on animepahe can change over time.
- If a batch stops after an error, re-run it — already-downloaded episodes are
  skipped and the remaining ones continue.

Support

If you find this project useful and would like to support its development, you can send a donation via USDT (Tether) to one of the following addresses:

· TRC‑20 (Tron network): TXAYrPatZEeHUzjMzY7EsP4zbkJicqT5Tk

· ERC‑20 (Ethereum network): 0x5f259fb64f3f76aa33959b3c8e6a7f1b2ffe8e24

## Disclaimer

The purpose of this script is to download anime episodes in order to watch them later in case when Internet is not available. Please do NOT copy or distribute downloaded anime episodes to any third party. Watch them and delete them afterwards. Please use this script at your own responsibility.
