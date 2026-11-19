#!/usr/bin/env bash
# MPL PRO v3.3.1 - Media Playlist Player
# Play local audio/video files with playlist management
# Press 'u' during playback to refresh the playlist without losing your position
# Press 'd' / 'o' during playback to sort newest-first / oldest-first (press the
# same key again to go back to name order); playing restarts at track 1
# Press '4' / '6' during playback to lower / raise the volume (one-handed use)
# Press 'f' during playback to add the current track to <dirname>.m3u8 (fav)
# Press 'n' in menu to toggle sort: newest-first <-> name (default)
# Press 'o' in menu to toggle sort: oldest-first <-> name (default)
# Press 'm' in menu to switch mode: 1 = normal, 2 = sample (asks for seconds);
# playing starts at once in the chosen mode
# Press 's' during sample playback to enter a new sample length
# Press 'm' during playback to switch sample <-> normal for the rest of the list
#
# Usage:
#   mpl                  - open interactive menu in current directory
#   mpl /path/to/dir     - open interactive menu in specified directory
#   mpl -a               - play all files in current directory
#   mpl -a /path         - play all files in specified directory
#   mpl -s [sec]         - sample mode: play only the first [sec] seconds
#                          (default 15) of every file in current directory;
#                          the status line ends with a yellow countdown of
#                          the seconds left in the sample; press 'p' to play
#                          the current track in full (it resumes from where
#                          you are); when it ends, or on 'n', sampling goes
#                          on with the next track, on 'b' with the previous
#   mpl -s 20 /path      - sample mode in specified directory
#   mpl -n N             - play all files, starting at track number N
#                          (numbered as in the menu list)
#   mpl -s 15 -n 10      - options combine in any order: sample mode,
#                          starting at track 10
#   mpl -d               - play all files, newest first
#   mpl -o               - play all files, oldest first
#   mpl -d -s 15 -n 10   - -d / -o combine with the other options too; -n
#                          counts in the sorted list (the last of -d / -o wins)
#   mpl course           - play files matching keyword (e.g. mpl course)
#   mpl *course*         - same with explicit wildcards
#   mpl course /path     - keyword filter in specified directory

termux-wake-lock 2>/dev/null || true

# === COLORS ===
G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; R='\033[0m'
# Colors for mpv arguments (real ESC character)
_MC=$'\033[1;36m'
_MR=$'\033[0m'
_SC=$'\033[1;32m'   # bold bright green for track duration and the [n/total] field
_YC=$'\033[1;33m'   # bold yellow for the sample countdown (sample mode)
_WC=$'\033[1;37m'   # bold white for the "/" separators in the status line

# === CONFIG ===
WATCH_LATER_BASE="$HOME/.config/mpv/watch_later"
mkdir -p "$WATCH_LATER_BASE"
VOL_FILE="$WATCH_LATER_BASE/volume.txt"

PLAYLIST_FILE=$(mktemp)
trap "rm -f '$PLAYLIST_FILE'" EXIT

# === STATE ===
MODE="menu"
DIR="."
FILTER=""
TIME_FILTER=0
TIME_FILTER_MODE=""
TSAMPLE=0          # sample mode: seconds to play per track (0 = off)
SAMPLE_LAST=15     # last chosen sample length (default offered by the 'm' menu)
START_NUM=0        # -n N: track number to start playing at (1-based, 0 = off)
SORT_MODE="name"   # "name" (default, sort -V), "newest" or "oldest"
CUR_IDX=0          # playlist index of the track that was playing when mpv quit
ALL_FILES=()
files=()

# === ARGUMENT PARSING ===
# Options (-s, -a, -n, -d, -o) may come in any order and combine; what is left
# over is the keyword/directory: [keyword|dir] [dir]
POSITIONAL=()
while (( $# > 0 )); do
    case "$1" in
        -s|--sample)
            MODE="playlist"
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                TSAMPLE="$2"
                shift
            else
                TSAMPLE=15      # no number given: default sample length
            fi
            ;;
        -a|--all)
            MODE="playlist"
            ;;
        -d|--newest)
            MODE="playlist"
            SORT_MODE="newest"
            ;;
        -o|--oldest)
            MODE="playlist"
            SORT_MODE="oldest"
            ;;
        -n|--number)
            if [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 > 0 )); then
                START_NUM=$((10#$2))
                shift
            else
                echo "mpl: -n needs a track number (1 or more)" >&2
                exit 1
            fi
            MODE="playlist"
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

if [[ "${POSITIONAL[0]}" == *\** || "${POSITIONAL[0]}" == *\?* ]]; then
    FILTER="${POSITIONAL[0]}"
    DIR="${POSITIONAL[1]:-.}"
elif [[ -n "${POSITIONAL[0]}" && -d "${POSITIONAL[0]}" ]]; then
    DIR="${POSITIONAL[0]}"
elif [[ -n "${POSITIONAL[0]}" ]]; then
    FILTER="*${POSITIONAL[0]}*"
    DIR="${POSITIONAL[1]:-.}"
fi
# a keyword on its own opens the filtered menu; with -s/-a/-n it plays
[[ -n "$FILTER" && "$MODE" == "menu" ]] && MODE="filter"

(( TSAMPLE > 0 )) && SAMPLE_LAST=$TSAMPLE

FULL_DIR=$(realpath "$DIR" 2>/dev/null || echo "$DIR")

# Favourites playlist named after the viewed directory (same as list-viewer)
PL_NAME=$(basename "$FULL_DIR" | tr ' ' '_')
[[ -z "$PL_NAME" || "$PL_NAME" == "/" ]] && PL_NAME="root"
FAV_PLAYLIST="$FULL_DIR/${PL_NAME}.m3u8"
export FAV_PLAYLIST   # read by the helper script that mpv runs on "f"

# === FUNCTIONS ===

# Raw scan -> ALL_FILES (respects SORT_MODE)
_rescan_files() {
    if [[ "$SORT_MODE" == "newest" ]]; then
        mapfile -t ALL_FILES < <(find "$FULL_DIR" -maxdepth 1 -type f \( \
            -iname "*.mp3" -o -iname "*.opus" -o -iname "*.ogg" -o \
            -iname "*.flac" -o -iname "*.m4a" -o -iname "*.wav" -o \
            -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o \
            -iname "*.part" \) -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | cut -d' ' -f2-)
    elif [[ "$SORT_MODE" == "oldest" ]]; then
        mapfile -t ALL_FILES < <(find "$FULL_DIR" -maxdepth 1 -type f \( \
            -iname "*.mp3" -o -iname "*.opus" -o -iname "*.ogg" -o \
            -iname "*.flac" -o -iname "*.m4a" -o -iname "*.wav" -o \
            -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o \
            -iname "*.part" \) -printf '%T@ %p\n' 2>/dev/null \
            | sort -n | cut -d' ' -f2-)
    else
        mapfile -t ALL_FILES < <(find "$FULL_DIR" -maxdepth 1 -type f \( \
            -iname "*.mp3" -o -iname "*.opus" -o -iname "*.ogg" -o \
            -iname "*.flac" -o -iname "*.m4a" -o -iname "*.wav" -o \
            -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mkv" -o \
            -iname "*.part" \) 2>/dev/null | sort -V)
    fi
}

# Apply text filter + time filter -> files[]
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

# Write mpv key bindings to a temp input config
# $1 = config file, $2 = favourites helper script, $3 = run mode ("full" or not)
_create_input_conf() {
    local conf="$1"
    cat > "$conf" <<'EOF'
SPACE cycle pause
4 add volume -5
6 add volume +5
, seek -10 relative+keyframes
. seek +10 relative+keyframes
LEFT seek -20 relative+keyframes
RIGHT seek +20 relative+keyframes
UP seek +120 relative+keyframes
DOWN seek -120 relative+keyframes
HOME seek 0 absolute
m quit 50
u quit 42
g quit 43
d quit 51
o quit 52
q quit
ENTER playlist-next
EOF
    # f = add the current track to the favourites playlist (helper path in $2)
    if [[ -n "$2" ]]; then
        printf '%s\n' "f run \"sh\" \"$2\" \"\${path}\" ; show-text \"★ fav: \${filename}\" 2500" >> "$conf"
    fi
    # Sample mode only (not while a full track is playing):
    #   p = quit with code 44, the shell then replays the current track in full
    #   s = quit with code 49, the shell asks for a new sample length
    # Otherwise s toggles playlist looping.
    if (( TSAMPLE > 0 )) && [[ "$3" != "full" ]]; then
        printf '%s\n' "p quit 44" "s quit 49" >> "$conf"
    else
        printf '%s\n' 's cycle-values loop-playlist inf no ; show-text "Loop: ${loop-playlist}"' >> "$conf"
    fi
    # n / b = next / previous track. While a full track is playing they quit
    # with codes 47 / 48 instead, so the shell goes back to sampling.
    if [[ "$3" == "full" ]]; then
        printf '%s\n' "n quit 47" "b quit 48" >> "$conf"
    else
        printf '%s\n' "n playlist-next" "b playlist-prev" >> "$conf"
    fi
}

# Write the mpv Lua helper (loaded in every mode). Script options:
#   mpl-sample  seconds per track in sample mode (0 = off)
#   mpl-full    "yes" while one track is played in full from sample mode
#   mpl-state   file that receives the current playlist index
_create_mpl_lua() {
    cat > "$1" <<'EOF'
local sample = tonumber(mp.get_opt("mpl-sample")) or 0
local full   = mp.get_opt("mpl-full") == "yes"
local state  = mp.get_opt("mpl-state")

-- keep the index of the current track in the state file, so the shell can
-- tell which track was playing when mpv quit (used by u, g and p)
if state and state ~= "" then
    mp.observe_property("playlist-pos", "number", function(_, pos)
        if not pos then return end
        local f = io.open(state, "w")
        if f then
            f:write(string.format("%d", pos), "\n")
            f:close()
        end
    end)
end

-- full mode: when the track ends by itself, quit with code 46 so the shell
-- can go back to sampling with the next track
if full then
    mp.register_event("end-file", function(ev)
        if ev.reason == "eof" then mp.commandv("quit", "46") end
    end)
end

-- sample mode: status line ends with a yellow countdown of the seconds left
-- in the sample. If the track is shorter than the sample, the countdown runs
-- to the real end of the track.
if sample > 0 then
    local ESC = "\27["
    local W = ESC .. "1;37m"   -- bold white: "/" separators
    local G = ESC .. "1;32m"   -- bold green: track duration
    local Y = ESC .. "1;33m"   -- bold yellow: seconds left
    local R = ESC .. "0m"

    local last = nil

    local function update()
        local pos = mp.get_property_number("time-pos")
        if not pos then return end

        local total = sample
        local dur = mp.get_property_number("duration")
        if dur and dur > 0 and dur < total then total = dur end

        local left = math.ceil(total - pos)
        if left < 0 then left = 0 end

        -- only touch the status line when the displayed second changes
        if left == last then return end
        last = left

        mp.set_property("term-status-msg",
            "${time-pos}" .. W .. "/" .. G .. "${duration}" .. W .. "/" ..
            Y .. string.format("%d", left) .. R .. " | V:${volume}%")
    end

    mp.observe_property("time-pos", "number", update)
end
EOF
}

# Print player header with key bindings
_show_header() {
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${C}  MPL PRO v3.3.1 | OFFLINE PLAYER                          ${R}"
    echo -e "${C}____________________________________________________________${R}"
    echo -e "${Y}  4 / 6  : Volume down / up              ${R}"
    echo -e "${Y}  , / .  : Seek -10 / +10 sec            ${R}"
    echo -e "${Y}  Left/Right : Seek -20 / +20 sec        ${R}"
    echo -e "${Y}  Up/Down    : Seek +120 / -120 sec      ${R}"
    echo -e "${Y}  n / b  : Next / Previous               ${R}"
    if (( TSAMPLE > 0 )); then
        echo -e "${Y}  SPACE  : Pause | s: Sample length      ${R}"
    else
        echo -e "${Y}  SPACE  : Pause | s: Shuffle            ${R}"
    fi
    echo -e "${Y}  HOME   : Restart | q: Menu              ${R}"
    echo -e "${Y}  u: Refresh playlist                    ${R}"
    # d / o: the active date sort is shown in green
    local c_d="$Y" c_o="$Y"
    [[ "$SORT_MODE" == "newest" ]] && c_d="$G"
    [[ "$SORT_MODE" == "oldest" ]] && c_o="$G"
    echo -e "${c_d}  d${Y} / ${c_o}o${Y}  : Sort ${c_d}newest${Y} / ${c_o}oldest${Y}          ${R}"
    echo -e "${Y}  g: Go to track                         ${R}"
    (( TSAMPLE > 0 )) && echo -e "${Y}  p: Play this track in full             ${R}"
    if (( TSAMPLE > 0 )); then
        echo -e "${Y}  m: Normal mode (stop sampling)         ${R}"
    else
        echo -e "${Y}  m: Sample mode                         ${R}"
    fi
    echo -e "${Y}  f: Fav -> ${PL_NAME}.m3u8${R}"
    echo -e "${C}____________________________________________________________${R}"
}

# Read last saved volume: on-disk VOL_FILE (survives quit/restart) > in-memory LAST_VOLUME > 70 default
_get_saved_volume() {
    if [[ -f "$VOL_FILE" ]]; then
        cat "$VOL_FILE"
    fi
}

# After mpv exits, find the most recently modified watch_later file, follow
# mpv's "# redirect entry" if the real data lives in another file (happens
# when the original filename is too long), and read volume= from it.
# Saves both in memory (LAST_VOLUME) and on disk (VOL_FILE).
_save_volume_from_watch_later() {
    # Pick the newest file with a single find call. A per-file loop spawns
    # several processes per file, which is very slow with hundreds of files.
    local wl_file
    wl_file=$(find "$WATCH_LATER_BASE" -maxdepth 1 -type f ! -name volume.txt \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [[ -z "$wl_file" ]] && return

    # Follow redirect entry (used when the original filename was too long)
    if [[ "$(head -1 "$wl_file" 2>/dev/null)" == "# redirect entry" ]]; then
        local target
        target=$(sed -n '2p' "$wl_file")
        [[ -n "$target" && -f "$target" ]] && wl_file="$target"
    fi

    local vol
    vol=$(grep -h "^volume=" "$wl_file" 2>/dev/null | tail -1 | cut -d'=' -f2)
    if [[ -n "$vol" ]]; then
        LAST_VOLUME="$vol"
        echo "$vol" > "$VOL_FILE"
    fi
}

# Launch mpv with the current PLAYLIST_FILE starting at given index.
# $2 = "full": sample mode is off for this run, the whole track is played
#      (resuming from the position saved when 'p' was pressed).
# Sets CUR_IDX to the playlist index of the track playing when mpv quit.
_run_mpv() {
    local start_idx="${1:-0}"
    local run_mode="${2:-normal}"

    # Sample length for this run (0 while a full track is played)
    local sample=$TSAMPLE
    [[ "$run_mode" == "full" ]] && sample=0

    local input_conf=$(mktemp)
    local fav_helper=$(mktemp)
    local state_file=$(mktemp)
    local mpl_lua=$(mktemp --suffix=.lua)   # mpv needs the .lua suffix
    _create_mpl_lua "$mpl_lua"
    # Set after all temp files exist so the trap string contains every path
    trap "rm -f '$input_conf' '$fav_helper' '$state_file' '$mpl_lua'" RETURN

    # helper run by mpv on "f": adds the given path to $FAV_PLAYLIST (no duplicates)
    cat > "$fav_helper" <<'FAVEOF'
f="$1"
[ -n "$f" ] && [ -n "$FAV_PLAYLIST" ] || exit 0
[ -f "$FAV_PLAYLIST" ] || echo "#EXTM3U" > "$FAV_PLAYLIST"
grep -Fxq -- "$f" "$FAV_PLAYLIST" || echo "$f" >> "$FAV_PLAYLIST"
FAVEOF
    _create_input_conf "$input_conf" "$fav_helper" "$run_mode"

    # Volume priority: on-disk VOL_FILE (survives full quit/restart) > in-memory LAST_VOLUME > 70 default
    local saved_vol
    saved_vol=$(_get_saved_volume)
    local vol_param="${saved_vol:-${LAST_VOLUME:-70}}"

    # Sample mode: stop every track after $sample seconds. Resume is disabled
    # so a saved position past the sample point cannot end the track at once.
    local end_opts=()
    if (( sample > 0 )); then
        end_opts=(--no-resume-playback --end="$sample")
    fi

    # Options for the Lua helper (it also draws the sample countdown)
    local full_flag="no"
    [[ "$run_mode" == "full" ]] && full_flag="yes"
    local script_opts="mpl-sample=${sample},mpl-full=${full_flag},mpl-state=${state_file}"

    # Status line: time-pos / duration (bold green) [/ yellow countdown in
    # sample mode] | volume. The "/" separators are bold white. The track
    # counter [n/total] is shown in the colored "playing" line instead.
    # In sample mode the Lua helper replaces this message with a live
    # countdown; the static sample length below is only the fallback.
    local status_msg="\${time-pos}${_WC}/${_SC}\${duration}${_MR}"
    if (( sample > 0 )); then
        status_msg+="${_WC}/${_YC}${sample}${_MR}"
    fi
    status_msg+=" | V:\${volume}%"

    clear
    _show_header
    [[ "$run_mode" == "full" ]] && echo -e "${M}  FULL TRACK - end/n/b: back to sampling${R}"

    mpv \
        --no-video \
        --audio-display=no \
        --no-input-default-bindings \
        --input-ar-delay=1000 \
        --input-ar-rate=1 \
        --volume="$vol_param" \
        --playlist="$PLAYLIST_FILE" \
        --playlist-start="$start_idx" \
        --save-position-on-quit \
        --resume-playback \
        --watch-later-directory="$WATCH_LATER_BASE" \
        --watch-later-options-remove=pause \
        --input-conf="$input_conf" \
        --term-status-msg="$status_msg" \
        --term-playing-msg="${_MC}▶ ${_SC}[\${playlist-pos-1}/\${playlist-count}]${_MC} \${filename}${_MR}" \
        --script="$mpl_lua" \
        --script-opts="$script_opts" \
        "${end_opts[@]}"

    local exit_code=$?

    # Which track was playing at exit? Falls back to the start index if the
    # Lua helper did not write the state file.
    CUR_IDX="$start_idx"
    local st
    st=$(cat "$state_file" 2>/dev/null)
    [[ "$st" =~ ^[0-9]+$ ]] && CUR_IDX="$st"

    _save_volume_from_watch_later
    return $exit_code
}

# Ask for the sample length in seconds (Enter or an invalid answer = the last
# value) and store it in TSAMPLE (active) and SAMPLE_LAST (default offered)
_ask_sample_secs() {
    local new_s
    echo -ne "${G}Sample length in seconds [${SAMPLE_LAST}]: ${R}"
    read -r new_s
    new_s=$(echo "$new_s" | tr -cd '0-9')
    if [[ -z "$new_s" ]] || (( 10#$new_s == 0 )); then
        new_s=$SAMPLE_LAST
    fi
    TSAMPLE=$((10#$new_s))
    SAMPLE_LAST=$TSAMPLE
}

# Exit codes of mpv handled here:
#   42 = u (refresh playlist), 43 = g (go to track),
#   44 = p (sample mode: play the current track in full),
#   46 = the full track started with p ended by itself,
#   47 / 48 = n / b pressed while that full track is playing,
#   49 = s (sample mode: ask for a new sample length),
#   50 = m (switch sample <-> normal for the rest of the list),
#   51 = d (sort newest first), 52 = o (sort oldest first); the same key
#        again returns to name order. Both rescan the directory and start
#        again from track 1 of the sorted list (like mpl -d / mpl -o).
_play_with_refresh() {
    local start_idx="${1:-0}"
    local run_mode="normal"   # "full" while a single track is played in full

    while true; do
        printf "%s\n" "${files[@]}" > "$PLAYLIST_FILE"
        local count_before=${#files[@]}

        _run_mpv "$start_idx" "$run_mode"
        local exit_code=$?
        local cur_idx=$CUR_IDX

        if [[ $exit_code -eq 42 || $exit_code -eq 51 || $exit_code -eq 52 ]]; then
            # d / o: switch the sort mode first, then rescan like u does
            if [[ $exit_code -eq 51 ]]; then
                if [[ "$SORT_MODE" == "newest" ]]; then SORT_MODE="name"; else SORT_MODE="newest"; fi
            elif [[ $exit_code -eq 52 ]]; then
                if [[ "$SORT_MODE" == "oldest" ]]; then SORT_MODE="name"; else SORT_MODE="oldest"; fi
            fi
            if [[ $exit_code -ne 42 ]]; then
                local sort_label="by name"
                [[ "$SORT_MODE" == "newest" ]] && sort_label="newest first"
                [[ "$SORT_MODE" == "oldest" ]] && sort_label="oldest first"
                echo -e "\n${G}Sort: ${sort_label}${R}"
            fi
            echo -e "\n${G}Refreshing playlist...${R}"

            local current_file="${files[$cur_idx]}"
            local old_count=$count_before

            if _scan_files; then
                local new_count=${#files[@]}
                local added=$((new_count - old_count))
                [[ $added -lt 0 ]] && added=0
                echo -e "${G}Files: ${old_count} -> ${new_count} (+${added} new)${R}"
            else
                echo -e "${Y}No files found - returning to menu${R}"
                sleep 1
                return 1
            fi

            local new_idx=0
            if [[ $exit_code -eq 42 ]]; then
                # u: find the current track in the refreshed list
                if [[ -n "$current_file" ]]; then
                    for i in "${!files[@]}"; do
                        if [[ "${files[$i]}" == "$current_file" ]]; then
                            new_idx=$i; break
                        fi
                    done
                fi
                echo -e "${M}Resuming: [track $((new_idx+1))/${#files[@]}] - position restored from watch_later${R}"
            else
                # d / o: start again from the first track of the sorted list
                # (a track played in full goes back to normal/sample mode)
                run_mode="normal"
                echo -e "${M}Starting at track 1/${#files[@]}${R}"
            fi
            sleep 1
            start_idx=$new_idx
            continue

        elif [[ $exit_code -eq 43 ]]; then
            # an empty or invalid answer stays on the current track
            start_idx=$cur_idx
            echo -ne "\n${G}Go to track (1-${#files[@]}): ${R}"
            read -r goto_num
            goto_num=$(echo "$goto_num" | tr -cd '0-9')
            if [[ -n "$goto_num" ]]; then
                local goto_idx=$((goto_num - 1))
                if (( goto_idx >= 0 && goto_idx < ${#files[@]} )); then
                    start_idx=$goto_idx
                    run_mode="normal"
                else
                    echo -e "${Y}No such track: $goto_num${R}"; sleep 1
                fi
            fi
            continue

        elif [[ $exit_code -eq 44 ]]; then
            # p: replay the current track in full, from the saved position
            start_idx=$cur_idx
            run_mode="full"
            continue

        elif [[ $exit_code -eq 46 || $exit_code -eq 47 ]]; then
            # full track ended (46) or n pressed (47): sample the next track
            start_idx=$((cur_idx + 1))
            run_mode="normal"
            (( start_idx >= ${#files[@]} )) && return 0
            continue

        elif [[ $exit_code -eq 48 ]]; then
            # b pressed during the full track: sample the previous track
            start_idx=$((cur_idx - 1))
            (( start_idx < 0 )) && start_idx=0
            run_mode="normal"
            continue

        elif [[ $exit_code -eq 49 ]]; then
            # s: new sample length (an empty or invalid answer keeps the old
            # one); the current track restarts with it
            start_idx=$cur_idx
            run_mode="normal"
            echo
            _ask_sample_secs
            continue

        elif [[ $exit_code -eq 50 ]]; then
            # m: switch the mode for the rest of the list; the current track
            # carries on in the new mode
            start_idx=$cur_idx
            run_mode="normal"
            echo
            if (( TSAMPLE > 0 )); then
                # sample (or full) -> normal: the track goes on in full from
                # the position saved at quit, and so do the following tracks
                TSAMPLE=0
                echo -e "${G}Mode: normal${R}"; sleep 0.5
            else
                # normal -> sample: the track restarts as a sample
                _ask_sample_secs
            fi
            continue

        else
            return 0
        fi
    done
}

# One menu row: the left cell is padded to a fixed width so the "|" separators
# line up. Cells are short enough that a row stays under 30 columns (narrow
# Termux screens).
# $3 / $4 = optional colors of the left / right cell (default: yellow). They go
# into the printf format (not into the arguments) so the \033 codes are expanded.
_menu_row() {
    local cl="${3:-$Y}" cr="${4:-$Y}"
    if [[ -n "$2" ]]; then
        printf "${cl}  %-13s${R}| ${cr}%s${R}\n" "$1" "$2"
    else
        printf "${cl}  %s${R}\n" "$1"
    fi
}

# === DRAW MENU ===
_draw_menu() {
    clear

    # Separator fits the terminal: at most 60 chars, one less than the width
    # on narrow screens so it never wraps onto a second line
    local cols sep
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=60
    (( cols = cols > 61 ? 60 : cols - 1 ))
    (( cols < 10 )) && cols=10
    sep=$(printf '%*s' "$cols" '' | tr ' ' '=')

    echo -e "${C}${sep}${R}"
    local header="${FULL_DIR}"
    [[ -n "$FILTER" ]] && header+=" ${Y}[filter: ${FILTER}]${C}"
    (( TIME_FILTER > 0 )) && header+=" ${M}[time: ${TIME_FILTER_MODE}${TIME_FILTER}min]${C}"
    [[ "$SORT_MODE" == "newest" ]] && header+=" ${G}[sort: newest]${C}"
    [[ "$SORT_MODE" == "oldest" ]] && header+=" ${G}[sort: oldest]${C}"
    (( TSAMPLE > 0 )) && header+=" ${Y}[sample: ${TSAMPLE}s]${C}"
    echo -e "${C}  ${header}${R}"
    echo -e "${C}${sep}${R}"

    for i in "${!files[@]}"; do
        local fname
        fname=$(basename "${files[$i]}" | cut -c1-56)
        [[ "$fname" == *.part ]] && fname="[DL] $fname"
        printf " %3d) %s\n" "$((i+1))" "$fname"
    done

    echo -e "${C}${sep}${R}"
    # n / o cells: the active date sort is shown in green
    local c_new="$Y" c_old="$Y"
    [[ "$SORT_MODE" == "newest" ]] && c_new="$G"
    [[ "$SORT_MODE" == "oldest" ]] && c_old="$G"
    _menu_row "a = play all" "s = shuffle"
    _menu_row "u = refresh"  "t = duration"
    _menu_row "/ = search"   "g = go to #"
    _menu_row "n = newest"   "o = oldest" "$c_new" "$c_old"
    _menu_row "m = mode"     "q = quit"
    echo -ne "  Choice: "
}

# === TIME FILTER HANDLER ===
_handle_time_filter() {
    echo -e "\r\033[K"
    echo -ne "${G}Duration filter (+min / -min / min, 0=off): ${R}"
    read -r tmin
    tmin=$(echo "$tmin" | tr -d ' ')
    if [[ "$tmin" == "0" ]]; then
        TIME_FILTER=0
        TIME_FILTER_MODE=""
        _apply_filter
        echo -e "${G}Time filter cleared${R}"; sleep 0.5
    elif [[ "$tmin" =~ ^[+-]?[0-9]+$ ]]; then
        if [[ "$tmin" =~ ^[+-] ]]; then
            TIME_FILTER=${tmin:1}
            TIME_FILTER_MODE=${tmin:0:1}
        else
            TIME_FILTER=$tmin
            TIME_FILTER_MODE="+"
        fi
        if ! _apply_filter; then
            echo -e "${Y}No files matching duration filter${R}"
            TIME_FILTER=0
            TIME_FILTER_MODE=""
            _apply_filter
            sleep 1
        else
            echo -e "${G}Found ${#files[@]} files${R}"; sleep 0.5
        fi
    fi
}

# === MODE HANDLER ===
# m in the menu: 1 = normal (full tracks), 2 = sample (first N seconds of each
# track; asks for the length). Either choice starts playing at once, from the
# first track. The active sample length is kept in TSAMPLE (0 = normal mode);
# the last chosen value stays in SAMPLE_LAST and is offered as the default.
_handle_mode() {
    local mode_key swallow
    echo -e "\r\033[K"
    echo -e "${G}Mode:${R}  ${Y}1${R} = normal   ${Y}2${R} = sample"
    echo -ne "${G}Choice (1/2): ${R}"
    read -r -n 1 mode_key
    echo
    case "$mode_key" in
        1)
            TSAMPLE=0
            # swallow an Enter typed after the 1 (mpv would take it as "next")
            read -r -t 0.4 -n 1 swallow
            # start playing at once from the first track (like 'a')
            _play_with_refresh 0
            ;;
        2)
            _ask_sample_secs
            # start playing at once from the first track (like 'a')
            _play_with_refresh 0
            ;;
    esac
}

# === STARTUP ===
_scan_files || { echo -e "${Y}No media files found in: $FULL_DIR${R}"; exit 1; }

if [[ "$MODE" == "playlist" ]]; then
    # -n N: start at track number N of the list (1-based, as in the menu)
    START_IDX=0
    if (( START_NUM > 0 )); then
        if (( START_NUM > ${#files[@]} )); then
            echo -e "${Y}No track ${START_NUM} - the list has ${#files[@]} tracks${R}"
            exit 1
        fi
        START_IDX=$((START_NUM - 1))
    fi
    _play_with_refresh "$START_IDX"
    exit 0
fi

if [[ "$MODE" == "filter" ]]; then
    echo -e "${C}Filter: ${Y}${FILTER}${C} - found ${G}${#files[@]}${C} files${R}"
    sleep 0.5
fi

# === MAIN MENU LOOP ===
while :; do
    _draw_menu

    read -s -r -n 1 key

    case "$key" in
        a|A)
            _play_with_refresh 0
            ;;
        s|S)
            mapfile -t files < <(printf "%s\n" "${files[@]}" | shuf)
            _play_with_refresh 0
            ;;
        u|U)
            echo -e "\n${G}Refreshing file list...${R}"
            if _scan_files; then
                echo -e "${G}Found ${#files[@]} files${R}"
                sleep 0.5
            else
                echo -e "${Y}No files found in directory${R}"
                sleep 1
            fi
            ;;
        t|T)
            _handle_time_filter
            ;;
        n|N)
            # Toggle: name <-> newest (pressing 'n' again returns to name)
            if [[ "$SORT_MODE" == "newest" ]]; then
                SORT_MODE="name"
            else
                SORT_MODE="newest"
            fi
            if _scan_files; then
                echo -e "${G}Sort: $( [[ "$SORT_MODE" == "newest" ]] && echo "newest first" || echo "by name" )${R}"
                sleep 0.5
            else
                echo -e "${Y}No files found${R}"
                sleep 1
            fi
            ;;
        o|O)
            # Toggle: name <-> oldest (pressing 'o' again returns to name)
            if [[ "$SORT_MODE" == "oldest" ]]; then
                SORT_MODE="name"
            else
                SORT_MODE="oldest"
            fi
            if _scan_files; then
                echo -e "${G}Sort: $( [[ "$SORT_MODE" == "oldest" ]] && echo "oldest first" || echo "by name" )${R}"
                sleep 0.5
            else
                echo -e "${Y}No files found${R}"
                sleep 1
            fi
            ;;
        m|M)
            _handle_mode
            ;;
        q|Q)
            clear; exit 0
            ;;
        g|G)
            echo -ne "\n${G}Go to track (1-${#files[@]}): ${R}"
            read -r goto_num
            goto_num=$(echo "$goto_num" | tr -cd '0-9')
            if [[ -n "$goto_num" ]]; then
                goto_idx=$((goto_num - 1))
                if (( goto_idx >= 0 && goto_idx < ${#files[@]} )); then
                    _play_with_refresh "$goto_idx"
                else
                    echo -e "${Y}No such track: $goto_num${R}"; sleep 1
                fi
            fi
            ;;
        /)
            echo -e "\r\033[K"
            echo -ne "${G}Search: ${R}"
            read -r keyword
            if [[ -n "$keyword" ]]; then
                FILTER="*${keyword}*"
                if ! _apply_filter; then
                    echo -e "${Y}No files matching: ${keyword}${R}"
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
                fi
            fi
            ;;
    esac
done
