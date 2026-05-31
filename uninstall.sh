#!/usr/bin/env bash
# Uninstaller for claude-statusline.
# Removes the `statusLine` key from settings.json (backing it up first) and
# deletes the installed script. Your other settings are left untouched.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

info() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required."

if [[ -f "$SETTINGS" ]]; then
    jq empty "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON."
    backup="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup"
    info "Backed up settings -> $backup"
    tmp="$(mktemp)"
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    info "Removed statusLine from $SETTINGS"
fi

if [[ -f "$DEST" ]]; then
    rm -f "$DEST"
    info "Removed $DEST"
fi

printf '\n\033[1;32m✓ claude-statusline removed.\033[0m\n'
