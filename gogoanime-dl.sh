#!/usr/bin/env bash
#
# Download anime from gogoanime mirrors (e.g. gogoanime.by) in terminal
# Auto-detects Classic Gogoanime vs WordPress clones
#
#/ Usage:
#/   ./gogoanime-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-o <audio>] [-l] [-d]
#/
#/ Options:
#/   -a <name>               anime name (interactive fzf picker over search results)
#/   -s <slug>               anime slug (category id), ignored when "-a" is set
#/   -e <num1,num3-num4...>  optional, episode numbers to download
#/                           comma separated, ranges with "-", all episodes with "*"
#/   -r <resolution>         optional, "1080", "720", "480", "360"
#/                           graceful fallback: default 720 -> highest available
#/   -o <language>           optional, audio: "eng" (dub) or "jpn" (sub)
#/                           graceful fallback: warns and uses whichever exists
#/   -l                      show direct video link without downloading
#/   -d                      enable debug mode
#/   -h | --help             display this help message
set -e
set -u

usage() {
  printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 1
}

set_var() {
  _CURL="$(command -v curl)" || command_not_found "curl"
  _JQ="$(command -v jq)" || command_not_found "jq"
  _FZF="$(command -v fzf)" || command_not_found "fzf"
  _YTDLP="$(command -v yt-dlp || true)"
  _SCRIPT_PATH=$(dirname "$(realpath "$0")")
  _DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  _HOST="$("$_JQ" -r '.host // empty' "$_SCRIPT_PATH/config.json" 2>/dev/null || true)"
  [[ -z "${_HOST:-}" ]] && _HOST="https://gogoanime.by"
  _USER_AGENT="$("$_JQ" -r '.ua // empty' "$_SCRIPT_PATH/config.json" 2>/dev/null || true)"
  [[ -z "${_USER_AGENT:-}" ]] && _USER_AGENT="$_DEFAULT_UA"
  _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
  _SOURCE_FILE=".source.json"
  _TAB=$'\t'
  _DOWNLOAD_DIR="$HOME/storage/downloads/Anime"
  mkdir -p "$_DOWNLOAD_DIR"
  _CONCURRENT_FRAGMENTS="${_CONCURRENT_FRAGMENTS:-32}"
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

print_info()  { [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[32m[INFO]\033[0m $1" >&2; }
print_warn()  { [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[33m[WARNING]\033[0m $1" >&2; }
print_error() { printf "%b\n" "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }
command_not_found() { print_error "$1 command not found!"; }

get() {
  "$_CURL" -sS -L --connect-timeout 20 "$1" \
    -A "$_USER_AGENT" -H "Accept-Language: en-US,en;q=0.9" --compressed || true
}

format_entries() {
  sed -E 's|href="/category/|[|; s|" title="|] |; s|"$|   |'
}

download_anime_list() {
  get "$_HOST/anime-list.html" \
    | grep -oE 'href="/category/[^"]+" title="[^"]+"' \
    | format_entries \
    > "$_ANIME_LIST_FILE" || true
}

search_anime_by_name() {
  local query="${1// /%20}"
  local html classic_results wp_results
  
  # 1. Try classic Gogoanime search
  html="$(get "$_HOST/search.html?keyword=$query")"
  classic_results="$(grep -oE 'href="/category/[^"]+" title="[^"]+"' <<< "$html" | format_entries || true)"
  
  if [[ -n "$classic_results" ]]; then
    echo "$classic_results" | tee -a "$_ANIME_LIST_FILE" | remove_slug
    return
  fi

  # 2. Fallback to WordPress search (e.g., gogoanime.by uses /?s=)
  print_info "Classic search not found, trying WordPress search (?s=)..."
  html="$(get "$_HOST/?s=$query")"
  
  # Look for links to /series/ or any link containing the search query
  wp_results="$(grep -oE 'href="[^"]*series/[^"]*"[^>]*>[^<]+<' <<< "$html" || true)"
  if [[ -z "$wp_results" ]]; then
    wp_results="$(grep -iE "href=\"[^\"]+\"[^>]*>[^<]*$1[^<]*<" <<< "$html" | head -10 || true)"
  fi

  if [[ -z "$wp_results" ]]; then
    print_error "No search result for '$1' on $_HOST (tried both classic and WordPress search)"
  fi

  # Format for fzf: [slug] Title
  while read -r line; do
    local url title slug
    url="$(echo "$line" | sed -E 's/.*href="([^"]+)".*/\1/')"
    title="$(echo "$line" | sed -E 's/.*>([^<]+)<.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    slug="$(basename "$url" | sed 's|/$||')"
    [[ -z "$slug" || "$slug" == "$_HOST" ]] && continue
    echo "[$slug] $title   "
  done <<< "$wp_results" | tee -a "$_ANIME_LIST_FILE" | remove_slug
}

remove_brackets() { awk -F']' '{print $1}' | sed -E 's/^\[//'; }
remove_slug()     { awk '{$1="";print}' | awk '{$1=$1;print}'; }

get_slug_from_name() {
  grep -F "] $1   " "$_ANIME_LIST_FILE" | tail -1 | remove_brackets || true
}

category_exists() {
  local code
  code="$("$_CURL" -s -o /dev/null -w '%{http_code}' -L --connect-timeout 20 \
            "$_HOST/category/$1" -A "$_USER_AGENT" || true)"
  [[ "$code" == "200" ]]
}

resolve_audio_slug() {
  local slug="$1" audio="${_ANIME_AUDIO:-}" base
  [[ -z "$audio" ]] && { echo "$slug"; return; }
  if [[ "$audio" == "eng" ]]; then
    [[ "$slug" == *-dub ]] && { echo "$slug"; return; }
    if category_exists "${slug}-dub"; then
      print_info "English audio requested: using dub entry '${slug}-dub'."
      echo "${slug}-dub"
    else
      print_warn "Selected audio language (eng) is not available, fallback to default (jpn/sub)."
      echo "$slug"
    fi
  else
    if [[ "$slug" == *-dub ]]; then
      base="${slug%-dub}"
      if category_exists "$base"; then
        print_info "Japanese audio requested: using sub entry '$base'."
        echo "$base"
      else
        print_warn "Selected audio language ($audio) is not available, fallback to default (dub entry)."
        echo "$slug"
      fi
    else
      echo "$slug"
    fi
  fi
}

extract_episode_hrefs() {
  # Handles both relative (/slug-episode-1) and absolute (https://host/slug-episode-1) URLs
  grep -oE 'href="[^"]*-episode-[0-9]+[^"]*"' \
    | sed -E 's|^href="||; s|"$||' \
    | sed -E 's|^https?://[^/]+||' \
    | sed -E 's|^/||' \
    | awk '!seen[$0]++' || true
}

fetch_episode_slugs() {
  local slug="$1"
  local html eps mid h p chunk more
  
  # 1. Try classic Gogoanime category page
  html="$(get "$_HOST/category/$slug")"
  eps="$(extract_episode_hrefs <<< "$html")"
  
  if [[ -z "$eps" ]]; then
    # 2. Try WordPress series page
    print_info "Classic category page empty, trying WordPress /series/ page..."
    html="$(get "$_HOST/series/$slug/")"
    eps="$(extract_episode_hrefs <<< "$html")"
    
    if [[ -z "$eps" ]]; then
      # 3. Try just the base URL if /series/ doesn't exist
      html="$(get "$_HOST/$slug/")"
      eps="$(extract_episode_hrefs <<< "$html")"
    fi
  fi
  
  if [[ -z "$eps" ]]; then
    # AJAX fallback for classic mirrors
    mid="$(grep -oE '<input[^>]*id="movie_id"[^>]*>' <<< "$html" | grep -oE '[0-9]+' | head -1 || true)"
    if [[ -n "$mid" ]]; then
      for h in "$_HOST" "https://ajax.gogocdn.com" "https://ajax.gogo-play.com"; do
        chunk="$(get "$h/ajax/page-episode?id=$mid&start=1&end=99999")"
        more="$(extract_episode_hrefs <<< "$chunk")"
        [[ -n "$more" ]] && eps+=$'\n'"$more"
        p=1
        while (( p <= 30 )); do
          chunk="$(get "$h/ajax/page/load_episodes?eid=$mid&episode_page=$p&alias=$slug")"
          more="$(extract_episode_hrefs <<< "$chunk")"
          [[ -z "$more" ]] && break
          eps+=$'\n'"$more"
          p=$((p+1))
        done
        [[ -n "$eps" ]] && break
      done
    fi
  fi
  
  printf '%s\n' "$eps" \
    | grep -Ee '-episode-[0-9]+' \
    | sed -E 's|^(.*)-episode-([0-9]+).*$|\2\t\1|' \
    | sort -t "$_TAB" -k1,1n -u || true
}

download_source() {
  local anime_dir="$_SCRIPT_PATH/$_ANIME_NAME" tsv
  mkdir -p "$anime_dir"
  tsv="$anime_dir/.episodes.tsv"
  fetch_episode_slugs "$_ANIME_SLUG" > "$tsv"
  [[ -s "$tsv" ]] || print_error "No episodes found for '$_ANIME_SLUG' on $_HOST"
  "$_JQ" -R -s 'split("\n") | map(select(length>0) | split("\t") | {episode: (.[0]|tonumber), slug: .[1]})' \
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

parse_download_page() {
  tr '\n' ' ' \
    | sed -E 's/<a href="/\n<a href="/g' \
    | grep -E '^<a href="https?://' \
    | awk '{
        url=$0; sub(/^<a href="/,"",url); sub(/".*/,"",url);
        line=tolower($0);
        q="";
        if (match(line, /\([0-9]+p\)/)) {
          q=substr(line, RSTART+1, RLENGTH-2);
        } else if (match(line, />[0-9]+p *</)) {
          q=substr(line, RSTART+1, RLENGTH-3);
        }
        if (q != "" && url ~ /\.mp4/) print q "\t" url;
      }' || true
}

pick_quality() {
  local want="${_ANIME_RESOLUTION:-}" r
  if [[ -n "$want" ]]; then
    print_info "Select video resolution: ${want}p"
    r="$(awk -F'\t' -v w="$want" '$1==w {print; exit}' <<< "$1" || true)"
    if [[ -z "$r" ]]; then
      print_warn "Selected video resolution is not available, fallback to default ${_DEFAULT_ANIME_RESOLUTION}p."
      want="$_DEFAULT_ANIME_RESOLUTION"
      r="$(awk -F'\t' -v w="$want" '$1==w {print; exit}' <<< "$1" || true)"
    fi
    if [[ -z "$r" ]]; then
      print_warn "Default resolution unavailable too; using highest available."
      r="$(sort -t "$_TAB" -k1,1n <<< "$1" | tail -1)"
    fi
  else
    r="$(sort -t "$_TAB" -k1,1n <<< "$1" | tail -1)"
    print_info "Using highest available resolution: ${r%%$_TAB*}p"
  fi
  echo "$r"
}

get_stream_fallback() {
  local iframe emb
  iframe="$(grep -oE '<iframe[^>]*src="[^"]+"' <<< "$1" | head -1 | sed -E 's/.*src="//; s/"$//' || true)"
  if [[ -z "$iframe" ]]; then
    iframe="$(grep -oE 'data-video="[^"]+"' <<< "$1" | head -1 | sed -E 's/^data-video="//; s/"$//' || true)"
  fi
  [[ -z "$iframe" ]] && return 0
  case "$iframe" in //*) iframe="https:$iframe" ;; esac
  emb="$("$_CURL" -sS -L --connect-timeout 20 -A "$_USER_AGENT" -e "$_HOST/$2" --compressed "$iframe" || true)"
  grep -oE 'https?://[^"'"'"' ]+\.m3u8[^"'"'"' ]*' <<< "$emb" | head -1 || true
}

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
      fst="$(head -1 <<< "$eps")"
      lst="$(tail -1 <<< "$eps")"
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
  local num="$1" v slug epage id links chosen q u pl src
  src="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
  v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"
  mkdir -p "$(dirname "$v")"
  if [[ -z "${_LIST_LINK_ONLY:-}" && -s "$v" ]]; then
    print_info "Episode $num already downloaded, skipping."
    return
  fi
  slug="$("$_JQ" -r --arg n "$num" '.[] | select(.episode == ($n|tonumber)) | .slug' "$src")"
  [[ "$slug" == "" ]] && print_warn "Episode $num not found!" && return
  
  # Try both classic and WordPress episode URL formats
  epage="$(get "$_HOST/$slug")"
  if [[ -z "$epage" || "$epage" == *"404 Not Found"* ]]; then
    epage="$(get "$_HOST/$slug-english-subbed")"
  fi
  
  id="$(grep -oE '(download|streaming\.php)\?id=[^"&]+' <<< "$epage" | head -1 | sed -E 's/.*id=//' || true)"
  links=""
  if [[ -n "$id" ]]; then
    links="$(get "$_HOST/download?id=$id" | parse_download_page)"
  fi
  chosen=""
  [[ -n "$links" ]] && chosen="$(pick_quality "$links")"
  
  if [[ -n "$chosen" ]]; then
    q="${chosen%%$_TAB*}"
    u="${chosen#*$_TAB}"
    if [[ -n "${_LIST_LINK_ONLY:-}" ]]; then echo "$u"; return; fi
    print_info "Downloading Episode $num (${q}p) ..."
    "$_CURL" -sS -L -C - --retry 3 -o "$v" \
      -A "$_USER_AGENT" -e "$_HOST/$slug" -H "Accept: */*" "$u" \
      || print_warn "Direct download failed for episode $num."
    [[ -s "$v" ]] || print_warn "Empty file for episode $num; skipped."
  else
    # HLS/iframe fallback (essential for WordPress clones like gogoanime.by)
    pl="$(get_stream_fallback "$epage" "$slug")"
    if [[ -z "$pl" ]]; then
      print_warn "Missing video list! Skip downloading episode $num!"
      return
    fi
    if [[ -n "${_LIST_LINK_ONLY:-}" ]]; then echo "$pl"; return; fi
    [[ -z "$_YTDLP" ]] && print_warn "yt-dlp not installed; cannot use HLS fallback for episode $num." && return
    print_info "Downloading Episode $num via iframe/HLS fallback..."
    "$_YTDLP" "$pl" \
      --add-header "Accept: */*" \
      --extractor-args "generic:impersonate" \
      --impersonate chrome \
      --referer "$_HOST/" \
      --user-agent "$_USER_AGENT" \
      --concurrent-fragments "$_CONCURRENT_FRAGMENTS" \
      --allow-unplayable-formats \
      --fixup force \
      --retries 5 \
      --no-warnings -q --progress -o "$v"
    if command -v ffmpeg > /dev/null && [[ "$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$v" 2>/dev/null)" != "mp4" ]]; then
      print_info "Remuxing Episode $num to MP4..."
      local remux_tmp="$v.remux.mp4"
      if ffmpeg -y -loglevel error -i "$v" -c copy -movflags +faststart "$remux_tmp" 2>/dev/null; then
        mv -f "$remux_tmp" "$v"
      else
        rm -f "$remux_tmp"
        print_warn "Remux to MP4 failed; keeping downloaded file as-is."
      fi
    fi
  fi
}

check_config() {
  if [[ -z "${_HOST:-}" ]]; then
    print_error "Missing host in config.json (expected a \"host\" key, e.g. https://gogoanime.by)."
  fi
}

main() {
  set_args "$@"
  set_var
  check_config
  local res
  if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
    res="$(search_anime_by_name "$_INPUT_ANIME_NAME")"
    [[ -z "$res" ]] && print_error "No search result for '$_INPUT_ANIME_NAME' on $_HOST"
    _ANIME_NAME=$("$_FZF" -1 <<< "$res")
    _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
  else
    if [[ -z "${_ANIME_SLUG:-}" ]]; then
      download_anime_list
      _ANIME_NAME=$("$_FZF" -1 <<< "$(remove_slug < "$_ANIME_LIST_FILE")")
      _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
    fi
  fi
  [[ "${_ANIME_SLUG:-}" == "" ]] && print_error "Anime slug not found!"
  _ANIME_SLUG="$(resolve_audio_slug "$_ANIME_SLUG")"
  _ANIME_NAME="$(grep -F "[$_ANIME_SLUG]" "$_ANIME_LIST_FILE" \
    | tail -1 | remove_slug | sed -E 's/[[:space:]]+$//' || true)"
  if [[ -z "${_ANIME_NAME:-}" ]]; then
    _ANIME_NAME="$(sed -E 's/-/ /g' <<< "$_ANIME_SLUG")"
  fi
  _ANIME_NAME="$(sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g' <<< "$_ANIME_NAME")"
  download_source
  [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
  download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
