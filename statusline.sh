#!/usr/bin/env bash
# claude-statusline — a two-row, colored status line for Claude Code.
# https://github.com/sandermuller/claude-statusline
#
#   Row 1: PWD: <dir> · <model> · ctx <bar> NN% · skills N · wf M
#   Row 2: 5h <bar> NN% resets <t> · 7d <bar> NN% resets <t>
#
# Reads the official statusline JSON on stdin; the skills/workflow counts are
# read from the session transcript. No network calls, no external services.
# Requires `jq`. Colors need a 256-color, ANSI-capable terminal.

# ---- Optional config -------------------------------------------------------
# Paths under PROJECT_ROOT are shown relative to it
# (e.g. "~/Documents/GitHub/app" -> "app"). Set to "" to disable and just
# collapse $HOME to "~".
PROJECT_ROOT="${CLAUDE_STATUSLINE_PROJECT_ROOT:-$HOME/Documents/GitHub}"
BAR_WIDTH="${CLAUDE_STATUSLINE_BAR_WIDTH:-12}"
# ----------------------------------------------------------------------------

input=$(cat)
jqf() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
round() { printf '%.0f' "$1" 2>/dev/null; }

# Format a unix epoch with a strftime spec, on macOS (BSD date) or Linux (GNU).
fmt_time() {
    local epoch=${1%.*} spec=$2
    date -r "$epoch" "$spec" 2>/dev/null || date -d "@$epoch" "$spec" 2>/dev/null
}

# ---- Palette (ANSI) --------------------------------------------------------
e=$'\033'
RST="${e}[0m"
VAL="${e}[1;97m"            # bright white bold — primary values (%, counts)
LBL="${e}[38;5;111m"        # soft light-blue — labels
TIM="${e}[38;5;253m"        # near-white — reset times
DIR="${e}[1;36m"            # bold cyan — directory
MDL="${e}[1;95m"            # bold magenta — model
SEP="${e}[38;5;245m·${RST}" # separator dot

# Colored progress bar (green < 50, yellow 50-79, red >= 80).
bar() {
    local p=${1:-0} width=$BAR_WIDTH filled empty out="" i color
    p=${p%.*}
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    filled=$(( (p * width + 50) / 100 ))
    (( filled > width )) && filled=$width
    empty=$(( width - filled ))
    if   (( p >= 80 )); then color="${e}[1;31m"   # red
    elif (( p >= 50 )); then color="${e}[1;33m"   # yellow
    else color="${e}[1;32m"                        # green
    fi
    for (( i = 0; i < filled; i++ )); do out+="█"; done
    for (( i = 0; i < empty;  i++ )); do out+="░"; done
    printf '%s%s%s' "$color" "$out" "$RST"
}

# ---- Row 1: directory · model · context · skills · workflows ---------------
row1=()

dir=$(jqf '.workspace.current_dir')
if [[ -n "$dir" ]]; then
    short="$dir"
    if [[ -n "$PROJECT_ROOT" && "$dir" == "$PROJECT_ROOT"/* ]]; then
        short="${dir#"$PROJECT_ROOT"/}"
    elif [[ "$dir" == "$HOME" || "$dir" == "$HOME"/* ]]; then
        short="~${dir#"$HOME"}"
    fi
    row1+=("${LBL}PWD:${RST} ${DIR}${short}${RST}")
fi

model=$(jqf '.model.display_name')
if [[ -n "$model" ]]; then
    row1+=("${MDL}${model}${RST}")
fi

ctx=$(jqf '.context_window.used_percentage')
if [[ -n "$ctx" ]]; then
    p=$(round "$ctx")
    row1+=("${LBL}ctx${RST} $(bar "$p") ${VAL}${p}%${RST}")
fi

transcript=$(jqf '.transcript_path')
if [[ -n "$transcript" && -f "$transcript" ]]; then
    skills=$(grep -c '"name":"Skill"' "$transcript" 2>/dev/null)
    wf=$(grep -c '"name":"Workflow"' "$transcript" 2>/dev/null)
    row1+=("${LBL}skills${RST} ${VAL}${skills:-0}${RST}")
    row1+=("${LBL}wf${RST} ${VAL}${wf:-0}${RST}")
fi

# ---- Row 2: 5h / 7d rate-limit usage with bars and reset times -------------
row2=()

h5=$(jqf '.rate_limits.five_hour.used_percentage')
if [[ -n "$h5" ]]; then
    p=$(round "$h5")
    seg="${LBL}5h${RST} $(bar "$p") ${VAL}${p}%${RST}"
    r5=$(jqf '.rate_limits.five_hour.resets_at')
    if [[ -n "$r5" ]]; then
        t=$(fmt_time "$r5" +%H:%M)
        [[ -n "$t" ]] && seg="$seg ${LBL}resets${RST} ${TIM}${t}${RST}"
    fi
    row2+=("$seg")
fi

d7=$(jqf '.rate_limits.seven_day.used_percentage')
if [[ -n "$d7" ]]; then
    p=$(round "$d7")
    seg="${LBL}7d${RST} $(bar "$p") ${VAL}${p}%${RST}"
    r7=$(jqf '.rate_limits.seven_day.resets_at')
    if [[ -n "$r7" ]]; then
        t=$(fmt_time "$r7" "+%a %H:%M")
        [[ -n "$t" ]] && seg="$seg ${LBL}resets${RST} ${TIM}${t}${RST}"
    fi
    row2+=("$seg")
fi

# ---- Join with a colored separator + print ---------------------------------
join() {
    local out="" s
    for s in "$@"; do
        if [[ -z "$out" ]]; then out="$s"; else out="$out ${SEP} $s"; fi
    done
    printf '%s' "$out"
}

line1=$(join "${row1[@]}")
line2=$(join "${row2[@]}")

printf '%s' "$line1"
if [[ -n "$line2" ]]; then
    printf '\n%s' "$line2"
fi
