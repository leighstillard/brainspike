#!/usr/bin/env bash
# brainspike probe: mentisdb
# Ranked-search over the mentisdb daemon's append-only semantic memory.
# Relevance-filtered (not a recency dump): see _mentis_filter.

PROBE_NAME="mentisdb"
PROBE_DESCRIPTION="mentisdb semantic memory (ranked search)"
PROBE_HOST="${MENTISDB_HOST:-http://127.0.0.1:9472}"

probe_detect() {
    command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1
}

probe_test_query() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$PROBE_HOST/v1/chains" 2>/dev/null)" = "200" ]
}

# Reads a ranked-search JSON payload from $1 (file), prints breadcrumb lines.
_mentis_filter() {
    MENTIS_MIN_SCORE="${MENTIS_MIN_SCORE:-10}" \
    MENTIS_FEEDBACK_MIN_SCORE="${MENTIS_FEEDBACK_MIN_SCORE:-5}" \
    python3 - "$1" <<'PY'
import json, os, sys, re

MIN_SCORE = float(os.environ.get("MENTIS_MIN_SCORE", "10"))
# "How to work with Leigh" feedback notes are the high-value class — give them
# a lower bar so a moderately-relevant one still surfaces (but not unconditionally).
FEEDBACK_MIN_SCORE = float(os.environ.get("MENTIS_FEEDBACK_MIN_SCORE", "5"))
# Hard project scope: drop hits whose structured tags name a *different* project.
# Generic by design — keys on a `<prefix><name>` tag convention (default "proj-")
# and no-ops entirely when no current project is known. Untagged hits (no
# project tag) and feedback notes are never project-scoped away.
PROJECT = os.environ.get("MENTIS_PROJECT", "").strip().lower()
PROJECT_TAG_PREFIX = os.environ.get("MENTIS_PROJECT_TAG_PREFIX", "proj-")

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

items = data.get("results") or data.get("thoughts") or (data if isinstance(data, list) else [])
if not isinstance(items, list):
    sys.exit(0)

def score_of(item):
    sc = item.get("score")
    if isinstance(sc, dict):
        return sc.get("total", 0.0) or 0.0
    return sc or 0.0

def is_foreign_project(tags):
    # A hit is foreign iff it carries >=1 project tag and none match PROJECT.
    # Match is boundary-aware (exact or hyphen-delimited prefix in either
    # direction) so "partseeker" matches "partseeker-scraper" but project
    # "art" does NOT spuriously match tag "proj-cart".
    if not PROJECT:
        return False
    proj_tags = [t[len(PROJECT_TAG_PREFIX):].lower()
                 for t in tags
                 if isinstance(t, str) and t.startswith(PROJECT_TAG_PREFIX)]
    proj_tags = [pt for pt in proj_tags if pt]
    if not proj_tags:
        return False
    def matches(pt):
        return pt == PROJECT or pt.startswith(PROJECT + "-") or PROJECT.startswith(pt + "-")
    return not any(matches(pt) for pt in proj_tags)

# Relevance-ranked, thresholded — never padded to a fixed count.
for item in sorted(items, key=score_of, reverse=True):
    th = item.get("thought") if isinstance(item.get("thought"), dict) else item
    content = re.sub(r"\s+", " ", (th.get("content") or "").strip())
    if not content:
        continue
    # tasksquad session-handoff blobs are surfaced (scoped + parsed) by the
    # dedicated tasksquad-handoff probe; here they are pure duplicated noise.
    if "tasksquad_kind" in content:
        continue
    tags = th.get("tags")
    tags = tags if isinstance(tags, list) else []
    is_feedback = content.startswith("[feedback_") or "feedback" in tags
    # Cross-project hits are dropped, but never feedback ("how to work with Leigh").
    if not is_feedback and is_foreign_project(tags):
        continue
    floor = FEEDBACK_MIN_SCORE if is_feedback else MIN_SCORE
    if score_of(item) < floor:
        continue
    if len(content) > 80:
        content = content[:77] + "..."
    ttype = th.get("thought_type") or ""
    chain = item.get("chain_key") or th.get("chain_key") or ""
    date_str = (th.get("timestamp") or th.get("created_at") or "")[:10]
    meta = ", ".join(x for x in [ttype, chain, date_str] if x)
    print(f'  - "{content}" ({meta})')
PY
}

probe_query() {
    local query="$1" tmp
    tmp="$(mktemp)" || return 0
    # Scope to the current repo (override with MENTIS_PROJECT; empty => no scoping).
    # Portable basename (no xargs -r, space-safe); git -C "$PWD" matches the
    # sibling tasksquad probe.
    if [ -z "${MENTIS_PROJECT:-}" ] && command -v git >/dev/null 2>&1; then
        MENTIS_PROJECT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
        MENTIS_PROJECT="${MENTIS_PROJECT##*/}"
    fi
    export MENTIS_PROJECT
    timeout 3 curl -s --max-time 3 -X POST "$PROBE_HOST/v1/ranked-search" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg q "$query" '{text: $q, limit: 12}')" 2>/dev/null > "$tmp"
    # Emit the full relevance-ranked filtered list; the consuming hook applies the
    # MENTIS_MAX cap *after* across-turn dedup so repeats advance to the next page
    # rather than starving rank-5+ hits.
    _mentis_filter "$tmp"
    rm -f "$tmp"
}

probe_breadcrumb() {
    echo 'mb search "<query>"'
}
