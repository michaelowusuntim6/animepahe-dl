#!/usr/bin/env bash
#
# Download anime from animepahe in terminal
#
#/ Usage:
#/   ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-l] [-d]
#/
#/ Options:
#/   -a <name>               anime name
#/   -s <slug>               anime slug/uuid, can be found in $_ANIME_LIST_FILE
#/                           ignored when "-a" is enabled
#/   -e <num1,num3-num4...>  optional, episode number to download
#/                           multiple episode numbers seperated by ","
#/                           episode range using "-"
#/                           all episodes using "*"
#/   -r <resolution>         optional, specify resolution: "1080", "720"...
#/                           by default, the highest resolution is selected
#/   -o <language>           optional, specify audio language: "eng", "jpn"...
#/   -l                      optional, show m3u8 playlist link without downloading videos
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
    _YTDLP="$(command -v yt-dlp)" || command_not_found "yt-dlp"
    _PYTHON="$(command -v python3.11)" || command_not_found "python3.11"

    _HOST="https://animepahe.pw"
    _ANIME_URL="$_HOST/anime"
    _API_URL="$_HOST/api"
    _REFERER_URL="https://kwik.cx/"
    _REFERER_HOST="https://animepahe.pw/"

    _SCRIPT_PATH=$(dirname "$(realpath "$0")")
    _USER_AGENT="$("$_JQ" -r '.ua' "$_SCRIPT_PATH/config.json")"
    _CF_CLEARANCE="$("$_JQ" -r '.cf' "$_SCRIPT_PATH/config.json")"
    _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
    _SOURCE_FILE=".source.json"

    # --- Termux download directory ---
    _DOWNLOAD_DIR="$HOME/storage/downloads/Anime"
    mkdir -p "$_DOWNLOAD_DIR"

    # --- Concurrent fragments for yt-dlp (default 32) ---
    _CONCURRENT_FRAGMENTS="${_CONCURRENT_FRAGMENTS:-32}"
}

set_args() {
    expr "$*" : ".*--help" > /dev/null && usage
    _DEFAULT_ANIME_RESOLUTION="720"
    while getopts ":hlda:s:e:r:o:" opt; do
        case $opt in
            a)
                _INPUT_ANIME_NAME="$OPTARG"
                ;;
            s)
                _ANIME_SLUG="$OPTARG"
                ;;
            e)
                _ANIME_EPISODE="$OPTARG"
                ;;
            l)
                _LIST_LINK_ONLY=true
                ;;
            r)
                _ANIME_RESOLUTION="$OPTARG"
                ;;
            o)
                _ANIME_AUDIO="$OPTARG"
                ;;
            d)
                set -x
                ;;
            h)
                usage
                ;;
            \?)
                print_error "Invalid option: -$OPTARG"
                ;;
        esac
    done
}

print_info() {
    # $1: info message
    [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[32m[INFO]\033[0m $1" >&2
}

print_warn() {
    # $1: warning message
    [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[33m[WARNING]\033[0m $1" >&2
}

print_error() {
    # $1: error message
    printf "%b\n" "\033[31m[ERROR]\033[0m $1" >&2
    exit 1
}

command_not_found() {
    # $1: command name
    print_error "$1 command not found!"
}

get() {
    # $1: url
    "$_CURL" -sS -L "$1" -b "cf_clearance=$_CF_CLEARANCE" -A "$_USER_AGENT" --compressed
}

download_anime_list() {
    get "$_ANIME_URL" \
    | grep "/anime/" \
    | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' \
    > "$_ANIME_LIST_FILE"
}

search_anime_by_name() {
    # $1: anime name
    local d n
    d="$(get "$_HOST/api?m=search&q=${1// /%20}")"
    n="$("$_JQ" -r '.total' <<< "$d" 2>/dev/null)"
    [[ -z "${n:-}" ]] && print_error "No search result... Need a new cf value in config.json"
    if [[ "$n" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d" \
            | tee -a "$_ANIME_LIST_FILE" \
            | remove_slug
    fi
}

get_episode_list() {
    # $1: anime id
    # $2: page number
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"
}

download_source() {
    local d p n
    local anime_dir="$_SCRIPT_PATH/$_ANIME_NAME"
    mkdir -p "$anime_dir"
    d="$(get_episode_list "$_ANIME_SLUG" "1")"

    # Validate that the response is valid JSON
    if ! echo "$d" | "$_JQ" . >/dev/null 2>&1; then
        print_error "Invalid API response (likely expired cookie). Run ./refresh_cookie.sh and try again."
    fi

    p="$("$_JQ" -r '.last_page' <<< "$d" 2>/dev/null)"
    [[ -z "${p:-}" ]] && print_error "No search result... Need a new cf value in config.json"

    if [[ "$p" -gt "1" ]]; then
        for i in $(seq 2 "$p"); do
            n="$(get_episode_list "$_ANIME_SLUG" "$i")"
            d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
        done
    fi

    # Final validation before writing
    if ! echo "$d" | "$_JQ" . >/dev/null 2>&1; then
        print_error "Merged data is not valid JSON. Possibly a network issue or cookie expired."
    fi

    # Write and strip UTF-8 BOM
    printf '%s' "$d" > "$anime_dir/$_SOURCE_FILE"
    sed -i '1s/^\xEF\xBB\xBF//' "$anime_dir/$_SOURCE_FILE"

    # Final sanity check: make sure the file on disk is valid JSON
    if ! "$_JQ" . "$anime_dir/$_SOURCE_FILE" >/dev/null 2>&1; then
        print_error "Wrote invalid JSON to $anime_dir/$_SOURCE_FILE. Run ./refresh_cookie.sh and try again."
    fi
}

get_episode_link() {
    # $1: episode number
    local s o l r=""
    local source_path="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" "$source_path")
    [[ "$s" == "" ]] && print_warn "Episode $1 not found!" && return
    o="$(get "${_HOST}/play/${_ANIME_SLUG}/${s}")"
    l="$(grep \<button <<< "$o" \
        | grep data-src \
        | sed -E 's/data-src="/\n/g' \
        | grep 'data-av1="0"')"

    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        print_info "Select audio language: $_ANIME_AUDIO"
        r="$(grep 'data-audio="'"$_ANIME_AUDIO"'"' <<< "$l")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected audio language is not available, fallback to default."
        fi
    fi

    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "Select video resolution: ${_ANIME_RESOLUTION}p"
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "${r:-$l}")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected video resolution is not available, fallback to default ${_DEFAULT_ANIME_RESOLUTION}p."
        fi
    fi

    if [[ -z "${r:-}" ]]; then
        grep kwik <<< "$l" | grep kwik | grep "$_DEFAULT_ANIME_RESOLUTION" | awk -F '"' '{print $1}'
    else
        awk -F '" ' '{print $1}' <<< "$r"
    fi
}

unpack_js_code() {
    # $1: raw packed eval(...) code from the kwik player page
    # Decodes the p.a.c.k.e.r obfuscation locally (no external JS runner needed)
    "$_PYTHON" - "$1" <<'PY'
import re
import sys


def b36(d):
    return chr(48 + d) if d < 10 else chr(87 + d)


def unpack_one(p, a, c, k):
    a, c = int(a), int(c)

    def e(i):
        first = "" if i < a else e(i // a)
        d = i % a
        return first + (chr(d + 29) if d > 35 else b36(d))

    while c:
        c -= 1
        if k[c]:
            p = re.sub(r"\b" + re.escape(e(c)) + r"\b", lambda m: k[c], p)
    return p


PAT = re.compile(
    r"eval\(function\(p,a,c,k,e,d\)\{.*?\}\('"
    r"((?:[^'\\]|\\.)*)',(\d+),(\d+),'((?:[^'\\]|\\.)*)'\.split\('\|'\),0,\{\}\)\)",
    re.S,
)

src = sys.argv[1]
out = src
for _ in range(10):
    found = False
    for m in PAT.finditer(out):
        found = True
        p = m.group(1).replace("\\'", "'").replace("\\\\", "\\")
        k = m.group(4).replace("\\'", "'").replace("\\\\", "\\")
        try:
            dec = unpack_one(p, m.group(2), m.group(3), k.split("|"))
        except Exception:
            continue
        out = out.replace(m.group(0), dec)
    if not found:
        break

sys.stdout.write(out)
PY
}

get_playlist_link() {
    # $1: episode link
    local s l t
    while read -r t; do
        s="$("$_CURL" --compressed -sS -H "Referer: $_REFERER_HOST" "$t" \
            | grep "<script>eval" \
            | awk -F 'script>' '{print $2}')"

        l="$(unpack_js_code "$s" \
            | grep 'source=' \
            | sed 's/.m3u8.*/.m3u8/' \
            | sed 's/.*https/https/')"

        if [[ -n "${l:-}" ]]; then
            echo "$l"
            return
        fi
    done <<< "$1"
}

download_episodes() {
    # $1: episode number string
    local origel el uniqel
    origel=()
    if [[ "$1" == *","* ]]; then
        IFS="," read -ra ADDR <<< "$1"
        for n in "${ADDR[@]}"; do
            origel+=("$n")
        done
    else
        origel+=("$1")
    fi

    el=()
    for i in "${origel[@]}"; do
        if [[ "$i" == *"*"* ]]; then
            local eps fst lst
            local source_path="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
            eps="$("$_JQ" -r '.data[].episode' "$source_path" | sort -nu)"
            fst="$(head -1 <<< "$eps")"
            lst="$(tail -1 <<< "$eps")"
            i="${fst}-${lst}"
        fi

        if [[ "$i" == *"-"* ]]; then
            s=$(awk -F '-' '{print $1}' <<< "$i")
            e=$(awk -F '-' '{print $2}' <<< "$i")
            for n in $(seq "$s" "$e"); do
                el+=("$n")
            done
        else
            el+=("$i")
        fi
    done

    IFS=" " read -ra uniqel <<< "$(printf '%s\n' "${el[@]}" | sort -n -u | tr '\n' ' ')"

    [[ ${#uniqel[@]} == 0 ]] && print_error "Wrong episode number!"

    for e in "${uniqel[@]}"; do
        download_episode "$e"
    done
}

download_episode() {
    # $1: episode number
    local num="$1" l pl v
    v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"
    mkdir -p "$(dirname "$v")"   # ensures the anime folder exists

    l=$(get_episode_link "$num")
    [[ "$l" != *"/"* ]] && print_warn "Wrong download link or episode $1 not found!" && return

    pl=$(get_playlist_link "$l")
    [[ -z "${pl:-}" ]] && print_warn "Missing video list! Skip downloading!" && return

    if [[ -z ${_LIST_LINK_ONLY:-} ]]; then
        print_info "Downloading Episode $1..."

        # Write cookie to a temporary file
        COOKIE_FILE=$(mktemp)
        trap 'rm -f "$COOKIE_FILE"' EXIT
        printf "# Netscape HTTP Cookie File\n.animepahe.pw\tTRUE\t/\tFALSE\t0\tcf_clearance\t%s\n" "$_CF_CLEARANCE" > "$COOKIE_FILE"

        # Download with full headers, impersonation, and native decryption (no ffmpeg during download)
        "$_YTDLP" "$pl" \
            --cookies "$COOKIE_FILE" \
            --add-header "Cookie: cf_clearance=$_CF_CLEARANCE" \
            --add-header "Origin: https://kwik.cx/" \
            --add-header "Accept: */*" \
            --extractor-args "generic:impersonate" \
            --impersonate chrome \
            --referer "$_REFERER_URL" \
            --user-agent "$_USER_AGENT" \
            --concurrent-fragments "$_CONCURRENT_FRAGMENTS" \
            --allow-unplayable-formats \
            --fixup force \
            --retries 5 \
            --no-warnings -q --progress -o "$v"

        rm -f "$COOKIE_FILE"

        # Remux to MP4 locally (this ffmpeg call is safe, as all fragments are on disk)
        if command -v ffmpeg > /dev/null && [[ "$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$v" 2>/dev/null)" != "mp4" ]]; then
            print_info "Remuxing Episode $1 to MP4..."
            local remux_tmp="$v.remux.mp4"
            if ffmpeg -y -loglevel error -i "$v" -c copy -movflags +faststart "$remux_tmp" 2>/dev/null; then
                mv -f "$remux_tmp" "$v"
            else
                rm -f "$remux_tmp"
                print_warn "Remux to MP4 failed; keeping downloaded file as-is."
            fi
        fi
    else
        echo "$pl"
    fi
}

select_episodes_to_download() {
    local source_path="$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    [[ ! -f "$source_path" ]] && print_error "Episode list file missing: $source_path"
    [[ "$(grep 'data' -c "$source_path")" -eq "0" ]] && print_error "No episode available!"
    "$_JQ" -r '.data[] | "[\(.episode | tonumber)] E\(.episode | tonumber) \(.created_at)"' "$source_path" >&2
    echo -n "Which episode(s) to download: " >&2
    read -r s
    echo "$s"
}

remove_brackets() {
    awk -F']' '{print $1}' | sed -E 's/^\[//'
}

remove_slug() {
    awk '{$1="";print}' | awk '{$1=$1;print}'
}

get_slug_from_name() {
    # $1: anime name
    # Match the title exactly: anime.list entries are "[slug] Title   ".
    # A plain substring match would wrongly resolve "Dies irae" to
    # "Dies irae: The Dawning Days" (tail -1 wins).
    grep -F "] $1   " "$_ANIME_LIST_FILE" | tail -1 | remove_brackets
}

check_config() {
    if [[ -z "${_CF_CLEARANCE:-}" ]] || [[ "$_CF_CLEARANCE" == "null" ]] || [[ "$_CF_CLEARANCE" == "" ]]; then
        print_error "Missing or invalid cf_clearance in config.json. Run ./refresh_cookie.sh to update."
    fi
    if [[ -z "${_USER_AGENT:-}" ]] || [[ "$_USER_AGENT" == "null" ]] || [[ "$_USER_AGENT" == "" ]]; then
        print_error "Missing or invalid user-agent in config.json. Run ./refresh_cookie.sh to update."
    fi
}

main() {
    set_args "$@"
    set_var
    check_config

    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        _ANIME_NAME=$("$_FZF" -1 <<< "$(search_anime_by_name "$_INPUT_ANIME_NAME")")
        _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
    else
        download_anime_list
        if [[ -z "${_ANIME_SLUG:-}" ]]; then
            _ANIME_NAME=$("$_FZF" -1 <<< "$(remove_slug < "$_ANIME_LIST_FILE")")
            _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
        fi
    fi

    [[ "$_ANIME_SLUG" == "" ]] && print_error "Anime slug not found!"
    _ANIME_NAME="$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" \
        | tail -1 \
        | remove_slug \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"

    if [[ "$_ANIME_NAME" == "" ]]; then
        print_warn "Anime name not found! Try again."
        download_anime_list
        exit 1
    fi

    download_source

    [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
    download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
