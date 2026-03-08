#!/usr/bin/env bash
# MT - Media Terminal Player v1.1.0
# A lightweight terminal media player with paginated file browser.
# Plays local audio/video files using mpv with resume support.
#
# Requirements: mpv, ffprobe (ffmpeg), termux-wake-lock (optional, Termux only)
#
# Usage:
#   mt               - open browser in current directory
#   mt /path/to/dir  - open browser in specified directory
#   mt kurs          - open browser with filter "kurs"
#   mt *kurs*        - same with explicit wildcards
#   mt kurs /path    - filter in specified directory
#
# Controls (browser):
#   [number] + ENTER - play file by number
#   PgUp / PgDn      - scroll pages
#   a                - play all (filter/time-filter mode)
#   u                - refresh file list
#   t                - time filter
#   /                - search
#   q                - clear filters / quit

termux-wake-lock 2>/dev/null || true

# === COLORS ===
G='\033[1;32m'
Y='\033[1;33m'
C='\033[1;36m'
R='\033[0m'

# === CONFIG ===
WATCH_LATER_BASE="$HOME/.config/mpv/watch_later"
mkdir -p "$WATCH_LATER_BASE/session"

PLAYLIST_FILE="$HOME/.mt_current_playlist.m3u"
DURATION_CACHE=$(mktemp)
INPUT_CONF=$(mktemp)
CURRENT_PAGE=0
LAST_H=0
LAST_W=0
FILTER=""
TIME_FILTER=0
TIME_FILTER_MODE=""

trap "rm -f '$DURATION_CACHE' '$INPUT_CONF'" EXIT

# === KEY BINDINGS ===
_create_input_conf() {
    cat > "$INPUT_CONF" <<'EOF'
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
s cycle-values loop-playlist inf no
u quit 42
q quit 43
ENTER playlist-next
EOF
}

# === HELPER: czy aktywny jakikolwiek filtr ===
_filter_active() {
    [[ -n "$FILTER" || $TIME_FILTER -gt 0 ]]
}

# === WAIT FOR PART FILE ===
_wait_for_part() {
    local file="$1"
    [[ "$file" != *.part ]] && return 0
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    if [[ -z "$size" ]] || (( size < 1048576 )); then
        echo -e "${Y}Buffering .part file...${R}"
        while [[ -z "$size" ]] || (( size < 1048576 )); do
            sleep 1
            size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            printf "\r${C}Downloaded: $((size/1024)) KB${R}"
        done
        echo -e "\n${G}Ready - starting playback${R}"
    fi
}

# === APPLY FILTER (text + time) → DISPLAY_FILES ===
_apply_filter() {
    local tmp_files=()

    if [[ -z "$FILTER" ]]; then
        tmp_files=("${ALL_FILES[@]}")
    else
        local grep_pat
        grep_pat=$(echo "$FILTER" | sed 's/\*/.*/g; s/?/./g')
        for f in "${ALL_FILES[@]}"; do
            local base
            base=$(basename "$f")
            echo "$base" | grep -qi "$grep_pat" && tmp_files+=("$f")
        done
    fi

    if (( TIME_FILTER > 0 )); then
        local min_secs=$(( TIME_FILTER * 60 ))
        DISPLAY_FILES=()
        for f in "${tmp_files[@]}"; do
            local dur
            dur=$(ffprobe -v quiet \
                -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 \
                "$f" 2>/dev/null)
            if [[ "$dur" =~ ^[0-9] ]]; then
                if [[ "$TIME_FILTER_MODE" == "+" ]]; then
                    awk "BEGIN{exit !($dur >= $min_secs)}" && DISPLAY_FILES+=("$f")
                else
                    awk "BEGIN{exit !($dur <= $min_secs)}" && DISPLAY_FILES+=("$f")
                fi
            fi
        done
    else
        DISPLAY_FILES=("${tmp_files[@]}")
    fi

    CURRENT_PAGE=0
}

# === RESCAN DIRECTORY → ALL_FILES ===
_rescan_files() {
    mapfile -t ALL_FILES < <(
        find "$FULL_DIR" -maxdepth 1 -type f \( \
            -iname "*.mp3"  -o -iname "*.opus" -o -iname "*.ogg"  -o \
            -iname "*.flac" -o -iname "*.m4a"  -o -iname "*.wav"  -o \
            -iname "*.mp4"  -o -iname "*.webm" -o -iname "*.mkv"  -o \
            -iname "*.part" \
        \) 2>/dev/null | sort -V
    )
}

# === BACKGROUND DURATION CALC ===
_calc_duration() {
    (
        local total=0 count=0
        local total_files=${#ALL_FILES[@]}
        for f in "${ALL_FILES[@]}"; do
            [[ "$f" == *.part ]] && { count=$((count+1)); continue; }
            local dur
            dur=$(ffprobe -v quiet \
                -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 \
                "$f" 2>/dev/null)
            [[ "$dur" =~ ^[0-9]+ ]] && \
                total=$(awk "BEGIN{printf \"%d\", $total + $dur}")
            count=$((count+1))
            if (( count % 5 == 0 || count == total_files )); then
                printf "%02d:%02d:%02d (%d/%d)" \
                    $((total/3600)) $(((total%3600)/60)) $((total%60)) \
                    "$count" "$total_files" > "$DURATION_CACHE"
            fi
        done
    ) &
}

# === DRAW BROWSER ===
_draw_browser() {
    local term_h term_w
    term_h=$(tput lines)
    term_w=$(tput cols)
    if [[ "$term_h" != "$LAST_H" || "$term_w" != "$LAST_W" ]]; then
        clear; LAST_H=$term_h; LAST_W=$term_w
    fi

    local max_rows=$(( term_h - 3 ))
    (( max_rows < 1 )) && max_rows=1

    local total_files=${#DISPLAY_FILES[@]}
    local total_pages=$(( (total_files + max_rows - 1) / max_rows ))
    (( total_pages < 1 )) && total_pages=1
    (( CURRENT_PAGE >= total_pages )) && CURRENT_PAGE=$(( total_pages - 1 ))

    local start_idx=$(( CURRENT_PAGE * max_rows ))
    local dur_val
    dur_val=$(cat "$DURATION_CACHE" 2>/dev/null)
    [[ -z "$dur_val" ]] && dur_val="Calculating..."

    printf "\033[H\033[J"

    for (( i = 0; i < max_rows; i++ )); do
        local idx=$(( start_idx + i ))
        (( idx >= total_files )) && break
        local file_path="${DISPLAY_FILES[$idx]}"
        local display_num

        if _filter_active; then
            display_num=$(( idx + 1 ))
        else
            display_num=0
            for j in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$j]}" == "$file_path" ]] && {
                    display_num=$(( j + 1 )); break
                }
            done
        fi

        local name
        name=$(basename "$file_path" | cut -c1-56)
        printf "${G}%3d)${R} %s\n" "$display_num" "$name"
    done

    local footer_info=""
    [[ -n "$FILTER" ]] && footer_info=" | ${C}Filter: ${FILTER}${R}"
    (( TIME_FILTER > 0 )) && \
        footer_info+=" | ${C}Time: ${TIME_FILTER_MODE}${TIME_FILTER}min (${#DISPLAY_FILES[@]} files)${R}"

    if _filter_active; then
        echo -e "${Y}a: play all${R} | ${Y}u: refresh${R} | ${Y}t: time filter${R} | ${Y}q: clear filters${R} | ${Y}/: search${R}${footer_info}"
    else
        echo -e "${Y}PgUp/PgDn${R} | ${Y}u: refresh${R} | ${Y}t: time filter${R} | ${Y}q: quit${R} | ${Y}/: search${R}\n${C}Total: ${dur_val}${R}"
    fi
    echo -ne "${Y}Page: $((CURRENT_PAGE+1))/$total_pages${R} | ${G}Choice:${R} "
}

# === PLAYBACK HEADER ===
_show_playback_header() {
    clear
    echo -e "${C}____________________________________________________________${R}"
    echo -e "\n${Y}  9 / 0  : Volume down / up${R}"
    echo -e "\n${Y}  , / .  : Seek -10 / +10 sec${R}"
    echo -e "\n${Y}  ← / →  : Seek -20 / +20 sec${R}"
    echo -e "\n${Y}  ↑ / ↓  : Seek +120 / -120 sec${R}"
    echo -e "\n${Y}  n / b  : Next / Previous${R}"
    echo -e "\n${Y}  SPACE  : Pause | s: Loop${R}"
    echo -e "\n${Y}  u: Refresh playlist  |  q: Menu${R}"
    echo -e "\n${C}____________________________________________________________${R}"
}

# === RUN MPV ===
_run_mpv() {
    local all_idx="$1"

    local play_list=()
    if _filter_active; then
        play_list=("${DISPLAY_FILES[@]}")
    else
        play_list=("${ALL_FILES[@]}")
    fi

    true > "$PLAYLIST_FILE"
    for f in "${play_list[@]}"; do
        echo "$f" >> "$PLAYLIST_FILE"
    done

    local start_idx=0
    local target="${ALL_FILES[$all_idx]}"
    for i in "${!play_list[@]}"; do
        [[ "${play_list[$i]}" == "$target" ]] && { start_idx=$i; break; }
    done

    _show_playback_header

    local first_file
    first_file=$(sed -n "$((start_idx+1))p" "$PLAYLIST_FILE")
    [[ -n "$first_file" ]] && _wait_for_part "$first_file"

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
        --input-conf="$INPUT_CONF" \
        --term-status-msg='[${playlist-pos-1}/${playlist-count}] ${time-pos}/${duration} | V:${volume}%' \
        --term-playing-msg='▶ [${playlist-pos-1}/${playlist-count}] ${filename}'

    return $?
}

# === PLAY WITH REFRESH ===
_play_with_refresh() {
    local all_start_idx="$1"

    while true; do
        _run_mpv "$all_start_idx"
        local exit_code=$?

        if [[ $exit_code -eq 42 ]]; then
            echo -e "\n${G}Refreshing playlist...${R}"
            local current_file="${ALL_FILES[$all_start_idx]}"

            _rescan_files
            _apply_filter

            echo -e "${G}Found ${#ALL_FILES[@]} files (${#DISPLAY_FILES[@]} after filter)${R}"

            true > "$DURATION_CACHE"
            _calc_duration

            local new_idx=0
            for i in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$i]}" == "$current_file" ]] && {
                    new_idx=$i; break
                }
            done

            echo -e "${C}Resuming track $((new_idx+1))/${#ALL_FILES[@]} - position restored${R}"
            sleep 1
            all_start_idx=$new_idx
            continue
        else
            return 0
        fi
    done
}

# === HANDLERS ===

_handle_search() {
    echo -e "\r\033[K"
    echo -ne "${G}Search: ${R}"
    read -r keyword
    if [[ -n "$keyword" ]]; then
        FILTER="*${keyword}*"
        _apply_filter
        if (( ${#DISPLAY_FILES[@]} == 0 )); then
            echo -e "${Y}No files matching: ${keyword}${R}"
            FILTER=""
            _apply_filter
            sleep 1
        fi
    else
        FILTER=""
        _apply_filter
    fi
    LAST_H=0
    _draw_browser
}

_page_down() {
    local m_rows=$(( $(tput lines) - 3 ))
    (( (CURRENT_PAGE+1) * m_rows < ${#DISPLAY_FILES[@]} )) && (( CURRENT_PAGE++ ))
    _draw_browser
}

_handle_number() {
    local first_key="$1"
    echo -ne "\r\033[K"
    read -e -r -p "$(echo -e "${G}Choice:${R} ")" -i "$first_key" input_cmd
    input_cmd=$(echo "$input_cmd" | tr -cd '0-9')
    [[ -z "$input_cmd" ]] && { _draw_browser; return; }

    local play_idx
    if _filter_active; then
        local disp_idx=$(( input_cmd - 1 ))
        if (( disp_idx >= 0 && disp_idx < ${#DISPLAY_FILES[@]} )); then
            local target_file="${DISPLAY_FILES[$disp_idx]}"
            play_idx=-1
            for j in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$j]}" == "$target_file" ]] && {
                    play_idx=$j; break
                }
            done
            (( play_idx >= 0 )) && _play_with_refresh "$play_idx"
        fi
    else
        play_idx=$(( input_cmd - 1 ))
        (( play_idx >= 0 && play_idx < ${#ALL_FILES[@]} )) && \
            _play_with_refresh "$play_idx"
    fi
    _draw_browser
}

_handle_play_all() {
    _filter_active || return
    (( ${#DISPLAY_FILES[@]} == 0 )) && return
    local first_file="${DISPLAY_FILES[0]}"
    local play_idx=0
    for j in "${!ALL_FILES[@]}"; do
        [[ "${ALL_FILES[$j]}" == "$first_file" ]] && { play_idx=$j; break; }
    done
    _play_with_refresh "$play_idx"
    _draw_browser
}

_handle_time_filter() {
    echo -e "\r\033[K"
    echo -ne "${G}Duration filter (+min or -min, 0=off): ${R}"
    read -r tmin
    tmin=$(echo "$tmin" | tr -d ' ')
    if [[ "$tmin" == "0" ]]; then
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        _apply_filter
    elif [[ "$tmin" =~ ^[+-][0-9]+$ ]]; then
        TIME_FILTER=${tmin:1}
        TIME_FILTER_MODE=${tmin:0:1}
        echo -e "${C}Scanning durations...${R}"
        _apply_filter
        if (( ${#DISPLAY_FILES[@]} == 0 )); then
            echo -e "${Y}No files matching duration filter${R}"
            TIME_FILTER=0
            TIME_FILTER_MODE=""
            _apply_filter
            sleep 1
        fi
    fi
    LAST_H=0
    _draw_browser
}

_handle_refresh() {
    _rescan_files
    _apply_filter
    true > "$DURATION_CACHE"
    _calc_duration
    LAST_H=0
    _draw_browser
}

_handle_quit() {
    if _filter_active; then
        FILTER=""
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        DISPLAY_FILES=("${ALL_FILES[@]}")
        CURRENT_PAGE=0
        LAST_H=0
        _draw_browser
    else
        clear
        exit 0
    fi
}

# =============================================================
# === STARTUP ===
# =============================================================

DIR="."
FILTER=""

if [[ "$1" == *\** || "$1" == *\?* ]]; then
    FILTER="$1"; DIR="${2:-.}"
elif [[ -n "$1" && -d "$1" ]]; then
    DIR="$1"
elif [[ -n "$1" ]]; then
    FILTER="*$1*"; DIR="${2:-.}"
fi

FULL_DIR=$(realpath "$DIR" 2>/dev/null || echo "$DIR")

_rescan_files

if (( ${#ALL_FILES[@]} == 0 )); then
    echo "No media files found in: $FULL_DIR"
    exit 1
fi

DISPLAY_FILES=("${ALL_FILES[@]}")

if [[ -n "$FILTER" ]]; then
    _apply_filter
    if (( ${#DISPLAY_FILES[@]} == 0 )); then
        echo "No files matching: $FILTER"
        exit 1
    fi
    echo -e "${C}Filter: ${Y}${FILTER}${C} — found ${G}${#DISPLAY_FILES[@]}${C} files${R}"
    sleep 0.5
fi

_create_input_conf
_calc_duration
_draw_browser

# =============================================================
# === MAIN INPUT LOOP ===
# =============================================================

while :; do
    read -s -r -n 1 key

    if [[ "$key" == $'\e' ]]; then
        read -s -r -n 1 -t 0.05 esc1
        read -s -r -n 1 -t 0.05 esc2
        read -s -r -n 1 -t 0.05 esc3
        rest="${esc1}${esc2}${esc3}"
        if   [[ "$rest" == "[5~" ]];          then (( CURRENT_PAGE > 0 )) && (( CURRENT_PAGE-- )); _draw_browser
        elif [[ "$rest" == "[6~" ]];          then _page_down
        elif [[ "${esc1}${esc2}" == "[A" ]];  then (( CURRENT_PAGE > 0 )) && (( CURRENT_PAGE-- )); _draw_browser
        elif [[ "${esc1}${esc2}" == "[B" ]];  then _page_down
        fi

    elif [[ "$key" == "" ]];                   then _draw_browser
    elif [[ "$key" == "u" || "$key" == "U" ]]; then _handle_refresh
    elif [[ "$key" == "a" || "$key" == "A" ]]; then _handle_play_all
    elif [[ "$key" == "t" || "$key" == "T" ]]; then _handle_time_filter
    elif [[ "$key" == "/" ]];                   then _handle_search
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then _handle_quit
    elif [[ "$key" =~ [0-9] ]];                then _handle_number "$key"
    fi
done
