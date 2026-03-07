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
#   q                - quit
#
# Controls (playback):
#   SPACE            - pause / resume
#   9 / 0            - volume down / up
#   , / .            - seek -10 / +10 sec
#   n / b            - next / previous track
#   s                - toggle loop
#   u                - refresh playlist (resume position kept)
#   q                - back to menu

termux-wake-lock 2>/dev/null || true

# === COLORS ===
G='\033[1;32m'   # green
Y='\033[1;33m'   # yellow
C='\033[1;36m'   # cyan
R='\033[0m'      # reset

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

trap "rm -f '$DURATION_CACHE' '$INPUT_CONF'" EXIT

# === KEY BINDINGS (same approach as MPL - custom input-conf) ===
# u exits mpv with code 42 → refresh playlist without losing position
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

# === FUNCTIONS ===

# Wait until a .part file reaches minimum buffered size before playing.
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

# Apply FILTER to ALL_FILES → update DISPLAY_FILES and reset page.
_apply_filter() {
    if [[ -z "$FILTER" ]]; then
        DISPLAY_FILES=("${ALL_FILES[@]}")
    else
        local grep_pat
        grep_pat=$(echo "$FILTER" | sed 's/\*/.*/g; s/?/./g')
        DISPLAY_FILES=()
        for f in "${ALL_FILES[@]}"; do
            local base
            base=$(basename "$f")
            if echo "$base" | grep -qi "$grep_pat"; then
                DISPLAY_FILES+=("$f")
            fi
        done
    fi
    CURRENT_PAGE=0
}

# Calculate total duration of all files in the background.
# Updates DURATION_CACHE every 5 files so the UI shows live progress.
_calc_duration() {
    (
        local total=0
        local count=0
        local total_files=${#ALL_FILES[@]}

        for f in "${ALL_FILES[@]}"; do
            # Skip incomplete .part files - ffprobe cannot read their duration
            [[ "$f" == *.part ]] && { count=$((count + 1)); continue; }

            local dur
            dur=$(ffprobe -v quiet \
                -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 \
                "$f" 2>/dev/null)

            [[ "$dur" =~ ^[0-9]+ ]] && \
                total=$(awk "BEGIN{printf \"%d\", $total + $dur}")

            count=$((count + 1))

            if (( count % 5 == 0 || count == total_files )); then
                printf "%02d:%02d:%02d (%d/%d)" \
                    $((total / 3600)) \
                    $(((total % 3600) / 60)) \
                    $((total % 60)) \
                    "$count" \
                    "$total_files" > "$DURATION_CACHE"
            fi
        done
    ) &
}

# Draw the paginated file browser.
# Filename display: uses fixed 56-char trim (like MPL) - reliable on any terminal width.
_draw_browser() {
    local term_h term_w
    term_h=$(tput lines)
    term_w=$(tput cols)

    if [[ "$term_h" != "$LAST_H" || "$term_w" != "$LAST_W" ]]; then
        clear
        LAST_H=$term_h
        LAST_W=$term_w
    fi

    # Reserve 3 lines for the footer
    local max_rows=$(( term_h - 3 ))
    (( max_rows < 1 )) && max_rows=1

    local total_files=${#DISPLAY_FILES[@]}
    local total_pages=$(( (total_files + max_rows - 1) / max_rows ))

    (( CURRENT_PAGE >= total_pages )) && CURRENT_PAGE=$(( total_pages - 1 ))

    local start_idx=$(( CURRENT_PAGE * max_rows ))

    local dur_val
    dur_val=$(cat "$DURATION_CACHE" 2>/dev/null)
    [[ -z "$dur_val" ]] && dur_val="Calculating..."

    # Move cursor to top-left and clear screen
    printf "\033[H\033[J"

    for (( i = 0; i < max_rows; i++ )); do
        local idx=$(( start_idx + i ))
        if (( idx < total_files )); then
            local file_path="${DISPLAY_FILES[$idx]}"

            # In filtered mode: show sequential position (1,2,3...)
            # In full mode: show real track number from ALL_FILES
            local display_num
            if [[ -n "$FILTER" ]]; then
                display_num=$(( idx + 1 ))
            else
                display_num=0
                for j in "${!ALL_FILES[@]}"; do
                    [[ "${ALL_FILES[$j]}" == "$file_path" ]] && {
                        display_num=$(( j + 1 ))
                        break
                    }
                done
            fi

            local name
            name=$(basename "$file_path" | cut -c1-56)
            printf "${G}%3d)${R} %s\n" "$display_num" "$name"
        fi
    done

    # Footer - show filter if active
    if [[ -n "$FILTER" ]]; then
        echo -e "${Y}a: play all${R} | ${Y}u: refresh${R} | ${Y}q: clear filter${R} | ${Y}/: search${R} | ${C}Filter: ${FILTER} (${#DISPLAY_FILES[@]} files)${R}"
    else
        echo -e "${Y}PgUp/PgDn${R} | ${Y}u: refresh${R} | ${Y}q: quit${R} | ${Y}/: search${R} | ${C}Total: ${dur_val}${R}"
    fi
    echo -ne "${Y}Page: $((CURRENT_PAGE + 1))/$total_pages${R} | ${G}Choice:${R} "
}

# Display playback key bindings before mpv starts - matches MPL style exactly.
_show_playback_header() {
    clear
    echo -e "${C}____________________________________________________________${R}"
    echo -e ""
    echo -e "${Y}  9 / 0  : Volume down / up${R}"
    echo -e ""
    echo -e "${Y}  , / .  : Seek -10 / +10 sec${R}"
    echo -e ""
    echo -e "${Y}  ← / →  : Seek -20 / +20 sec${R}"
    echo -e ""
    echo -e "${Y}  ↑ / ↓  : Seek +120 / -120 sec${R}"
    echo -e ""
    echo -e "${Y}  n / b  : Next / Previous${R}"
    echo -e ""
    echo -e "${Y}  SPACE  : Pause | s: Shuffle${R}"
    echo -e ""
    echo -e "${Y}  q: Menu${R}"
    echo -e ""
    echo -e "${Y}  u: Refresh playlist${R}"
    echo -e ""
    echo -e "${C}____________________________________________________________${R}"
}

# Write playlist and launch mpv starting at given index (0-based).
# When filter is active, playlist contains only DISPLAY_FILES so n/b
# navigate within filtered results. start_idx is always an ALL_FILES index,
# so we translate it to the DISPLAY_FILES position first.
_run_mpv() {
    local all_idx="$1"

    # Build playlist from filtered or full list
    true > "$PLAYLIST_FILE"
    local play_list=()
    if [[ -n "$FILTER" ]]; then
        play_list=("${DISPLAY_FILES[@]}")
    else
        play_list=("${ALL_FILES[@]}")
    fi
    for f in "${play_list[@]}"; do
        echo "$f" >> "$PLAYLIST_FILE"
    done

    # Find start position within the playlist we just wrote
    local start_idx=0
    local target="${ALL_FILES[$all_idx]}"
    for i in "${!play_list[@]}"; do
        [[ "${play_list[$i]}" == "$target" ]] && { start_idx=$i; break; }
    done

    _show_playback_header

    # Wait for .part file to buffer if needed
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

# Playback loop with u-key refresh support (ported from MPL).
# all_start_idx is always an index into ALL_FILES.
_play_with_refresh() {
    local all_start_idx="$1"

    while true; do
        _run_mpv "$all_start_idx"
        local exit_code=$?

        if [[ $exit_code -eq 42 ]]; then
            # 'u' pressed - remember current file, rescan, restore position
            echo -e "\n${G}Refreshing playlist...${R}"
            local current_file="${ALL_FILES[$all_start_idx]}"

            # Rescan directory
            mapfile -t ALL_FILES < <(
                find "$FULL_DIR" -maxdepth 1 -type f \( \
                    -iname "*.mp3"  -o -iname "*.opus" -o -iname "*.ogg"  -o \
                    -iname "*.flac" -o -iname "*.m4a"  -o -iname "*.wav"  -o \
                    -iname "*.mp4"  -o -iname "*.webm" -o -iname "*.mkv"  -o \
                    -iname "*.part" \
                \) 2>/dev/null | sort -V
            )

            # Reapply active filter
            _apply_filter

            echo -e "${G}Found ${#ALL_FILES[@]} files${R}"

            # Restart duration calculation for updated file list
            true > "$DURATION_CACHE"
            _calc_duration

            # Find same file in updated ALL_FILES → restore index
            local new_idx=0
            for i in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$i]}" == "$current_file" ]] && {
                    new_idx=$i
                    break
                }
            done

            echo -e "${C}Resuming track $((new_idx+1))/${#ALL_FILES[@]} - position restored${R}"
            sleep 1
            all_start_idx=$new_idx
            continue
        else
            # exit 43 = q pressed
            # if filter active → return to filtered browser (keep filter)
            # if no filter → return to full browser
            return 0
        fi
    done
}

# Handle / search input.
# Clears the footer area first so the prompt appears on a clean line.
_handle_search() {
    # Clear current line (Choice:) and move to next clean line
    echo -e "\r\033[K"
    echo -ne "${G}Search: ${R}"
    read -r keyword
    if [[ -n "$keyword" ]]; then
        FILTER="*${keyword}*"
        _apply_filter
        if (( ${#DISPLAY_FILES[@]} == 0 )); then
            echo -e "${Y}No files matching: ${keyword}${R}"
            FILTER=""
            DISPLAY_FILES=("${ALL_FILES[@]}")
            sleep 1
        fi
    else
        # Empty input = clear active filter
        FILTER=""
        DISPLAY_FILES=("${ALL_FILES[@]}")
    fi
    LAST_H=0  # force full redraw
    _draw_browser
}

# Handle PgDn in main loop.
_page_down() {
    local m_h m_rows
    m_h=$(tput lines)
    m_rows=$(( m_h - 3 ))
    (( (CURRENT_PAGE + 1) * m_rows < ${#DISPLAY_FILES[@]} )) && \
        (( CURRENT_PAGE++ ))
    _draw_browser
}

# Handle number input and play selected track.
# In filtered mode: number refers to position in DISPLAY_FILES (1,2,3...).
# In full mode: number refers to real track number in ALL_FILES.
_handle_number() {
    local first_key="$1"
    echo -n "$first_key"
    read -r rest
    local input_cmd="${first_key}${rest}"
    input_cmd=$(echo "$input_cmd" | tr -cd '0-9')

    if [[ -n "$input_cmd" ]]; then
        local play_idx
        if [[ -n "$FILTER" ]]; then
            # Filtered mode: input is 1-based index into DISPLAY_FILES
            local disp_idx=$(( input_cmd - 1 ))
            if (( disp_idx >= 0 && disp_idx < ${#DISPLAY_FILES[@]} )); then
                local target_file="${DISPLAY_FILES[$disp_idx]}"
                # Find real index in ALL_FILES
                play_idx=-1
                for j in "${!ALL_FILES[@]}"; do
                    [[ "${ALL_FILES[$j]}" == "$target_file" ]] && {
                        play_idx=$j
                        break
                    }
                done
                (( play_idx >= 0 )) && _play_with_refresh "$play_idx"
            fi
        else
            # Normal mode: input is real track number
            play_idx=$(( input_cmd - 1 ))
            (( play_idx >= 0 && play_idx < ${#ALL_FILES[@]} )) && \
                _play_with_refresh "$play_idx"
        fi
        _draw_browser
    fi
}

# === STARTUP ===

DIR="."
FILTER=""

if [[ "$1" == *\** || "$1" == *\?* ]]; then
    # Wildcard pattern like *kurs* - filter mode
    FILTER="$1"
    DIR="${2:-.}"
elif [[ -n "$1" && -d "$1" ]]; then
    # Existing directory path
    DIR="$1"
elif [[ -n "$1" ]]; then
    # Plain keyword - treat as filter (e.g. mt kurs)
    FILTER="*$1*"
    DIR="${2:-.}"
fi

FULL_DIR=$(realpath "$DIR" 2>/dev/null || echo "$DIR")

mapfile -t ALL_FILES < <(
    find "$FULL_DIR" -maxdepth 1 -type f \( \
        -iname "*.mp3"  -o -iname "*.opus" -o -iname "*.ogg"  -o \
        -iname "*.flac" -o -iname "*.m4a"  -o -iname "*.wav"  -o \
        -iname "*.mp4"  -o -iname "*.webm" -o -iname "*.mkv"  -o \
        -iname "*.part" \
    \) 2>/dev/null | sort -V
)

if (( ${#ALL_FILES[@]} == 0 )); then
    echo "No media files found in: $FULL_DIR"
    exit 1
fi

DISPLAY_FILES=("${ALL_FILES[@]}")

# Apply CLI filter if given (e.g. mt kurs)
if [[ -n "$FILTER" ]]; then
    _apply_filter
    if (( ${#DISPLAY_FILES[@]} == 0 )); then
        echo "No files matching: $FILTER"
        exit 1
    fi
    echo -e "${C}Filter: ${Y}${FILTER}${C} — found ${G}${#DISPLAY_FILES[@]}${C} files${R}"
    sleep 0.5
fi

# Create key bindings config once (reused for every mpv launch)
_create_input_conf

# Start duration calculation in background
_calc_duration

# Initial browser draw
_draw_browser

# === MAIN INPUT LOOP ===

while :; do
    read -s -r -n 1 key

    if [[ "$key" == $'\e' ]]; then
        read -s -r -n 1 -t 0.05 esc1
        read -s -r -n 1 -t 0.05 esc2
        read -s -r -n 1 -t 0.05 esc3
        rest="${esc1}${esc2}${esc3}"

        if [[ "$rest" == "[5~" ]]; then
            # PgUp
            (( CURRENT_PAGE > 0 )) && (( CURRENT_PAGE-- ))
            _draw_browser
        elif [[ "$rest" == "[6~" ]]; then
            # PgDn
            _page_down
        elif [[ "${esc1}${esc2}" == "[A" ]]; then
            # Arrow Up - scroll one page up
            (( CURRENT_PAGE > 0 )) && (( CURRENT_PAGE-- ))
            _draw_browser
        elif [[ "${esc1}${esc2}" == "[B" ]]; then
            # Arrow Down - scroll one page down
            _page_down
        fi

    elif [[ "$key" == "" ]]; then
        _draw_browser

    elif [[ "$key" == "u" || "$key" == "U" ]]; then
        # Refresh file list
        mapfile -t ALL_FILES < <(
            find "$FULL_DIR" -maxdepth 1 -type f \( \
                -iname "*.mp3"  -o -iname "*.opus" -o -iname "*.ogg"  -o \
                -iname "*.flac" -o -iname "*.m4a"  -o -iname "*.wav"  -o \
                -iname "*.mp4"  -o -iname "*.webm" -o -iname "*.mkv"  -o \
                -iname "*.part" \
            \) 2>/dev/null | sort -V
        )
        _apply_filter
        true > "$DURATION_CACHE"
        _calc_duration
        LAST_H=0
        _draw_browser

    elif [[ "$key" == "a" || "$key" == "A" ]]; then
        # Play all - only available in Search/filter mode
        if [[ -n "$FILTER" ]]; then
            local first_file="${DISPLAY_FILES[0]}"
            local play_idx=0
            for j in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$j]}" == "$first_file" ]] && { play_idx=$j; break; }
            done
            _play_with_refresh "$play_idx"
            _draw_browser
        fi

    elif [[ "$key" =~ [0-9] ]]; then
        _handle_number "$key"

    elif [[ "$key" == "/" ]]; then
        _handle_search

    elif [[ "$key" == "q" || "$key" == "Q" ]]; then
        if [[ -n "$FILTER" ]]; then
            # First q: clear filter, show full list
            FILTER=""
            DISPLAY_FILES=("${ALL_FILES[@]}")
            CURRENT_PAGE=0
            LAST_H=0
            _draw_browser
        else
            # Second q (no filter): exit
            clear
            exit 0
        fi
    fi
done
