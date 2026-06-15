#!/usr/bin/env bash
# Behaviour tests for probes/tasksquad-handoff.sh — the handoff parser.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/probes/tasksquad-handoff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected >>$2<<, got: >>$1<<"; }
assert_empty()    { [ -z "$1" ] || fail "$2: expected empty, got: >>$1<<"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
hand() { jq -nc --argjson p "$1" '{results:[{thought:{content:($p|tostring)}}]}'; }
filter() { hand "$1" > "$TMP/p.json"; _tasksquad_filter "$TMP/p.json" "$2" "$3"; }

inprog='{"tasksquad_kind":"session-handoff","repo_name":"brainspike","branch":"main","status":"in-progress","session_end":"2026-06-15T01:00:00","task_id":"T-42","pending":["wire probe"],"next_steps":["regenerate hook"]}'

# in-progress handoff for matching repo+branch is surfaced
out="$(filter "$inprog" brainspike main)"
assert_contains "$out" "T-42"            "surfaces in-progress task id"
assert_contains "$out" "pending: wire probe" "surfaces first pending item"
assert_contains "$out" "/dropped-threads"     "surfaces breadcrumb"

# wrong branch is ignored
out="$(filter "$inprog" brainspike other)"
assert_empty "$out" "ignores handoff for a different branch"

# completed handoff is not surfaced
done_h="${inprog/in-progress/completed}"
out="$(filter "$done_h" brainspike main)"
assert_empty "$out" "ignores completed handoff"

echo "tasksquad probe tests passed"
