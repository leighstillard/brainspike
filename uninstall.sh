#!/usr/bin/env bash
# brainspike uninstaller
# Removes ~/.claude/hooks/brainspike*.sh and unregisters from settings.

set -euo pipefail

HOOK_FILE="$HOME/.claude/hooks/brainspike.sh"
PRETOOL_HOOK_FILE="$HOME/.claude/hooks/brainspike-pretool.sh"
SETTINGS_FILE=".claude/settings.local.json"

while [ $# -gt 0 ]; do
    case "$1" in
        --hook) HOOK_FILE="$2"; shift 2 ;;
        --pretool-hook) PRETOOL_HOOK_FILE="$2"; shift 2 ;;
        --settings) SETTINGS_FILE="$2"; shift 2 ;;
        --global) SETTINGS_FILE="$HOME/.claude/settings.json"; shift ;;
        -h|--help)
            sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -f "$HOOK_FILE" ]; then
    rm -f "$HOOK_FILE"
    echo "==> Removed: $HOOK_FILE"
else
    echo "==> No hook at: $HOOK_FILE"
fi

if [ -f "$PRETOOL_HOOK_FILE" ]; then
    rm -f "$PRETOOL_HOOK_FILE"
    echo "==> Removed: $PRETOOL_HOOK_FILE"
else
    echo "==> No PreToolUse hook at: $PRETOOL_HOOK_FILE"
fi

if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
    if jq empty "$SETTINGS_FILE" 2>/dev/null; then
        tmp="$(mktemp)"
        HOOK_PATH="$HOOK_FILE" PRETOOL_HOOK_PATH="$PRETOOL_HOOK_FILE" jq '
            if .hooks.UserPromptSubmit then
                .hooks.UserPromptSubmit |= [
                    .[] | (.hooks |= map(select(.command != env.HOOK_PATH))) | select(.hooks | length > 0)
                ]
            else . end |
            if .hooks.PreToolUse then
                .hooks.PreToolUse |= [
                    .[] | (.hooks |= map(select(.command != env.PRETOOL_HOOK_PATH))) | select(.hooks | length > 0)
                ]
            else . end
        ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        echo "==> Unregistered from: $SETTINGS_FILE"
    fi
fi

echo "Done."
