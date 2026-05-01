#!/usr/bin/env bash
# brainspike probe: slack-agent-mem
# Advertises the slack-recall Claude Code skill as an on-demand Slack memory
# layer. The hook cannot call MCP tools itself, so this probe emits breadcrumbs
# for the agent to invoke the skill when Slack/thread context looks relevant.

PROBE_NAME="slack-agent-mem"
PROBE_DESCRIPTION="Slack thread recall skill backed by Slack MCP"

_slack_agent_mem_skill_candidates() {
    local probe_dir repo_dir
    probe_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    repo_dir="$(cd "$probe_dir/.." 2>/dev/null && pwd)"

    [ -n "${SLACK_AGENT_MEM_SKILL:-}" ] && printf '%s\n' "$SLACK_AGENT_MEM_SKILL"
    [ -n "${SLACK_AGENT_MEM_ROOT:-}" ] && printf '%s\n' "$SLACK_AGENT_MEM_ROOT/skills/slack-recall/SKILL.md"
    printf '%s\n' \
        "$PWD/.claude/skills/slack-recall/SKILL.md" \
        "$HOME/.claude/skills/slack-recall/SKILL.md" \
        "$repo_dir/../slack-agent-mem/skills/slack-recall/SKILL.md" \
        "$repo_dir/../slack-agent-mem/skills/slack-recall.md"
}

_slack_agent_mem_find_skill() {
    local candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate" ] && {
            printf '%s\n' "$candidate"
            return 0
        }
    done <<EOF
$(_slack_agent_mem_skill_candidates)
EOF
    return 1
}

probe_detect() {
    _slack_agent_mem_find_skill >/dev/null
}

probe_test_query() {
    local skill
    skill="$(_slack_agent_mem_find_skill)" || return 1
    grep -Eq 'slack_read_thread|/slack-recall|slack_search_public' "$skill"
}

probe_query() {
    local query="$1"
    local lower terms

    lower="$(printf '%s\n' "$query" | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$lower" | grep -Eq 'slack|/slack-recall|thread_ts|message_ts|cc-connect|what (did|were) we (decide|discuss)|decision|decided|agreed|discussion|discussed|conversation|catch[ -]?up|recall|remember|prior context' || return 0

    terms="$(printf '%s\n' "$query" \
        | tr '[:upper:]' '[:lower:]' \
        | grep -oE '[a-z][a-z0-9_-]{2,}' \
        | grep -vE '^(the|and|for|did|that|this|with|from|what|when|where|which|were|have|does|they|there|then|also|into|like|want|need|please|make|tell|just|about|some|find|show|look|using|could|would|should|slack|thread|recall|remember|discussion|discussed|conversation|context|decision|decided|decide|agreed)$' \
        | awk '!seen[$0]++' \
        | head -6 \
        | paste -sd ' ' -)"

    echo '  - "Slack thread recall is available" (/slack-recall, current thread or latest channel thread)'
    if [ -n "$terms" ]; then
        echo "  - \"/slack-recall search $terms\" (search related Slack threads)"
    else
        echo '  - "/slack-recall recent 3" (review recent Slack threads)'
    fi
}

probe_breadcrumb() {
    echo '/slack-recall  (or /slack-recall search <query>)'
}
