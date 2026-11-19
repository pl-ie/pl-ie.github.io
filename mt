#!/usr/bin/env bash
# MT - Media Terminal Player v1.3.9
# A lightweight terminal media player with paginated file browser.
# Plays local audio/video files using mpv with resume support.
#
# Requirements: mpv, ffprobe (ffmpeg), termux-wake-lock (optional, Termux only)
#
# Usage:
#   mt               - open browser in current directory
#   mt /path/to/dir  - open browser in specified directory
#   mt course        - open browser with filter "course"
#   mt *course*      - same with explicit wildcards
#   mt course /path  - filter in specified directory
#   mt -o            - open browser sorted by file date, oldest first
#   mt -d            - open browser sorted by file date, newest first
#                      (--oldest / --newest also work; combine with a filter
#                      and/or a directory in any order)
#
# Controls (browser):
#   [number] + ENTER - play file by number
#   PgUp / PgDn      - scroll pages
#   a                - play all
#   u                - refresh file list
#   t                - time filter
#   l                - sort by length: longest first / shortest first / off
#   n                - sort by file date: newest first (press again = by name)
#   o                - sort by file date: oldest first (press again = by name)
#   /                - search
#   q                - clear filters / quit (the date sort stays)
#
# Controls (playback):
#   4 / 6            - volume down / up (one-handed use)
#   d / o            - sort newest first / oldest first (same key again = back
#                      to name order); the directory is rescanned and playing
#                      restarts at track 1 of the sorted list

termux-wake-lock 2>/dev/null || true

# === COLORS ===
G='\033[1;32m'
Y='\033[1;33m'
C='\033[1;36m'
M='\033[1;38;5;43m' # sea turquoise (256-color) - total duration of the filtered files
W='\033[1;37m'      # bold white - counters "(n/total)" next to the durations
R='\033[0m'
# Colors for mpv arguments (real ESC character)
_MC=$'\033[1;36m'
_MR=$'\033[0m'
_SC=$'\033[1;32m'   # bold bright green for track duration and the [n/total] field

# === CONFIG ===
WATCH_LATER_BASE="$HOME/.config/mpv/watch_later"
mkdir -p "$WATCH_LATER_BASE/session"

PLAYLIST_FILE="$HOME/.mt_current_playlist.m3u"
DURATION_CACHE=$(mktemp)
DUR_DB=$(mktemp)          # lines: "seconds<TAB>path"
INPUT_CONF=$(mktemp)
CURRENT_PAGE=0
LAST_H=0
LAST_W=0
FILTER=""
TIME_FILTER=0
TIME_FILTER_MODE=""
SORT_MODE="name"          # order from the directory scan: "name" (sort -V), "newest" or "oldest" (file date)
LEN_SORT=""               # sort of the displayed list by length: "" = off, "desc" = longest first, "asc" = shortest first
CALC_PID=""
MAX_ROWS=10
TERM_H=24
TERM_W=80
declare -A DUR

trap "[[ -n \"\$CALC_PID\" ]] && kill \"\$CALC_PID\" 2>/dev/null; rm -f '$DURATION_CACHE' '$DUR_DB' '$INPUT_CONF'" EXIT

# === KEY BINDINGS ===
_create_input_conf() {
    cat > "$INPUT_CONF" <<'EOF'
SPACE cycle pause
4 add volume -5
6 add volume +5
, seek -10 relative+keyframes
. seek +10 relative+keyframes
LEFT seek -20 relative+keyframes
RIGHT seek +20 relative+keyframes
UP seek +120 relative+keyframes
DOWN seek -120 relative+keyframes
n playlist-next
b playlist-prev
s cycle-values loop-playlist inf no
HOME seek 0 absolute
u quit 42
q quit 43
g quit 44
d quit 51
o quit 52
ENTER playlist-next
EOF
}

# === HELPER: is any filter / length sort active (the date sort is not a filter) ===
_filter_active() {
    [[ -n "$FILTER" || $TIME_FILTER -gt 0 || -n "$LEN_SORT" ]]
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

# === LOAD DURATIONS (DUR_DB → DUR[]) ===
_load_durations() {
    DUR=()
    local d p
    while IFS=$'\t' read -r d p; do
        [[ -n "$p" ]] && DUR["$p"]="$d"
    done < "$DUR_DB"
}

# === WAIT UNTIL BACKGROUND DURATION SCAN FINISHES ===
_wait_durations() {
    local need=${#ALL_FILES[@]} have
    while :; do
        have=$(wc -l < "$DUR_DB"); have=${have// /}
        (( have >= need )) && break
        [[ -n "$CALC_PID" ]] && ! kill -0 "$CALC_PID" 2>/dev/null && break
        printf "\r${C}Reading durations: %d/%d${R}" "$have" "$need"
        sleep 0.3
    done
    printf "\r\033[K"
}

# === SORT DISPLAY_FILES BY LENGTH (the 'l' key) ===
# Stable: files of equal length keep the order from the scan (name or date).
_sort_display() {
    [[ -z "$LEN_SORT" ]] && return
    (( ${#DISPLAY_FILES[@]} < 2 )) && return
    _wait_durations
    _load_durations
    local key="-k1,1rn"
    [[ "$LEN_SORT" == "asc" ]] && key="-k1,1n"
    local f
    mapfile -t DISPLAY_FILES < <(
        for f in "${DISPLAY_FILES[@]}"; do
            printf '%s\t%s\n' "${DUR[$f]:-0}" "$f"
        done | sort -s -t$'\t' $key | cut -f2-
    )
}

# === APPLY FILTER (text + time + sort) → DISPLAY_FILES ===
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
        local count=0 total=${#tmp_files[@]}
        for f in "${tmp_files[@]}"; do
            count=$((count+1))
            printf "\r${C}Scanning: %d/%d  found: %d${R}" "$count" "$total" "${#DISPLAY_FILES[@]}"
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
        echo
    else
        DISPLAY_FILES=("${tmp_files[@]}")
    fi

    _sort_display
    CURRENT_PAGE=0
}

# === FIND MEDIA FILES IN FULL_DIR (an extra find action can be passed in "$@") ===
_find_media() {
    find "$FULL_DIR" -maxdepth 1 -type f \( \
        -iname "*.mp3"  -o -iname "*.opus" -o -iname "*.ogg"  -o \
        -iname "*.flac" -o -iname "*.m4a"  -o -iname "*.wav"  -o \
        -iname "*.mp4"  -o -iname "*.webm" -o -iname "*.mkv"  -o \
        -iname "*.part" \
    \) "$@" 2>/dev/null
}

# === RESCAN DIRECTORY → ALL_FILES (the order follows SORT_MODE, as in mpl) ===
_rescan_files() {
    case "$SORT_MODE" in
        newest) mapfile -t ALL_FILES < <(_find_media -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-) ;;
        oldest) mapfile -t ALL_FILES < <(_find_media -printf '%T@ %p\n' | sort -n  | cut -d' ' -f2-) ;;
        *)      mapfile -t ALL_FILES < <(_find_media | sort -V) ;;
    esac
}

# === RESCAN AFTER A SORT CHANGE (n / o in the menu, d / o during playback) ===
# Durations are stored per path, so the background duration scan is restarted
# only when the set of files changed.
_rescan_after_sort() {
    local before=${#ALL_FILES[@]}
    _rescan_files
    (( ${#ALL_FILES[@]} != before )) && _calc_duration
    _apply_filter
}

# === BACKGROUND DURATION CALC (total + per-file DB) ===
_calc_duration() {
    [[ -n "$CALC_PID" ]] && kill "$CALC_PID" 2>/dev/null
    : > "$DURATION_CACHE"
    : > "$DUR_DB"
    (
        local total=0 count=0 f d dur
        local total_files=${#ALL_FILES[@]}
        for f in "${ALL_FILES[@]}"; do
            dur=0
            if [[ "$f" != *.part ]]; then
                d=$(ffprobe -v quiet \
                    -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 \
                    "$f" 2>/dev/null)
                [[ "$d" =~ ^[0-9]+ ]] && dur=$(awk "BEGIN{printf \"%d\", $d}")
            fi
            total=$(( total + dur ))
            printf '%s\t%s\n' "$dur" "$f" >> "$DUR_DB"
            count=$((count+1))
            if (( count % 5 == 0 || count == total_files )); then
                printf "%02d:%02d:%02d (%d/%d)" \
                    $((total/3600)) $(((total%3600)/60)) $((total%60)) \
                    "$count" "$total_files" > "$DURATION_CACHE"
            fi
        done
    ) &
    CALC_PID=$!
}

# === TERMINAL SIZE → TERM_H / TERM_W ===
_term_size() {
    local sz
    sz=$(stty size 2>/dev/null </dev/tty)
    if [[ "$sz" =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] > 0 )); then
        TERM_H=${BASH_REMATCH[1]}
        TERM_W=${BASH_REMATCH[2]}
    else
        TERM_H=$(tput lines 2>/dev/null)
        TERM_W=$(tput cols 2>/dev/null)
    fi
    [[ "$TERM_H" =~ ^[0-9]+$ ]] || TERM_H=24
    [[ "$TERM_W" =~ ^[0-9]+$ ]] || TERM_W=80
}

# === TEXT OF ACTIVE FILTERS / SORT (no colors) ===
_info_plain() {
    local s=""
    [[ -n "$FILTER" ]] && s="Filter: ${FILTER}"
    (( TIME_FILTER > 0 )) && s+="${s:+ | }Time: ${TIME_FILTER_MODE}${TIME_FILTER}min (${#DISPLAY_FILES[@]} files)"
    case "$LEN_SORT" in
        desc) s+="${s:+ | }Sort: longest first" ;;
        asc)  s+="${s:+ | }Sort: shortest first" ;;
    esac
    printf '%s' "$s"
}

# === LAYOUT: tracks per page (2 screen lines per track) ===
_calc_layout() {
    _term_size
    local footer=6 info
    if _filter_active; then
        info=$(_info_plain)
        # 4 help lines + info line(s) + filtered-total line + page line
        footer=$(( 6 + ( ${#info} + TERM_W - 1 ) / TERM_W ))
    fi
    footer=$(( footer + 1 ))   # spare line for wrapping
    MAX_ROWS=$(( (TERM_H - footer) / 2 ))
    (( MAX_ROWS < 1 )) && MAX_ROWS=1
}

# === DRAW BROWSER ===
_draw_browser() {
    _calc_layout
    local term_h=$TERM_H term_w=$TERM_W max_rows=$MAX_ROWS
    if [[ "$term_h" != "$LAST_H" || "$term_w" != "$LAST_W" ]]; then
        clear; LAST_H=$term_h; LAST_W=$term_w
    fi

    # line 1: "NNN) 276m " (11 chars) + start of the name
    # line 2: 6-char indent + rest of the name
    local w1=$(( term_w - 12 )); (( w1 < 8 )) && w1=8
    local w2=$(( term_w - 7 ));  (( w2 < 8 )) && w2=8

    local total_files=${#DISPLAY_FILES[@]}
    local total_pages=$(( (total_files + max_rows - 1) / max_rows ))
    (( total_pages < 1 )) && total_pages=1
    (( CURRENT_PAGE >= total_pages )) && CURRENT_PAGE=$(( total_pages - 1 ))

    local start_idx=$(( CURRENT_PAGE * max_rows ))
    local dur_val
    dur_val=$(cat "$DURATION_CACHE" 2>/dev/null)
    [[ -z "$dur_val" ]] && dur_val="Calculating..."

    _load_durations

    printf "\033[H\033[J"

    local i
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

        local secs="${DUR[$file_path]}" dtxt="--"
        if [[ -n "$secs" ]] && (( secs > 0 )); then
            local mins=$(( (secs + 30) / 60 ))
            if (( mins == 0 )); then dtxt="<1m"; else dtxt="${mins}m"; fi
        fi

        local name="${file_path##*/}"
        printf "${G}%3d)${R} ${C}%5s${R} %s\n" "$display_num" "$dtxt" "${name:0:w1}"
        printf "      %s\n" "${name:w1:w2}"
    done

    # n / o help cells: the active date sort is shown in green
    local c_new="$Y" c_old="$Y"
    [[ "$SORT_MODE" == "newest" ]] && c_new="$G"
    [[ "$SORT_MODE" == "oldest" ]] && c_old="$G"

    if _filter_active; then
        # Total duration of the currently displayed (filtered) files.
        # Durations come from the background scan; "..." = scan not finished yet.
        local f f_secs f_txt f_total=0 f_known=0
        for f in "${DISPLAY_FILES[@]}"; do
            if [[ -n "${DUR[$f]+x}" ]]; then
                f_secs="${DUR[$f]}"
                [[ "$f_secs" =~ ^[0-9]+$ ]] || f_secs=0
                f_total=$(( f_total + f_secs ))
                f_known=$(( f_known + 1 ))
            fi
        done
        f_txt=$(printf "%02d:%02d:%02d" \
            $((f_total/3600)) $(((f_total%3600)/60)) $((f_total%60)))
        (( f_known < total_files )) && f_txt+=" ..."

        local filter_info
        filter_info="${C}$(_info_plain)${R}"
        echo -e "${Y}a: all${R} | ${Y}l: sort${R} | ${Y}PgUp/PgDn${R}"
        echo -e "${Y}u: refresh${R}  | ${Y}t: time filter${R}"
        echo -e "${c_new}n: newest${R}   | ${c_old}o: oldest${R}"
        echo -e "${Y}/: search${R}   | ${Y}q: clear filters${R}"
        echo -e "$filter_info"
        # White counter: files shown after filtering / all files in the directory
        echo -e "${M}Filtered: ${f_txt}${W} (${total_files}/${#ALL_FILES[@]})${R}"
    else
        echo -e "${Y}a: all${R} | ${Y}l: sort${R} | ${Y}PgUp/PgDn${R}"
        echo -e "${Y}u: refresh${R}  | ${Y}t: time filter${R}"
        echo -e "${c_new}n: newest${R}   | ${c_old}o: oldest${R}"
        echo -e "${Y}/: search${R}   | ${Y}q: quit${R}"
        # Time stays cyan, the scan counter " (n/total)" is white
        local dur_time="${dur_val%% (*}" dur_cnt=""
        [[ "$dur_val" == *" ("* ]] && dur_cnt=" (${dur_val#* (}"
        echo -e "${C}Total: ${dur_time}${W}${dur_cnt}${R}"
    fi
    echo -ne "${Y}Page: $((CURRENT_PAGE+1))/$total_pages${R} | ${G}Choice:${R} "
}

# === PLAYBACK HEADER ===
_show_playback_header() {
    clear
    echo -e "${C}____________________________________________________________${R}"
    echo -e "\n${Y}  4 / 6  : Volume down / up${R}"
    echo -e "\n${Y}  , / .  : Seek -10 / +10 sec${R}"
    echo -e "\n${Y}  ← / →  : Seek -20 / +20 sec${R}"
    echo -e "\n${Y}  ↑ / ↓  : Seek +120 / -120 sec${R}"
    echo -e "\n${Y}  n / b  : Next / Previous${R}"
    echo -e "\n${Y}  SPACE  : Pause | s: Loop${R}"
    echo -e "\n${Y}  HOME   : Restart  |  q: Menu${R}"
    echo -e "\n${Y}  u: Refresh playlist${R}"
    echo -e "\n${Y}  d / o  : Newest / Oldest${R}"
    echo -e "\n${Y}  g: Go to track${R}"
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

    # Status line: the track counter [n/total] is already shown in the colored
    # "playing" line, so it is not repeated here. Duration is bold green, V: is plain white.
    mpv \
        --no-video \
        --audio-display=no \
        --no-input-default-bindings \
        --input-ar-delay=1000 \
        --input-ar-rate=1 \
        --volume=70 \
        --playlist="$PLAYLIST_FILE" \
        --playlist-start="$start_idx" \
        --save-position-on-quit \
        --resume-playback \
        --watch-later-directory="$WATCH_LATER_BASE" \
        --watch-later-options-remove=pause \
        --input-conf="$INPUT_CONF" \
        --term-status-msg="\${time-pos}/${_SC}\${duration}${_MR} | V:\${volume}%" \
        --term-playing-msg="${_MC}▶ ${_SC}[\${playlist-pos-1}/\${playlist-count}]${_MC} \${filename}${_MR}"

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
            _calc_duration
            _apply_filter

            echo -e "${G}Found ${#ALL_FILES[@]} files (${#DISPLAY_FILES[@]} after filter)${R}"

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
        elif [[ $exit_code -eq 51 || $exit_code -eq 52 ]]; then
            # d / o during playback (same logic as mpl): toggle the date sort
            # (the same key again = back to name order), rescan the directory
            # and start again from track 1 of the sorted list
            if [[ $exit_code -eq 51 ]]; then
                if [[ "$SORT_MODE" == "newest" ]]; then SORT_MODE="name"; else SORT_MODE="newest"; fi
            else
                if [[ "$SORT_MODE" == "oldest" ]]; then SORT_MODE="name"; else SORT_MODE="oldest"; fi
            fi
            LEN_SORT=""     # a length sort would hide the date order
            local sort_label="by name"
            [[ "$SORT_MODE" == "newest" ]] && sort_label="newest first"
            [[ "$SORT_MODE" == "oldest" ]] && sort_label="oldest first"
            echo -e "\n${G}Sort: ${sort_label}${R}"

            _rescan_after_sort
            if (( ${#DISPLAY_FILES[@]} == 0 )); then
                echo -e "${Y}No files found - returning to menu${R}"
                sleep 1
                return 0
            fi

            # track 1 of the playlist = first displayed file
            all_start_idx=0
            for i in "${!ALL_FILES[@]}"; do
                [[ "${ALL_FILES[$i]}" == "${DISPLAY_FILES[0]}" ]] && { all_start_idx=$i; break; }
            done
            echo -e "${M}Starting at track 1/${#DISPLAY_FILES[@]}${R}"
            sleep 1
            continue
        elif [[ $exit_code -eq 44 ]]; then
            local play_list=()
            if _filter_active; then
                play_list=("${DISPLAY_FILES[@]}")
            else
                play_list=("${ALL_FILES[@]}")
            fi
            echo -ne "\n${G}Go to track (1-${#play_list[@]}): ${R}"
            read -r goto_num
            goto_num=$(echo "$goto_num" | tr -cd '0-9')
            if [[ -n "$goto_num" ]]; then
                local goto_pl_idx=$((goto_num - 1))
                if (( goto_pl_idx >= 0 && goto_pl_idx < ${#play_list[@]} )); then
                    local target_file="${play_list[$goto_pl_idx]}"
                    local new_all_idx=0
                    for i in "${!ALL_FILES[@]}"; do
                        [[ "${ALL_FILES[$i]}" == "$target_file" ]] && { new_all_idx=$i; break; }
                    done
                    all_start_idx=$new_all_idx
                else
                    echo -e "${Y}❌ No such track: $goto_num${R}"; sleep 1
                fi
            fi
            continue
        else
            return 0
        fi
    done
}

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

_handle_sort() {
    case "$LEN_SORT" in
        "")   LEN_SORT="desc" ;;
        desc) LEN_SORT="asc" ;;
        *)    LEN_SORT="" ;;
    esac
    _apply_filter
    LAST_H=0
    _draw_browser
}

# Date sort (same logic as mpl): $1 = "newest" or "oldest"; the same key again
# goes back to name order. The order itself comes from the directory scan.
_handle_date_sort() {
    if [[ "$SORT_MODE" == "$1" ]]; then
        SORT_MODE="name"
    else
        SORT_MODE="$1"
    fi
    LEN_SORT=""     # a length sort would hide the date order
    _rescan_after_sort
    LAST_H=0
    _draw_browser
}

_page_down() {
    _calc_layout
    (( (CURRENT_PAGE+1) * MAX_ROWS < ${#DISPLAY_FILES[@]} )) && (( CURRENT_PAGE++ ))
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
    local source_list=()
    if _filter_active; then
        source_list=("${DISPLAY_FILES[@]}")
    else
        source_list=("${ALL_FILES[@]}")
    fi
    (( ${#source_list[@]} == 0 )) && return
    local first_file="${source_list[0]}"
    local play_idx=0
    for j in "${!ALL_FILES[@]}"; do
        [[ "${ALL_FILES[$j]}" == "$first_file" ]] && { play_idx=$j; break; }
    done
    _play_with_refresh "$play_idx"
    _draw_browser
}

_handle_time_filter() {
    echo -e "\r\033[K"
    echo -ne "${G}Duration filter (+min / -min / min, 0=off): ${R}"
    read -r tmin
    tmin=$(echo "$tmin" | tr -d ' ')
    if [[ "$tmin" == "0" ]]; then
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        _apply_filter
    elif [[ "$tmin" =~ ^[+-]?[0-9]+$ ]]; then
        if [[ "$tmin" =~ ^[+-] ]]; then
            TIME_FILTER=${tmin:1}
            TIME_FILTER_MODE=${tmin:0:1}
        else
            TIME_FILTER=$tmin
            TIME_FILTER_MODE="+"
        fi
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
    _calc_duration
    _apply_filter
    LAST_H=0
    _draw_browser
}

_handle_quit() {
    if _filter_active; then
        FILTER=""
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        LEN_SORT=""
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

# Sort flags (can appear anywhere on the command line, like in mpl):
#   -o / --oldest  open sorted by file date, oldest first
#   -d / --newest  open sorted by file date, newest first (the last one wins)
_args=()
for _a in "$@"; do
    case "$_a" in
        -o|--oldest) SORT_MODE="oldest" ;;
        -d|--newest) SORT_MODE="newest" ;;
        *)  _args+=("$_a") ;;
    esac
done
set -- "${_args[@]}"

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
    elif [[ "$key" == "l" || "$key" == "L" ]]; then _handle_sort
    elif [[ "$key" == "n" || "$key" == "N" ]]; then _handle_date_sort newest
    elif [[ "$key" == "o" || "$key" == "O" ]]; then _handle_date_sort oldest
    elif [[ "$key" == "/" ]];                   then _handle_search
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then _handle_quit
    elif [[ "$key" =~ [0-9] ]];                then _handle_number "$key"
    fi
done

# === END OF FILE (mt v1.3.9) ===
