#!/usr/bin/env bash
# MPL PRO v3.0.0 - Media Playlist Player
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

# === CONFIG ===
WATCH_LATER_BASE="$HOME/.config/mpv/watch_later"
mkdir -p "$WATCH_LATER_BASE"

# Global playlist file - shared between functions
PLAYLIST_FILE=$(mktemp)
trap "rm -f '$PLAYLIST_FILE'" EXIT

# === ARGUMENT PARSING ===
MODE="menu"
DIR="."
FILTER=""

if [[ "$1" == "-a" || "$1" == "--all" ]]; then
    MODE="playlist"
    DIR="${2:-.}"
elif [[ "$1" == *\** || "$1" == *\?* ]]; then
    # Wildcard pattern like *course* - filter mode
    MODE="filter"
    FILTER="$1"
    DIR="${2:-.}"
elif [[ -n "$1" && -d "$1" ]]; then
    # Existing directory - open menu there
    DIR="$1"
elif [[ -n "$1" ]]; then
    # Plain word - treat as keyword filter (e.g. mpl course)
    MODE="filter"
    FILTER="*$1*"
    DIR="${2:-.}"
fi

FULL_DIR=$(realpath "$DIR" 2>/dev/null || echo "$DIR")

# === FUNCTIONS ===

# Scan directory for supported media files
# If FILTER is set, only include files matching the pattern (case-insensitive)
_scan_files() {
    mapfile -t all_files < <(find "$FULL_DIR" -maxdepth 1 -type f \( \
        -iname "*.mp3" -o -iname "*.opus" -o -iname "*.ogg" -o \
        -iname "*.flac" -o -iname "*.m4a" -o -iname "*.wav" -o \
        -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o \
        -iname "*.part" \) 2>/dev/null | sort -V)

    if [[ -n "$FILTER" ]]; then
        # Convert wildcard pattern to case-insensitive grep pattern
        local grep_pat=$(echo "$FILTER" | sed 's/\*/.*/g; s/?/./g')
        files=()
        for f in "${all_files[@]}"; do
            local base=$(basename "$f")
            if echo "$base" | grep -qi "$grep_pat"; then
                files+=("$f")
            fi
        done
    else
        files=("${all_files[@]}")
    fi

    ((${#files[@]} == 0)) && return 1
    return 0
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
# Exit code 42 = refresh signal (triggered by 'u' key)
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
r seek 0 absolute
u quit 42
q quit
ENTER playlist-next
EOF
}

# Print player header with key bindings
_show_header() {
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${C}  MPL PRO v3.0.0 | OFFLINE PLAYER                          ${R}"
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${Y}  9 / 0  : Volume down / up              ${R}"
    echo -e "${Y}  , / .  : Seek -10 / +10 sec            ${R}"
    echo -e "${Y}  ← / →  : Seek -20 / +20 sec            ${R}"
    echo -e "${Y}  ↑ / ↓  : Seek +120 / -120 sec          ${R}"
    echo -e "${Y}  n / b  : Next / Previous               ${R}"
    echo -e "${Y}  SPACE  : Pause | s: Shuffle            ${R}"
    echo -e "${Y}  r: Restart | q: Menu                   ${R}"
    echo -e "${Y}  u: Refresh playlist                    ${R}"
    echo -e "${C}____________________________________________________________${R}"
}

# Launch mpv with the current PLAYLIST_FILE starting at given index
_run_mpv() {
    local start_idx="${1:-0}"

    # Wait for .part file to buffer if needed
    local first_file=$(sed -n "$((start_idx+1))p" "$PLAYLIST_FILE")
    [[ -n "$first_file" ]] && _wait_for_part "$first_file"

    local input_conf=$(mktemp)
    trap "rm -f '$input_conf'" RETURN
    _create_input_conf "$input_conf"

    local watch_dir="$WATCH_LATER_BASE"

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
        --watch-later-directory="$watch_dir" \
        --watch-later-options-remove=pause \
        --input-conf="$input_conf" \
        --term-status-msg='[${playlist-pos-1}/${playlist-count}] ${time-pos}/${duration} | V:${volume}%' \
        --term-playing-msg='▶ [${playlist-pos-1}/${playlist-count}] ${filename}'

    return $?
}

# Main playback loop with live playlist refresh support
#
# How 'u' refresh works:
#   1. User presses 'u' -> mpv exits with code 42
#   2. We remember which file was playing (by index in old list)
#   3. Rescan the directory for new/removed files
#   4. Find the same file in the updated list -> restore index
#   5. Restart mpv - it auto-resumes position from watch_later
_play_with_refresh() {
    local start_idx="${1:-0}"

    while true; do
        # Write current file list to playlist
        printf "%s\n" "${files[@]}" > "$PLAYLIST_FILE"
        local count_before=${#files[@]}

        # Start playback
        _run_mpv "$start_idx"
        local exit_code=$?

        if [[ $exit_code -eq 42 ]]; then
            # 'u' was pressed - refresh playlist
            echo -e "\n${G}🔄 Refreshing playlist...${R}"

            # Remember which file was active before refresh
            local current_file="${files[$start_idx]}"

            # Rescan directory
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

            # Find the previously playing file in the updated list
            local new_idx=0
            if [[ -n "$current_file" ]]; then
                for i in "${!files[@]}"; do
                    if [[ "${files[$i]}" == "$current_file" ]]; then
                        new_idx=$i
                        break
                    fi
                done
            fi

            echo -e "${M}📍 Resuming: [track $((new_idx+1))/${#files[@]}] - position restored from watch_later${R}"
            sleep 1

            start_idx=$new_idx
            # Loop continues - mpv will resume exact position automatically
            continue
        else
            # Normal exit: 'q' pressed or playlist finished
            return 0
        fi
    done
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
    # Drop into menu so user can browse the filtered list
fi

# === MAIN MENU ===
while :; do
    clear
    echo -e "${C}============================================================${R}"
    if [[ -n "$FILTER" ]]; then
        echo -e "${C}  FILE LIST: ${FULL_DIR} ${Y}[filter: ${FILTER}]${R}"
    else
        echo -e "${C}  FILE LIST: ${FULL_DIR}${R}"
    fi
    echo -e "${C}============================================================${R}"

    for i in "${!files[@]}"; do
        fname=$(basename "${files[$i]}" | cut -c1-56)
        [[ "$fname" == *.part ]] && fname="📥 $fname"
        printf " %3d) %s\n" "$((i+1))" "$fname"
    done

    echo -e "${C}============================================================${R}"
    echo -e "${Y}  a = play all | s = shuffle | u = refresh | q = quit${R}"
    echo -e "${Y}  / = search | number + ENTER = play${R}"
    echo -ne "  Choice: "

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
        q|Q)
            clear; exit 0
            ;;
        /)
            echo -e "\r\033[K"
            echo -ne "${G}Search: ${R}"
            read -r keyword
            if [[ -n "$keyword" ]]; then
                FILTER="*${keyword}*"
                if ! _scan_files; then
                    echo -e "${Y}❌ No files matching: ${keyword}${R}"
                    FILTER=""
                    _scan_files 2>/dev/null
                    sleep 1
                fi
            else
                FILTER=""
                _scan_files 2>/dev/null
            fi
            ;;
        [0-9])
            echo -n "$key"
            read -r rest
            input_cmd="${key}${rest}"
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
