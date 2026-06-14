#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_empty() {
    local value="$1"
    local label="$2"
    [ -z "$value" ] || fail "$label: expected empty output, got: $value"
}

assert_contains() {
    local value="$1"
    local needle="$2"
    local label="$3"
    [[ "$value" == *"$needle"* ]] || fail "$label: expected to contain $needle, got: $value"
}

HOME_DIR="$TMPDIR_ROOT/home"
PROJECT_DIR="$TMPDIR_ROOT/project"
PROBES_DIR="$TMPDIR_ROOT/probes"
mkdir -p "$HOME_DIR" "$PROJECT_DIR" "$PROBES_DIR"

cat > "$PROBES_DIR/fixture.sh" <<'PROBE'
PROBE_NAME="fixture"
PROBE_DESCRIPTION="fixture memory layer"

probe_detect() { return 0; }
probe_test_query() { return 0; }

probe_query() {
    local query="$1"
    case "$query" in
        *alpha*) printf '  - "Alpha decision" (fixture/alpha.md)\n' ;;
        *bravo*) printf '  - "Bravo note" (fixture/bravo.md)\n' ;;
    esac
}

probe_breadcrumb() {
    echo 'fixture-search "<query>"'
}
PROBE

cd "$PROJECT_DIR"
HOOK="$TMPDIR_ROOT/brainspike.sh"
PRETOOL_HOOK="$TMPDIR_ROOT/brainspike-pretool.sh"
SETTINGS="$PROJECT_DIR/.claude/settings.local.json"

HOME="$HOME_DIR" "$ROOT/install.sh" \
    --probes "$PROBES_DIR" \
    --hook "$HOOK" \
    --pretool-hook "$PRETOOL_HOOK" \
    --settings "$SETTINGS"

HOME="$HOME_DIR" "$ROOT/install.sh" \
    --probes "$PROBES_DIR" \
    --hook "$HOOK" \
    --pretool-hook "$PRETOOL_HOOK" \
    --settings "$SETTINGS" >/dev/null

[ -x "$HOOK" ] || fail "UserPromptSubmit hook was not written"
[ -x "$PRETOOL_HOOK" ] || fail "PreToolUse hook was not written"

jq -e --arg hook "$HOOK" '
    any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $hook)
' "$SETTINGS" >/dev/null || fail "UserPromptSubmit hook was not registered"

jq -e --arg hook "$PRETOOL_HOOK" '
    any(.hooks.PreToolUse[]?;
        .matcher == "Grep|Glob|Task|Agent|WebSearch|WebFetch" and
        any(.hooks[]?; .command == $hook))
' "$SETTINGS" >/dev/null || fail "PreToolUse STRONG matcher was not registered"

[ "$(jq --arg hook "$HOOK" '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == $hook)] | length' "$SETTINGS")" = "1" ] \
    || fail "UserPromptSubmit hook was registered more than once"
[ "$(jq --arg hook "$PRETOOL_HOOK" '[.hooks.PreToolUse[]?.hooks[]? | select(.command == $hook)] | length' "$SETTINGS")" = "1" ] \
    || fail "PreToolUse hook was registered more than once"

export TMPDIR="$TMPDIR_ROOT/tmp"
mkdir -p "$TMPDIR"

first="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-a","tool_name":"Task","tool_input":{"prompt":"Investigate alpha decision drift"}}
JSON
)"
jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$first" >/dev/null \
    || fail "PreToolUse JSON envelope did not name PreToolUse: $first"
jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$first" >/dev/null \
    || fail "PreToolUse JSON envelope did not allow: $first"
additional="$(printf '%s' "$first" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$additional" "=== brainspike (mid-turn) ===" "additionalContext header"
assert_contains "$additional" "fixture (1 match" "additionalContext breadcrumb"
assert_contains "$additional" "Alpha decision" "additionalContext result"

second="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-a","tool_name":"Task","tool_input":{"prompt":"Investigate alpha decision drift"}}
JSON
)"
assert_empty "$second" "duplicate PreToolUse breadcrumb in same session"

bash_out="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-b","tool_name":"Bash","tool_input":{"command":"rg alpha"}}
JSON
)"
assert_empty "$bash_out" "Bash is out of STRONG scope"

read_out="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-b","tool_name":"Read","tool_input":{"file_path":"docs/alpha.md"}}
JSON
)"
assert_empty "$read_out" "Read/file_path is Phase 2 and out of scope"

webfetch_out="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-c","tool_name":"WebFetch","tool_input":{"url":"https://example.com/page","prompt":"Summarize bravo evidence"}}
JSON
)"
assert_contains "$webfetch_out" "Bravo note" "WebFetch query combines url and prompt"

user_out="$(printf '%s\n' '{"session_id":"session-d","prompt":"alpha"}' | "$HOOK")"
assert_contains "$user_out" "=== brainspike ===" "UserPromptSubmit still emits raw context"
seeded="$("$PRETOOL_HOOK" <<'JSON'
{"session_id":"session-d","tool_name":"Grep","tool_input":{"pattern":"alpha"}}
JSON
)"
assert_empty "$seeded" "PreToolUse dedups against UserPromptSubmit surfaced set"

echo "pretooluse gate tests passed"
