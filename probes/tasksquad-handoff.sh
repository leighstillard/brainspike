#!/usr/bin/env bash
# brainspike probe: tasksquad-handoff
# Surfaces the latest *in-progress* session-handoff for the current repo+branch
# from mentisdb. Scoped by repo+branch (not the user's query), so it only fires
# inside tasksquad-managed repos and never leaks other projects' handoffs.

PROBE_NAME="tasksquad-handoff"
PROBE_DESCRIPTION="paused tasksquad session-handoff for this repo+branch"
PROBE_HOST="${MENTISDB_HOST:-http://127.0.0.1:9472}"

_tasksquad_repo() {
    local p="$PWD"
    while [ "$p" != "/" ]; do
        [ -d "$p/.tasksquad" ] && return 0
        { [ -f "$p/core/CLAUDE.md" ] && [ -d "$p/data/wiki" ]; } && return 0
        p="$(dirname "$p")"
    done
    return 1
}

probe_detect() {
    command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
        && command -v git >/dev/null 2>&1 && _tasksquad_repo
}

probe_test_query() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$PROBE_HOST/v1/chains" 2>/dev/null)" = "200" ]
}

# Parse a ranked-search payload ($1) for the latest in-progress handoff matching
# repo ($2) + branch ($3); print a compact breadcrumb or nothing.
_tasksquad_filter() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
repo, branch = sys.argv[2], sys.argv[3]
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
items = data.get("results") or data.get("thoughts") or (data if isinstance(data, list) else [])
if not isinstance(items, list):
    sys.exit(0)
latest = None
for item in items:
    t = item.get("thought", item)
    try:
        payload = json.loads(t.get("content") or "")
    except Exception:
        continue
    if not isinstance(payload, dict):
        continue
    if payload.get("tasksquad_kind") != "session-handoff":
        continue
    if payload.get("repo_name") != repo or payload.get("branch") != branch:
        continue
    if latest is None or (payload.get("session_end") or "") > (latest.get("session_end") or ""):
        latest = payload
if latest and latest.get("status") == "in-progress":
    task = latest.get("task_id") or "(no task ID)"
    ended = (latest.get("session_end") or "")[:10]
    pend = latest.get("pending") or []
    nxt = latest.get("next_steps") or []
    print(f"  - {task}  (paused {ended})")
    if pend:
        print(f"    pending: {pend[0]}")
    if nxt:
        print(f"    next: {nxt[0]}")
    print("    run: /dropped-threads  for full detail")
PY
}

probe_query() {
    # The user's query ($1) is intentionally ignored: this probe is scoped by
    # repo+branch, not by query relevance.
    local repo branch tmp
    repo="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null | xargs -I{} basename {} 2>/dev/null)"
    branch="$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    { [ -z "$repo" ] || [ -z "$branch" ]; } && return 0
    tmp="$(mktemp)" || return 0
    timeout 3 curl -s --max-time 3 -X POST "$PROBE_HOST/v1/ranked-search" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg q "session handoff $repo $branch" '{text: $q, limit: 10}')" 2>/dev/null > "$tmp"
    _tasksquad_filter "$tmp" "$repo" "$branch"
    rm -f "$tmp"
}

probe_breadcrumb() {
    echo '/dropped-threads'
}
