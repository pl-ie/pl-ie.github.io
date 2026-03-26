#!/usr/bin/env bash
# MPL PRO v3.1.0 - Media Playlist Player
# Play local audio/video files with playlist management
# Press 'u' during playback to refresh the playlist without losing your position
#
# Usage:
#   mpl                  - open interactive menu in current directory
#   mpl /path/to/dir     - open interactive menu in specified directory
#   mpl -a               - play all files in current directory
#   mpl -a /path         - play all files in specified directory
#   mpl course           - play files matching keyword (e.g. mpl course)
#   mpl *course*         - same with explicit wildcards
#   mpl course /path     - keyword filter in specified directory

termux-wake-lock 2>/dev/null || true

# === COLORS ===
G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; R='\033[0m'
# Kolory dla argumentów mpv (prawdziwy znak ESC)
_MC=$'\033[1;36m'
_MR=$'\033[0m'

# === CONFIG ===
WATCH_LATER_BASE="$HOME/.config/mpv/watch_later"
mkdir -p "$WATCH_LATER_BASE"

PLAYLIST_FILE=$(mktemp)
trap "rm -f '$PLAYLIST_FILE'" EXIT

# === STATE ===
MODE="menu"
DIR="."
FILTER=""
TIME_FILTER=0
TIME_FILTER_MODE=""
ALL_FILES=()
files=()

# === ARGUMENT PARSING ===
if [[ "$1" == "-a" || "$1" == "--all" ]]; then
    MODE="playlist"
    DIR="${2:-.}"
elif [[ "$1" == *\** || "$1" == *\?* ]]; then
    MODE="filter"
    FILTER="$1"
    DIR="${2:-.}"
elif [[ -n "$1" && -d "$1" ]]; then
    DIR="$1"
elif [[ -n "$1" ]]; then
    MODE="filter"
    FILTER="*$1*"
    DIR="${2:-.}"
fi

FULL_DIR=$(realpath "$DIR" 2>/dev/null || echo "$DIR")

# === FUNCTIONS ===

# Raw scan → ALL_FILES
_rescan_files() {
    mapfile -t ALL_FILES < <(find "$FULL_DIR" -maxdepth 1 -type f \( \
        -iname "*.mp3" -o -iname "*.opus" -o -iname "*.ogg" -o \
        -iname "*.flac" -o -iname "*.m4a" -o -iname "*.wav" -o \
        -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o \
        -iname "*.part" \) 2>/dev/null | sort -V)
}

# Apply text filter + time filter → files[]
_apply_filter() {
    local tmp=()

    if [[ -z "$FILTER" ]]; then
        tmp=("${ALL_FILES[@]}")
    else
        local grep_pat
        grep_pat=$(echo "$FILTER" | sed 's/\*/.*/g; s/?/./g')
        for f in "${ALL_FILES[@]}"; do
            local base
            base=$(basename "$f")
            echo "$base" | grep -qi "$grep_pat" && tmp+=("$f")
        done
    fi

    if (( TIME_FILTER > 0 )); then
        local min_secs=$(( TIME_FILTER * 60 ))
        files=()
        local count=0 total=${#tmp[@]}
        for f in "${tmp[@]}"; do
            count=$((count+1))
            printf "\r${C}Scanning: %d/%d  found: %d${R}" "$count" "$total" "${#files[@]}"
            local dur
            dur=$(ffprobe -v quiet \
                -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 \
                "$f" 2>/dev/null)
            if [[ "$dur" =~ ^[0-9] ]]; then
                if [[ "$TIME_FILTER_MODE" == "+" ]]; then
                    awk "BEGIN{exit !($dur >= $min_secs)}" && files+=("$f")
                else
                    awk "BEGIN{exit !($dur <= $min_secs)}" && files+=("$f")
                fi
            fi
        done
        echo
    else
        files=("${tmp[@]}")
    fi

    ((${#files[@]} == 0)) && return 1
    return 0
}

# Rescan + apply filters
_scan_files() {
    _rescan_files
    _apply_filter
}

_filter_active() {
    [[ -n "$FILTER" || $TIME_FILTER -gt 0 ]]
}

# Wait until a .part file reaches minimum buffered size before playing
_wait_for_part() {
    local file="$1"
    [[ "$file" != *.part ]] && return 0

    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    if [[ -z "$size" ]] || (( size < 1048576 )); then
        echo -e "${Y}📥 Buffering .part file...${R}"
        while [[ -z "$size" ]] || (( size < 1048576 )); do
            sleep 1
            size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            printf "\r${M}📊 Downloaded: $((size/1024)) KB${R}"
        done
        echo -e "\n${G}✅ Ready - starting playback${R}"
    fi
}

# Write mpv key bindings to a temp input config
_create_input_conf() {
    local conf="$1"
    cat > "$conf" <<'EOF'
SPACE cycle pause
9 add volume -5
0 add volume +5
, seek -10 relative+keyframes
. seek +10 relative+keyframes
LEFT seek -20 relative+keyframes
RIGHT seek +20 relative+keyframes
UP seek +120 relative+keyframes
DOWN seek -120 relative+keyframes
n playlist-next
b playlist-prev
s cycle-values loop-playlist inf no ; show-text "Loop: ${loop-playlist}"
HOME seek 0 absolute
u quit 42
q quit
ENTER playlist-next
EOF
}

# Print player header with key bindings
_show_header() {
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${C}  MPL PRO v3.1.0 | OFFLINE PLAYER                          ${R}"
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${Y}  9 / 0  : Volume down / up              ${R}"
    echo -e "${Y}  , / .  : Seek -10 / +10 sec            ${R}"
    echo -e "${Y}  ← / →  : Seek -20 / +20 sec            ${R}"
    echo -e "${Y}  ↑ / ↓  : Seek +120 / -120 sec          ${R}"
    echo -e "${Y}  n / b  : Next / Previous               ${R}"
    echo -e "${Y}  SPACE  : Pause | s: Shuffle            ${R}"
    echo -e "${Y}  HOME   : Restart | q: Menu              ${R}"
    echo -e "${Y}  u: Refresh playlist                    ${R}"
    echo -e "${C}____________________________________________________________${R}"
}

# Launch mpv with the current PLAYLIST_FILE starting at given index
_run_mpv() {
    local start_idx="${1:-0}"

    local first_file=$(sed -n "$((start_idx+1))p" "$PLAYLIST_FILE")
    [[ -n "$first_file" ]] && _wait_for_part "$first_file"

    local input_conf=$(mktemp)
    trap "rm -f '$input_conf'" RETURN
    _create_input_conf "$input_conf"

    clear
    _show_header

    mpv \
        --no-video \
        --audio-display=no \
        --no-input-default-bindings \
        --input-ar-delay=1000 \
        --input-ar-rate=1 \
        --volume=60 \
        --playlist="$PLAYLIST_FILE" \
        --playlist-start="$start_idx" \
        --save-position-on-quit \
        --resume-playback \
        --watch-later-directory="$WATCH_LATER_BASE" \
        --watch-later-options-remove=pause \
        --input-conf="$input_conf" \
        --term-status-msg='[${playlist-pos-1}/${playlist-count}] ${time-pos}/${duration} | V:${volume}%' \
        --term-playing-msg="${_MC}▶ [\${playlist-pos-1}/\${playlist-count}] \${filename}${_MR}"

    return $?
}

_play_with_refresh() {
    local start_idx="${1:-0}"

    while true; do
        printf "%s\n" "${files[@]}" > "$PLAYLIST_FILE"
        local count_before=${#files[@]}

        _run_mpv "$start_idx"
        local exit_code=$?

        if [[ $exit_code -eq 42 ]]; then
            echo -e "\n${G}🔄 Refreshing playlist...${R}"

            local current_file="${files[$start_idx]}"
            local old_count=$count_before

            if _scan_files; then
                local new_count=${#files[@]}
                local added=$((new_count - old_count))
                [[ $added -lt 0 ]] && added=0
                echo -e "${G}✅ Files: ${old_count} -> ${new_count} (+${added} new)${R}"
            else
                echo -e "${Y}❌ No files found - returning to menu${R}"
                sleep 1
                return 1
            fi

            local new_idx=0
            if [[ -n "$current_file" ]]; then
                for i in "${!files[@]}"; do
                    if [[ "${files[$i]}" == "$current_file" ]]; then
                        new_idx=$i; break
                    fi
                done
            fi

            echo -e "${M}📍 Resuming: [track $((new_idx+1))/${#files[@]}] - position restored from watch_later${R}"
            sleep 1
            start_idx=$new_idx
            continue
        else
            return 0
        fi
    done
}

# === DRAW MENU ===
_draw_menu() {
    clear
    echo -e "${C}============================================================${R}"
    local header="${FULL_DIR}"
    [[ -n "$FILTER" ]] && header+=" ${Y}[filter: ${FILTER}]${C}"
    (( TIME_FILTER > 0 )) && header+=" ${M}[time: ${TIME_FILTER_MODE}${TIME_FILTER}min]${C}"
    echo -e "${C}  ${header}${R}"
    echo -e "${C}============================================================${R}"

    for i in "${!files[@]}"; do
        local fname
        fname=$(basename "${files[$i]}" | cut -c1-56)
        [[ "$fname" == *.part ]] && fname="📥 $fname"
        printf " %3d) %s\n" "$((i+1))" "$fname"
    done

    echo -e "${C}============================================================${R}"
    echo -e "${Y}  a = play all${R} | ${Y}s = shuffle${R}"
    echo -e "${Y}  u = refresh${R}  | ${Y}t = time filter${R}"
    echo -e "${Y}  / = search${R}   | ${Y}q = quit${R}"
    echo -ne "  Choice: "
}

# === TIME FILTER HANDLER ===
_handle_time_filter() {
    echo -e "\r\033[K"
    echo -ne "${G}Duration filter (+min or -min, 0=off): ${R}"
    read -r tmin
    tmin=$(echo "$tmin" | tr -d ' ')
    if [[ "$tmin" == "0" ]]; then
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        _apply_filter
        echo -e "${G}✅ Time filter cleared${R}"; sleep 0.5
    elif [[ "$tmin" =~ ^[+-][0-9]+$ ]]; then
        TIME_FILTER=${tmin:1}
        TIME_FILTER_MODE=${tmin:0:1}
        if ! _apply_filter; then
            echo -e "${Y}❌ No files matching duration filter${R}"
            TIME_FILTER=0
            TIME_FILTER_MODE=""
            _apply_filter
            sleep 1
        else
            echo -e "${G}✅ Found ${#files[@]} files${R}"; sleep 0.5
        fi
    fi
}

# === STARTUP ===
_scan_files || { echo -e "${Y}❌ No media files found in: $FULL_DIR${R}"; exit 1; }

if [[ "$MODE" == "playlist" ]]; then
    _play_with_refresh 0
    exit 0
fi

if [[ "$MODE" == "filter" ]]; then
    echo -e "${C}🔍 Filter: ${Y}${FILTER}${C} — found ${G}${#files[@]}${C} files${R}"
    sleep 0.5
fi

# === MAIN MENU LOOP ===
while :; do
    _draw_menu

    read -s -r -n 1 key

    case "$key" in
        a|A)
            _play_with_refresh 0
            _scan_files
            ;;
        s|S)
            mapfile -t files < <(printf "%s\n" "${files[@]}" | shuf)
            _play_with_refresh 0
            _scan_files
            ;;
        u|U)
            echo -e "\n${G}🔄 Refreshing file list...${R}"
            if _scan_files; then
                echo -e "${G}✅ Found ${#files[@]} files${R}"
                sleep 0.5
            else
                echo -e "${Y}❌ No files found in directory${R}"
                sleep 1
            fi
            ;;
        t|T)
            _handle_time_filter
            ;;
        q|Q)
            clear; exit 0
            ;;
        /)
            echo -e "\r\033[K"
            echo -ne "${G}Search: ${R}"
            read -r keyword
            if [[ -n "$keyword" ]]; then
                FILTER="*${keyword}*"
                if ! _apply_filter; then
                    echo -e "${Y}❌ No files matching: ${keyword}${R}"
                    FILTER=""
                    _apply_filter 2>/dev/null
                    sleep 1
                fi
            else
                FILTER=""
                _apply_filter 2>/dev/null
            fi
            ;;
        [0-9])
            echo -ne "\r\033[K"
            read -e -r -p "$(echo -e "${G}Choice:${R} ")" -i "$key" input_cmd
            input_cmd=$(echo "$input_cmd" | tr -cd '0-9')
            if [[ -n "$input_cmd" ]]; then
                idx=$((input_cmd - 1))
                if [[ -n "${files[$idx]}" ]]; then
                    _play_with_refresh "$idx"
                    _scan_files
                fi
            fi
            ;;
    esac
done
