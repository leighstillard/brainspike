#!/usr/bin/env bash
# brainspike probe: auto-memory
# Searches Claude Code's per-project auto-memory markdown files.

PROBE_NAME="auto-memory"
PROBE_DESCRIPTION="Claude Code per-project memory markdown files"
PROBE_ROOT="${CLAUDE_AUTO_MEMORY_ROOT:-$HOME/.claude/projects}"

probe_detect() {
    [ -d "$PROBE_ROOT" ]
}

probe_test_query() {
    # Need at least one memory directory with a markdown file
    find "$PROBE_ROOT" -maxdepth 3 -path '*/memory/*.md' -print -quit 2>/dev/null | grep -q . || return 1
    command -v grep >/dev/null 2>&1
}

probe_query() {
    local query="$1"
    # Build a regex of useful keywords from the prompt
    local terms
    terms="$(printf '%s\n' "$query" \
        | tr '[:upper:]' '[:lower:]' \
        | grep -oE '[a-z][a-z0-9_-]{3,}' \
        | grep -vE '^(that|this|with|from|what|when|where|which|were|have|does|they|there|then|also|into|like|want|need|please|make|tell|just|about|some|find|show|look|using|could|would|should)$' \
        | sort -u \
        | head -8 \
        | paste -sd '|' -)"

    [ -z "$terms" ] && return 0

    timeout 3 grep -rliE "($terms)" "$PROBE_ROOT" \
        --include='*.md' \
        --max-count=1 \
        2>/dev/null \
        | grep '/memory/' \
        | head -5 \
        | while IFS= read -r path; do
            local project memname title
            project="${path#$PROBE_ROOT/}"
            project="${project%%/memory/*}"
            # Strip leading "-home-<user>-" and "workspace-" so projects show as
            # "cc-connect" instead of "-home-leigh-workspace-cc-connect".
            project="$(printf '%s' "$project" | sed -E 's|^-home-[^-]+-||; s|^workspace-||')"
            memname="$(basename "$path" .md)"
            # First non-frontmatter heading or first non-empty line
            title="$(awk '
                /^---$/ { if (in_fm) { in_fm=0; next } else { in_fm=1; next } }
                in_fm { next }
                /^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }
            ' "$path" 2>/dev/null)"
            if [ -z "$title" ]; then
                title="$(awk '!/^---$/ && !/^[[:space:]]*$/ && !/^#+[[:space:]]*$/ { sub(/^#+[[:space:]]*/, ""); print; exit }' "$path" 2>/dev/null)"
            fi
            title="${title:-$memname}"
            # Trim
            title="$(printf '%s' "$title" | head -c 80)"
            echo "  - \"$title\" ($project/$memname)"
        done
}

probe_breadcrumb() {
    echo "grep -rli '<query>' $PROBE_ROOT/*/memory --include='*.md'"
}
