#!/usr/bin/env bash
#
# Download anime from hianime.at in terminal (ani-cli v5.1.4 extraction pipeline)
# No Cloudflare cookie, no AES crypto, no headless browser.
#
#/ Usage:
#/   ./hianime-dl.sh [-a <anime name>] [-s <anime_id>] [-e <num1,num2,num3-num4...>] [-r <resolution>] [-o <audio>] [-l] [-d]
#/
#/ Options:
#/   -a <name>               anime name (interactive fzf picker over search results)
#/   -s <id>                 anime id/slug from anime.list; ignored when "-a" is set
#/   -e <num1,num3-num4...>  optional, episode numbers: comma list, range with "-", all with "*"
#/   -r <resolution>         optional, "1080", "720", "480", "360"
#/                           graceful fallback: default 720 -> highest available
#/   -o <language>           optional, audio: "eng" (dub) or "jpn" (sub)
#/                           graceful fallback: warns and uses whichever exists
#/   -l                      show m3u8 link without downloading
#/   -d                      enable debug mode
#/   -h | --help             display this help message
set -e
set -u

usage() { printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 1; }

set_var() {
  _CURL="$(command -v curl)" || command_not_found "curl"
  _JQ="$(command -v jq)" || command_not_found "jq"
  _FZF="$(command -v fzf)" || command_not_found "fzf"
  _YTDLP="$(command -v yt-dlp || true)"
  _SCRIPT_PATH=$(dirname "$(realpath "$0")")
  _DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  _HOST="$("$_JQ" -r '.hianime // empty' "$_SCRIPT_PATH/config.json" 2>/dev/null || true)"
  [[ -z "${_HOST:-}" ]] && _HOST="https://hianime.at"
  _USER_AGENT="$("$_JQ" -r '.ua // empty' "$_SCRIPT_PATH/config.json" 2>/dev/null || true)"
  [[ -z "${_USER_AGENT:-}" ]] && _USER_AGENT="$_DEFAULT_UA"
  _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
  _SOURCE_FILE=".source.json"
  _TAB=$'\t'
  _DOWNLOAD_DIR="$HOME/storage/downloads/Anime"
  mkdir -p "$_DOWNLOAD_DIR"
  _CONCURRENT_FRAGMENTS="${_CONCURRENT_FRAGMENTS:-16}"
}

set_args() {
  expr "$*" : ".*--help" > /dev/null && usage
  _DEFAULT_ANIME_RESOLUTION="720"
  while getopts ":hlda:s:e:r:o:" opt; do
    case $opt in
      a) _INPUT_ANIME_NAME="$OPTARG" ;;
      s) _ANIME_SLUG="$OPTARG" ;;
      e) _ANIME_EPISODE="$OPTARG" ;;
      l) _LIST_LINK_ONLY=true ;;
      r) _ANIME_RESOLUTION="$OPTARG" ;;
      o) _ANIME_AUDIO="$OPTARG" ;;
      d) set -x ;;
      h) usage ;;
      \?) print_error "Invalid option: -$OPTARG" ;;
    esac
  done
}

# Added `|| true` to prevent set -e from killing the script when _LIST_LINK_ONLY is true
print_info()  { [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[32m[INFO]\033[0m $1" >&2 || true; }
print_warn()  { [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[33m[WARNING]\033[0m $1" >&2 || true; }
print_error() { printf "%b\n" "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }
command_not_found() { print_error "$1 command not found!"; }

get() {
  # $1: url ; $2: optional referer
  local out
  out="$("$_CURL" -sS -L --connect-timeout 20 ${2:+-e "$2"} "$1" \
        -A "$_USER_AGENT" -H "Accept-Language: en-US,en;q=0.9" --compressed || true)"
  if grep -qi "Just a moment" <<< "$out"; then
    print_error "Blocked by Cloudflare on $1. Retry later or install curl-impersonate."
  fi
  printf '%s' "$out"
}

unescape() { sed -e "s|&#039;|'|g" -e 's|&quot;|"|g' -e 's|&amp;|\&|g'; }

# ---------------------------------------------------------------- search/list
search_anime_by_name() {
  # $1: query -> stdout: "id<TAB>title" (sidebar cut off BEFORE parsing, so no
  # trending/top10 pollution like the gogoanime.by bug)
  get "$_HOST/search?keyword=${1// /+}" \
    | sed '/id="main-sidebar"/,$d' \
    | tr '\n' ' ' \
    | sed 's|<div class="film-detail">|\n<div class="film-detail">|g' \
    | sed -nE 's|.*<h3 class="film-name">[[:space:]]*<a href="[^"]*/([^"/]*)"[[:space:]]*title="([^"]*)".*|\1\t\2|p' \
    | unescape \
    | awk -F'\t' '!seen[$1]++' || true
}

remove_brackets() { awk -F']' '{print $1}' | sed -E 's/^\[//'; }
remove_slug()     { awk '{$1="";print}' | awk '{$1=$1;print}'; }

get_slug_from_name() {
  grep -F "] $1   " "$_ANIME_LIST_FILE" 2>/dev/null | tail -1 | remove_brackets || true
}

# ------------------------------------------------------------------- episodes
fetch_episode_pairs() {
  # $1: anime id -> stdout: "num<TAB>epid"
  local page
  page="$(get "$_HOST/api/theme/episode/list/$1")"
  {
    tr '\n' ' ' <<< "$page" | sed 's|ep-item|\nep-item|g' \
      | sed -nE "s|.*data-number=\"([0-9]+)\".*data-id=\"([0-9]+)\".*/watch/$1\?ep=.*|\1\t\2|p"
    tr '\n' ' ' <<< "$page" | sed 's|ep-item|\nep-item|g' \
      | sed -nE "s|.*data-id=\"([0-9]+)\".*data-number=\"([0-9]+)\".*/watch/$1\?ep=.*|\2\t\1|p"
  } | awk -F'\t' '!seen[$1]++' | sort -t "$_TAB" -k1,1n -u || true
}

download_source() {
  local anime_dir="$_SCRIPT_PATH/$_ANIME_NAME" tsv
  mkdir -p "$anime_dir"
  tsv="$anime_dir/.episodes.tsv"
  fetch_episode_pairs "$_ANIME_SLUG" > "$tsv"
  [[ -s "$tsv" ]] || print_error "No episodes found for '$_ANIME_SLUG' on $_HOST"
  "$_JQ" -R -s 'split("\n") | map(select(length>0) | split("\t") | {episode: (.[0]|tonumber), epid: .[1]})' \
    "$tsv" > "$anime_dir/$_SOURCE_FILE"
  rm -f "$tsv"
  "$_JQ" -e 'length > 0' "$anime_dir/$_SOURCE_FILE" >/dev/null \
    || print_error "Wrote invalid episode cache to $anime_dir/$_SOURCE_FILE"
}

select_episodes_to_download() {
  local source_path="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE" s
  [[ ! -f "$source_path" ]] && print_error "Episode list file missing: $source_path"
  "$_JQ" -r '.[] | "[\(.episode)] E\(.episode)"' "$source_path" >&2
  echo -n "Which episode(s) to download: " >&2
  read -r s
  echo "$s"
}

# ------------------------------------------------------- embed blob decoding
# base64(json XOR "otaku-embed-v1") -> json   (algorithm from ani-cli master)
deobfuscate_blob() (
  _bytes="$(printf '%s\n' "$1" | base64 -d 2>/dev/null | od -v -An -tu1)"
  set -- 111 116 97 107 117 45 101 109 98 101 100 45 118 49
  _output=""
  for _byte in $_bytes; do
    _char=$((_byte ^ $1))
    _output="${_output}0$((_char / 64))$(((_char / 8) % 8))$((_char % 8))"
    set -- "$@" "$1"
    shift
  done
  printf '%b' "$_output"
)

get_master_playlist() {
  # $1: epid, $2: mode (sub|dub) -> stdout: "master_m3u8<TAB>referer"
  local servers hash embed page blob master refr
  servers="$(get "$_HOST/api/theme/episode/servers?episodeId=$1" | sed 's|server-item|\nserver-item|g')"
  hash="$(sed -nE 's|.*data-type="'"$2"'"[^>]*data-server-name="ZokoAnime"[^>]*data-hash="([^"]*)".*|\1|p' <<< "$servers" | head -1 || true)"
  [[ -z "$hash" ]] && hash="$(sed -nE 's|.*data-hash="([^"]*)"[^>]*data-type="'"$2"'"[^>]*data-server-name="ZokoAnime".*|\1|p' <<< "$servers" | head -1 || true)"
  [[ -z "$hash" ]] && return 1
  embed="$(printf '%s\n' "$hash" | base64 -d 2>/dev/null || true)"
  [[ -z "$embed" ]] && return 1
  page="$(get "$embed")"
  blob="$(sed -nE 's|.*window\.__P="([^"]*)".*|\1|p' <<< "$page" | head -1 || true)"
  [[ -z "$blob" ]] && return 1
  master="$(sed -nE 's|.*"src":"([^"]*\.m3u8[^"]*)".*|\1|p' <<< "$(deobfuscate_blob "$blob")" | head -1 || true)"
  [[ -z "$master" ]] && return 1
  refr="$(sed -E 's|^(https?://[^/]*).*|\1/|' <<< "$embed")"
  printf '%s\t%s' "$master" "$refr"
}

pick_variant() {
  # $1: master m3u8 url, $2: referer -> stdout: "height<TAB>variant_url"
  local links want r
  links="$(get "$1" "$2" \
    | sed 's|^#EXT-X-STREAM-INF.*x||g; s|,.*|p|g; /^#/d; $!N; s|\n|>|; /EXT-X-I-FRAME/d' \
    | sed "\|>https*://|!s|>|>${1%/*}/|" \
    | sort -g -r -s || true)"
  [[ -z "$links" ]] && return 1
  want="${_ANIME_RESOLUTION:-}"
  if [[ -n "$want" ]]; then
    print_info "Select video resolution: ${want}p"
    r="$(grep -m1 "^${want}>" <<< "$links" || true)"
    if [[ -z "$r" ]]; then
      print_warn "Selected video resolution is not available, fallback to default ${_DEFAULT_ANIME_RESOLUTION}p."
      r="$(grep -m1 "^${_DEFAULT_ANIME_RESOLUTION}>" <<< "$links" || true)"
    fi
    if [[ -z "$r" ]]; then
      print_warn "Default resolution unavailable too; using highest available."
      r="$(head -1 <<< "$links")"
    fi
  else
    r="$(head -1 <<< "$links")"
    print_info "Using highest available resolution: ${r%%>*}p"
  fi
  local h u
  h="${r%%>*}"; u="${r#*>}"
  printf '%s\t%s' "$h" "$u"
}

# ---------------------------------------------------------------- downloading
download_episodes() {
  local origel el uniqel i n s e eps fst lst source_path
  source_path="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
  origel=()
  if [[ "$1" == *","* ]]; then
    IFS="," read -ra ADDR <<< "$1"
    for n in "${ADDR[@]}"; do origel+=("$n"); done
  else
    origel+=("$1")
  fi
  el=()
  for i in "${origel[@]}"; do
    if [[ "$i" == *"*"* ]]; then
      eps="$("$_JQ" -r '.[].episode' "$source_path" | sort -nu)"
      fst="$(head -1 <<< "$eps")"; lst="$(tail -1 <<< "$eps")"
      i="${fst}-${lst}"
    fi
    if [[ "$i" == *"-"* ]]; then
      s=$(awk -F '-' '{print $1}' <<< "$i")
      e=$(awk -F '-' '{print $2}' <<< "$i")
      for n in $(seq "$s" "$e"); do el+=("$n"); done
    else
      el+=("$i")
    fi
  done
  IFS=" " read -ra uniqel <<< "$(printf '%s\n' "${el[@]}" | sort -n -u | tr '\n' ' ')"
  [[ ${#uniqel[@]} == 0 ]] && print_error "Wrong episode number!"
  for e in "${uniqel[@]}"; do download_episode "$e"; done
}

download_episode() {
  # $1: episode number
  local num="$1" v epid src mode other pair master refr chosen h u
  src="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
  v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"
  mkdir -p "$(dirname "$v")"
  if [[ -z "${_LIST_LINK_ONLY:-}" && -s "$v" ]]; then
    print_info "Episode $num already downloaded, skipping."
    return
  fi
  epid="$("$_JQ" -r --arg n "$num" '.[] | select(.episode == ($n|tonumber)) | .epid' "$src")"
  [[ "$epid" == "" ]] && print_warn "Episode $num not found!" && return

  case "${_ANIME_AUDIO:-jpn}" in
    eng) mode="dub"; other="sub" ;;
    *)   mode="sub"; other="dub" ;;
  esac
  pair="$(get_master_playlist "$epid" "$mode" || true)"
  if [[ -z "$pair" ]]; then
    print_warn "Selected audio language (${_ANIME_AUDIO:-jpn}) is not available, fallback to default (${other})."
    pair="$(get_master_playlist "$epid" "$other" || true)"
  fi
  if [[ -z "$pair" ]]; then
    print_warn "Missing video list! Skip downloading episode $num!"
    return
  fi
  master="${pair%%$_TAB*}"; refr="${pair#*$_TAB}"
  chosen="$(pick_variant "$master" "$refr" || true)"
  if [[ -z "$chosen" ]]; then
    print_warn "Missing video list! Skip downloading episode $num!"
    return
  fi
  h="${chosen%%$_TAB*}"; u="${chosen#*$_TAB}"
  if [[ -n "${_LIST_LINK_ONLY:-}" ]]; then echo "$u"; return; fi
  print_info "Downloading Episode $num (${h}p) ..."
  if [[ -n "$_YTDLP" ]]; then
    "$_YTDLP" "$u" \
      --referer "$refr" \
      --user-agent "$_USER_AGENT" \
      --no-skip-unavailable-fragments \
      --fragment-retries infinite \
      -N "$_CONCURRENT_FRAGMENTS" \
      --no-warnings -q --progress -o "$v" \
    || print_warn "yt-dlp failed for episode $num; trying ffmpeg..."
  fi
  if [[ ! -s "$v" ]]; then
    command -v ffmpeg >/dev/null \
      && ffmpeg -extension_picky 0 -referer "$refr" -loglevel error -stats -i "$u" -c copy "$v" \
      || print_warn "No downloader available for episode $num."
  fi
  [[ -s "$v" ]] || print_warn "Empty file for episode $num; skipped."
}

# Fixed: Using `if` instead of `&&` to prevent a silent exit code 1 under `set -e`
check_config() {
  if [[ -z "${_HOST:-}" ]]; then
    print_error "Empty host in config.json."
  fi
}

main() {
  set_args "$@"
  set_var
  check_config
  local res query
  if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
    query="$_INPUT_ANIME_NAME"
  elif [[ -z "${_ANIME_SLUG:-}" ]]; then
    echo -n "Search anime: " >&2
    read -r query
  fi
  if [[ -n "${query:-}" ]]; then
    print_info "Searching '$query' on $_HOST ..."
    res="$(search_anime_by_name "$query")" || true
    if [[ -z "$res" ]]; then
      print_error "No search result for '$query' on $_HOST"
    fi
    : > "$_SCRIPT_PATH/.picker.tmp"
    while IFS="$_TAB" read -r id title; do
      printf '[%s] %s   \n' "$id" "$title"
    done <<< "$res" | tee -a "$_ANIME_LIST_FILE" > "$_SCRIPT_PATH/.picker.tmp"
    _picker_list="$(remove_slug < "$_SCRIPT_PATH/.picker.tmp")"
    if [[ -z "$_picker_list" ]]; then
      print_error "Search returned unparseable results for '$query'."
    fi
    _ANIME_NAME="$("$_FZF" -1 <<< "$_picker_list" || true)"
    if [[ -z "$_ANIME_NAME" ]]; then
      print_error "No anime selected (fzf returned nothing)."
    fi
    rm -f "$_SCRIPT_PATH/.picker.tmp"
    _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
  fi
  [[ "${_ANIME_SLUG:-}" == "" ]] && print_error "Anime id not found!"
  _ANIME_NAME="$(grep -F "[$_ANIME_SLUG]" "$_ANIME_LIST_FILE" \
    | tail -1 | remove_slug | sed -E 's/[[:space:]]+$//' || true)"
  [[ -z "${_ANIME_NAME:-}" ]] && _ANIME_NAME="$(sed -E 's/-/ /g' <<< "$_ANIME_SLUG")"
  _ANIME_NAME="$(sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g' <<< "$_ANIME_NAME")"
  download_source
  [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
  download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
