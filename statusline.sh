#!/usr/bin/env bash
# claude-statusline — a responsive, colored status line for Claude Code.
# https://github.com/sandermuller/claude-statusline
#
#   PWD: <dir> · git <branch> · <model> · ctx <bar> NN%
#   5h <bar> NN% ↻ <t> · 7d <bar> NN% ↻ <t> · peer <session>
#
# Segments are packed into as many rows as the terminal needs, with a fixed
# break between the working-context group and the rate-limit group so the two
# never share a row. Width comes from $COLUMNS, which Claude Code exports to the
# status-line process.
#
# Reads the official statusline JSON on stdin; the branch comes from git and the
# peer session name from the Claude Code session registry. No network calls, no
# external services.
# Requires `jq`. Colors need a 256-color, ANSI-capable terminal.

# ---- Optional config -------------------------------------------------------
# Paths under PROJECT_ROOT are shown relative to it
# (e.g. "~/Documents/GitHub/app" -> "app"). Set to "" to disable and just
# collapse $HOME to "~".
PROJECT_ROOT="${CLAUDE_STATUSLINE_PROJECT_ROOT-$HOME/Documents/GitHub}"
BAR_WIDTH="${CLAUDE_STATUSLINE_BAR_WIDTH:-12}"
# Optional hard ceilings for the variable-length fields. 0 means "no ceiling":
# the field is shown in full and only elided if it cannot fit a row on its own.
BRANCH_MAX="${CLAUDE_STATUSLINE_BRANCH_MAX:-0}"
DIR_MAX="${CLAUDE_STATUSLINE_DIR_MAX:-0}"
PEER_MAX="${CLAUDE_STATUSLINE_PEER_MAX:-0}"
# Where Claude Code keeps its session registry (used for the peer session name).
SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
# Terminal width. Claude Code exports COLUMNS; GUTTER is held back so a full row
# never touches the right edge. MAX_ROWS caps the number of rows, at the cost of
# letting them overflow and be clipped; 0 (the default) never clips, and lets
# the line grow instead. Content only reaches a third row when it has to.
WIDTH="${CLAUDE_STATUSLINE_WIDTH:-${COLUMNS:-80}}"
# Claude Code renders the status line inside a padded container, so the usable
# width is narrower than $COLUMNS. Measured at 4 columns: with COLUMNS=80 a row
# is clipped after 75 characters plus an ellipsis.
GUTTER="${CLAUDE_STATUSLINE_GUTTER:-4}"
MAX_ROWS="${CLAUDE_STATUSLINE_MAX_ROWS:-0}"
# ----------------------------------------------------------------------------

input=$(cat)
jqf() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
round() { printf '%.0f' "$1" 2>/dev/null; }

# Elide a string to $2 columns, dropping the tail. Used where the head carries
# the meaning (a branch name, a project path).
elide_tail() {
    local v=$1 max=$2
    if (( max > 0 && ${#v} > max )); then v="${v:0:$(( max - 1 ))}…"; fi
    printf '%s' "$v"
}

# Elide to $2 columns, dropping the head. Used for session names, where the
# suffix is the part that tells two sessions apart (…-src-8d vs …-src-e7).
elide_head() {
    local v=$1 max=$2
    if (( max > 0 && ${#v} > max )); then v="…${v: -$(( max - 1 ))}"; fi
    printf '%s' "$v"
}

# Format a unix epoch with a strftime spec, on macOS (BSD date) or Linux (GNU).
fmt_time() {
    local epoch=${1%.*} spec=$2
    date -r "$epoch" "$spec" 2>/dev/null || date -d "@$epoch" "$spec" 2>/dev/null
}

# Current git branch for a directory (short SHA when detached), or nothing.
git_branch() {
    local d=$1
    [[ -n "$d" && -d "$d" ]] || return
    GIT_OPTIONAL_LOCKS=0 git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null \
        || GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse --short HEAD 2>/dev/null
}

# The name other Claude Code sessions use to message this one. Looked up in the
# session registry by session id; the newest matching record wins, since a
# resumed or crashed session can leave a stale entry behind.
peer_name() {
    local sid=$1 files=()
    [[ -n "$sid" && -d "$SESSIONS_DIR" ]] || return
    files=("$SESSIONS_DIR"/*.json)
    [[ -e "${files[0]}" ]] || return
    jq -rn --arg sid "$sid" \
        '[inputs | select(.sessionId == $sid)]
         | sort_by(.updatedAt // 0) | last | .name // empty' \
        "${files[@]}" 2>/dev/null
}

# ---- Palette (ANSI) --------------------------------------------------------
e=$'\033'
RST="${e}[0m"
VAL="${e}[1;97m"            # bright white bold — primary values (%, counts)
LBL="${e}[38;5;111m"        # soft light-blue — labels
TIM="${e}[38;5;253m"        # near-white — reset times
DIR="${e}[1;36m"            # bold cyan — directory
MDL="${e}[1;95m"            # bold magenta — model
ARROW="${e}[38;5;245m→${RST}"  # subfolder separator inside a repo
GIT="${e}[1;32m"            # bold green — git branch
PEE="${e}[1;33m"            # bold yellow — peer session name
TRK="${e}[38;5;240m"        # dim grey — unfilled part of a bar
SEP="${e}[38;5;245m·${RST}" # separator dot

# Colored progress bar (green < 50, yellow 50-79, red >= 80).
# Drawn as a rule rather than a block: the filled part is a heavy line in the
# usage color, the rest a light line in grey. Low visual weight at any width.
bar() {
    local p=${1:-0} width=$BAR_WIDTH filled empty out="" i color
    p=${p%.*}
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    filled=$(( (p * width + 50) / 100 ))
    (( filled > width )) && filled=$width
    # Never round a non-zero percentage away to an empty bar.
    (( p > 0 && filled == 0 )) && filled=1
    empty=$(( width - filled ))
    if   (( p >= 80 )); then color="${e}[1;31m"   # red
    elif (( p >= 50 )); then color="${e}[1;33m"   # yellow
    else color="${e}[1;32m"                        # green
    fi
    for (( i = 0; i < filled; i++ )); do out+="━"; done
    out="${color}${out}${RST}${TRK}"
    for (( i = 0; i < empty; i++ )); do out+="─"; done
    printf '%s%s' "$out" "$RST"
}

# ---- Layout width ----------------------------------------------------------
usable=$(( WIDTH - GUTTER ))
(( usable < 20 )) && usable=20

# Columns a variable-length field may occupy. Packing already moves a segment to
# its own row when it does not fit beside its neighbours, so a field only has to
# be elided when its whole segment would overflow a row by itself. $2 is the
# segment's fixed overhead (label, spaces). A user-set ceiling tightens it.
cap() {
    local user=$1 overhead=$2 c
    c=$(( usable - overhead ))
    (( c < 8 )) && c=8
    (( user > 0 && user < c )) && c=$user
    printf '%s' "$c"
}

# ---- Segments --------------------------------------------------------------
# Each segment is pushed with its display width in columns, so the wrapper can
# measure rows without parsing escape codes back out of the rendered string.
seg_text=()
seg_w=()
seg_brk=()
_brk=0
# Force the next segment onto a new row, whatever the width allows.
brk() { _brk=1; }
add_seg() { seg_text+=("$1"); seg_w+=("$2"); seg_brk+=("$_brk"); _brk=0; }

dir=$(jqf '.workspace.current_dir')
if [[ -n "$dir" ]]; then
    rel="${dir#"$PROJECT_ROOT"/}"
    rel="${rel%/}"                       # tolerate a trailing slash on dir
    rel=$(printf '%s' "$rel" | tr -s /)  # collapse repeated // into /
    rel="${rel#/}"                       # drop any leading slash
    if [[ -n "$PROJECT_ROOT" && "$dir" == "$PROJECT_ROOT"/* && -n "$rel" ]]; then
        # Under PROJECT_ROOT: show "repo" or "repo → sub/path".
        repo="${rel%%/*}"                # first segment = repo
        sub="${rel#"$repo"}"             # remainder, leading "/" kept
        sub="${sub#/}"                   # strip leading "/"
        if [[ -n "$sub" ]]; then
            # The repo name is the anchor, so it is kept whole and the subpath
            # gives way first — from its head, since the folder you are in is
            # the deep end.
            sub=$(elide_head "$sub" "$(cap "$DIR_MAX" $(( 5 + ${#repo} + 3 )))")
            add_seg "${LBL}PWD:${RST} ${DIR}${repo}${RST} ${ARROW} ${DIR}${sub}${RST}" \
                    $(( 5 + ${#repo} + 3 + ${#sub} ))
        else
            repo=$(elide_tail "$repo" "$(cap "$DIR_MAX" 5)")
            add_seg "${LBL}PWD:${RST} ${DIR}${repo}${RST}" $(( 5 + ${#repo} ))
        fi
    else
        short="$dir"
        if [[ "$dir" == "$HOME" || "$dir" == "$HOME"/* ]]; then
            short="~${dir#"$HOME"}"
        fi
        # A bare path is elided from the head: the tail says where you are.
        short=$(elide_head "$short" "$(cap "$DIR_MAX" 5)")
        add_seg "${LBL}PWD:${RST} ${DIR}${short}${RST}" $(( 5 + ${#short} ))
    fi
fi

branch=$(git_branch "$dir")
if [[ -n "$branch" ]]; then
    branch=$(elide_tail "$branch" "$(cap "$BRANCH_MAX" 4)")
    add_seg "${LBL}git${RST} ${GIT}${branch}${RST}" $(( 4 + ${#branch} ))
fi

model=$(jqf '.model.display_name')
if [[ -n "$model" ]]; then
    # "Opus 5 (1M context)" -> "Opus 5 1M": the parenthetical costs 10 columns
    # and says nothing the bare qualifier doesn't.
    if [[ "$model" =~ ^(.*)\ \((.*)\ context\)$ ]]; then
        model="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    fi
    add_seg "${MDL}${model}${RST}" "${#model}"
fi

ctx=$(jqf '.context_window.used_percentage')
if [[ -n "$ctx" ]]; then
    p=$(round "$ctx")
    add_seg "${LBL}ctx${RST} $(bar "$p") ${VAL}${p}%${RST}" \
            $(( 4 + BAR_WIDTH + 2 + ${#p} ))
fi

# 5h / 7d rate-limit windows. "↻" marks the reset time.
rate_seg() {
    local label=$1 pctpath=$2 respath=$3 spec=$4 pct p seg w t r
    pct=$(jqf "$pctpath")
    [[ -n "$pct" ]] || return
    p=$(round "$pct")
    seg="${LBL}${label}${RST} $(bar "$p") ${VAL}${p}%${RST}"
    w=$(( ${#label} + 1 + BAR_WIDTH + 2 + ${#p} ))
    r=$(jqf "$respath")
    if [[ -n "$r" ]]; then
        t=$(fmt_time "$r" "$spec")
        if [[ -n "$t" ]]; then
            seg="$seg ${LBL}↻${RST} ${TIM}${t}${RST}"
            w=$(( w + 3 + ${#t} ))
        fi
    fi
    add_seg "$seg" "$w"
}

# The rate-limit windows start their own row. They are a different kind of
# reading from the working-context segments above, and letting the packer merge
# the two whenever a wide terminal has room makes the line jump around on every
# resize. Row 1 is where you are and what you are using; row 2 is your budget.
before=${#seg_text[@]}
brk
rate_seg 5h '.rate_limits.five_hour.used_percentage' \
             '.rate_limits.five_hour.resets_at' +%H:%M
rate_seg 7d '.rate_limits.seven_day.used_percentage' \
             '.rate_limits.seven_day.resets_at' "+%a %H:%M"
# On API-key billing there are no rate limits; drop the break so the following
# segment is not stranded on a row of its own.
(( ${#seg_text[@]} == before )) && _brk=0

# The session id is on the JSON; fall back to the transcript filename, which is
# named after it.
sid=$(jqf '.session_id')
if [[ -z "$sid" ]]; then
    transcript=$(jqf '.transcript_path')
    [[ -n "$transcript" ]] && sid=$(basename "$transcript" .jsonl)
fi
peer=$(peer_name "$sid")
if [[ -n "$peer" ]]; then
    peer=$(elide_head "$peer" "$(cap "$PEER_MAX" 5)")
    add_seg "${LBL}peer${RST} ${PEE}${peer}${RST}" $(( 5 + ${#peer} ))
fi

# ---- Wrap segments into rows -----------------------------------------------
# Two passes. The first packs greedily against the full width, which yields the
# fewest rows possible for this segment order. The second re-packs against an
# even share of that row count, so three rows come out balanced rather than
# "full, full, one lonely segment". The second pass is kept only if it did not
# cost an extra row.
n=${#seg_text[@]}

# Pack into rows against a target width; sets `rows` and `row_w`.
pack() {
    local target=$1 i w cur="" curw=0
    rows=()
    row_w=()
    for (( i = 0; i < n; i++ )); do
        w=${seg_w[i]}
        if [[ -z "$cur" ]]; then
            cur="${seg_text[i]}"; curw=$w
        elif (( seg_brk[i] )); then
            rows+=("$cur"); row_w+=("$curw")
            cur="${seg_text[i]}"; curw=$w
        elif (( curw + 3 + w <= target )); then
            cur="$cur ${SEP} ${seg_text[i]}"; curw=$(( curw + 3 + w ))
        else
            rows+=("$cur"); row_w+=("$curw")
            cur="${seg_text[i]}"; curw=$w
        fi
    done
    [[ -n "$cur" ]] && { rows+=("$cur"); row_w+=("$curw"); }
}

if (( n > 0 )); then
    pack "$usable"
    min_rows=${#rows[@]}

    # Cap the row count: widen the target until the rows fit in MAX_ROWS, letting
    # them overflow (Claude Code clips) rather than printing a tall block. An
    # even share is only a lower bound, so step up until the cap is met.
    if (( MAX_ROWS > 0 && min_rows > MAX_ROWS )); then
        total=0
        for (( i = 0; i < n; i++ )); do total=$(( total + seg_w[i] + 3 )); done
        target=$(( (total - 3 + MAX_ROWS - 1) / MAX_ROWS ))
        while (( target < total )); do
            pack "$target"
            (( ${#rows[@]} <= MAX_ROWS )) && break
            target=$(( target + 4 ))
        done
    elif (( min_rows > 1 )); then
        total=0
        for (( i = 0; i < n; i++ )); do total=$(( total + seg_w[i] + 3 )); done
        greedy=("${rows[@]}")
        pack $(( (total - 3 + min_rows - 1) / min_rows ))
        # Balancing must not cost a row, and must not overflow the terminal.
        over=0
        for w in "${row_w[@]}"; do (( w > usable )) && over=1; done
        if (( ${#rows[@]} != min_rows || over )); then rows=("${greedy[@]}"); fi
    fi

    printf '%s' "${rows[0]}"
    for (( i = 1; i < ${#rows[@]}; i++ )); do printf '\n%s' "${rows[i]}"; done
fi
