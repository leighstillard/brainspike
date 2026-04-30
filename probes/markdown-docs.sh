#!/usr/bin/env bash
# brainspike probe: markdown-docs
# Generic search of a local docs/ tree (markdown files in CWD).

PROBE_NAME="markdown-docs"
PROBE_DESCRIPTION="local markdown documentation tree"
PROBE_ROOTS="${BRAINSPIKE_DOCS_ROOTS:-docs doc Docs documentation}"

probe_detect() {
    local root
    for root in $PROBE_ROOTS; do
        [ -d "$root" ] && return 0
    done
    return 1
}

probe_test_query() {
    local root
    for root in $PROBE_ROOTS; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth 6 -name '*.md' -print -quit 2>/dev/null | grep -q . && return 0
    done
    return 1
}

probe_query() {
    local query="$1"
    local terms
    terms="$(printf '%s\n' "$query" \
        | tr '[:upper:]' '[:lower:]' \
        | grep -oE '[a-z][a-z0-9_-]{3,}' \
        | grep -vE '^(that|this|with|from|what|when|where|which|were|have|does|they|there|then|also|into|like|want|need|please|make|tell|just|about|some|find|show|look|using|could|would|should)$' \
        | sort -u \
        | head -8 \
        | paste -sd '|' -)"

    [ -z "$terms" ] && return 0

    local root active=""
    for root in $PROBE_ROOTS; do
        [ -d "$root" ] && active+=" $root"
    done
    [ -z "$active" ] && return 0

    # shellcheck disable=SC2086
    timeout 3 grep -rliE "($terms)" $active \
        --include='*.md' \
        --max-count=1 \
        2>/dev/null \
        | head -5 \
        | while IFS= read -r path; do
            local title
            title="$(awk '!/^---$/ && !/^[[:space:]]*$/ { sub(/^#+[[:space:]]*/, ""); print; exit }' "$path" 2>/dev/null)"
            title="${title:-$(basename "$path" .md)}"
            title="$(printf '%s' "$title" | head -c 80)"
            echo "  - \"$title\" ($path)"
        done
}

probe_breadcrumb() {
    echo "grep -rli '<query>' $PROBE_ROOTS --include='*.md'"
}
