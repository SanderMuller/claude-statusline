#!/usr/bin/env bash
# Installer for claude-statusline.
# https://github.com/sandermuller/claude-statusline
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sandermuller/claude-statusline/main/install.sh | bash
# or, from a clone:
#   ./install.sh
#
# It downloads statusline.sh into your Claude Code config dir and merges the
# `statusLine` key into settings.json WITHOUT touching your other settings
# (a timestamped backup is made first).

set -euo pipefail

REPO="sandermuller/claude-statusline"
BRANCH="main"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}/statusline.sh"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

info() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required. Install it first — macOS: 'brew install jq', Debian/Ubuntu: 'sudo apt install jq'."

mkdir -p "$CLAUDE_DIR"

# Resolve the script source: prefer a local copy (running from a clone),
# otherwise download from the repo.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
tmp_script="$(mktemp)"
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/statusline.sh" ]]; then
    info "Using local statusline.sh"
    cp "$SELF_DIR/statusline.sh" "$tmp_script"
else
    info "Downloading statusline.sh from $REPO"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW" -o "$tmp_script"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_script" "$RAW"
    else
        die "Need curl or wget to download the script."
    fi
fi
[[ -s "$tmp_script" ]] || die "Downloaded script is empty."

mv "$tmp_script" "$DEST"
chmod +x "$DEST"
info "Installed script -> $DEST"

CMD="bash $DEST"

if [[ -f "$SETTINGS" ]]; then
    jq empty "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON. Fix or move it aside, then re-run."
    backup="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup"
    info "Backed up settings -> $backup"
    tmp_settings="$(mktemp)"
    jq --arg cmd "$CMD" '.statusLine = {type:"command", command:$cmd}' "$SETTINGS" > "$tmp_settings"
    mv "$tmp_settings" "$SETTINGS"
    info "Merged statusLine into $SETTINGS"
else
    jq -n --arg cmd "$CMD" '{statusLine:{type:"command", command:$cmd}}' > "$SETTINGS"
    info "Created $SETTINGS"
fi

printf '\n\033[1;32m✓ claude-statusline installed.\033[0m Interact with Claude Code to see it.\n'
printf '  Customize the repo-folder prefix:  export CLAUDE_STATUSLINE_PROJECT_ROOT="$HOME/code"\n'
printf '  Uninstall:  curl -fsSL https://raw.githubusercontent.com/%s/%s/uninstall.sh | bash\n' "$REPO" "$BRANCH"
