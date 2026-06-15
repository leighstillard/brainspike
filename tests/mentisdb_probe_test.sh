#!/usr/bin/env bash
# Behaviour tests for probes/mentisdb.sh — the score/relevance filter.
# Exercises _mentis_filter (the embeddable JSON->breadcrumb stage) against
# fixed ranked-search payloads, so the three approved fixes are pinned:
#   (a) score threshold + no padding to 5
#   (b) drop tasksquad_kind session-handoff content
#   (c) privilege [feedback_*] LessonLearned with a lower threshold
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/probes/mentisdb.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected to contain >>$2<<, got: >>$1<<"; }
assert_missing()  { [[ "$1" != *"$2"* ]] || fail "$3: expected NOT to contain >>$2<<, got: >>$1<<"; }
assert_empty()    { [ -z "$1" ] || fail "$2: expected empty, got: >>$1<<"; }

rs() { # build a ranked-search result object: rs <total> <type> <content>
    jq -nc --argjson t "$1" --arg ty "$2" --arg c "$3" \
        '{chain_key:"personal",score:{total:$t},thought:{thought_type:$ty,content:$c}}'
}
rst() { # rs WITH a structured tags array: rst <total> <type> <content> <tags_json>
    jq -nc --argjson t "$1" --arg ty "$2" --arg c "$3" --argjson tg "$4" \
        '{chain_key:"personal",score:{total:$t},thought:{thought_type:$ty,content:$c,tags:$tg}}'
}
payload() { jq -nc --argjson r "[$(printf '%s,' "$@" | sed 's/,$//')]" '{backend:"x",total:($r|length),results:$r}'; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
filter() { payload "$@" > "$TMP/p.json"; _mentis_filter "$TMP/p.json"; }
# filter with a current-project scope set: filterp <project> <items...>
filterp() { local proj="$1"; shift; payload "$@" > "$TMP/p.json"; MENTIS_PROJECT="$proj" _mentis_filter "$TMP/p.json"; }

# (a) high-score relevant item is surfaced
hi="$(rs 28.5 LessonLearned '[feedback_verbosity_depth] Keep replies terse')"
out="$(filter "$hi")"
assert_contains "$out" "Keep replies terse" "high-score surfaced"

# (a) low-score noise is dropped, not padded into the output
noise="$(rs 8.9 Finding '[synapse-ai] AWS CLI access verified for S3 operations')"
out="$(filter "$hi" "$noise")"
assert_contains "$out" "Keep replies terse" "keeps high-score with noise present"
assert_missing "$out" "AWS CLI access"        "drops sub-threshold noise"

# (b) tasksquad session-handoff JSON is excluded (handled by its own probe)
tsq="$(rs 30 FactLearned '{"tasksquad_kind": "session-handoff", "status": "in-progress", "task_id": "T1"}')"
out="$(filter "$hi" "$tsq")"
assert_contains "$out" "Keep replies terse"  "keeps real hit alongside tasksquad"
assert_missing "$out" "tasksquad_kind"        "drops tasksquad session-handoff JSON"

# (c) [feedback_*] LessonLearned is privileged: surfaces below the main floor;
#     a generic item at the same score does not.
fb_mid="$(rs 6 LessonLearned '[feedback_check_memory_first] Check memory before asking')"
gen_mid="$(rs 6 Finding '[synapse-ai] some unrelated finding')"
out="$(filter "$fb_mid" "$gen_mid")"
assert_contains "$out" "Check memory before asking" "privileges feedback below main floor"
assert_missing  "$out" "unrelated finding"           "generic item at same score dropped"

# but a feedback note below even the feedback floor is still dropped (not unconditional)
fb_low="$(rs 1 LessonLearned '[feedback_check_memory_first] Check memory before asking')"
out="$(filter "$fb_low")"
assert_empty "$out" "feedback below feedback floor is dropped"

# (d) hard project filter — scope to the current repo via structured proj-* tags.
#     Identity lives in the `tags` array (proj-<name>); cross-project hits drop,
#     untagged/feedback hits survive, and the filter no-ops when unscoped.
foreign="$(rst 40 Insight 'piebald deploy notes' '["proj-piebald"]')"
own="$(rst 40 Insight 'brainspike hook design' '["proj-brainspike"]')"
asg="$(rst 16 Insight 'partseeker-scraper-worker ASG owned by CloudWatch alarms' '["asg","scraper-worker","aws"]')"

out="$(filterp brainspike "$foreign")"
assert_empty "$out" "foreign proj-* tag dropped under project scope"

out="$(filterp brainspike "$own")"
assert_contains "$out" "brainspike hook design" "matching proj-* tag kept under project scope"

out="$(filterp brainspike "$asg")"
assert_contains "$out" "ASG owned by CloudWatch" "non-proj-tagged hit kept under project scope"

# boundary-aware match: repo token is a hyphen-delimited prefix of a proj tag
own_sub="$(rst 40 Insight 'partseeker scraper pricing' '["proj-partseeker-scraper"]')"
out="$(filterp partseeker "$own_sub")"
assert_contains "$out" "partseeker scraper pricing" "proj tag with the repo token as a hyphen-prefix kept"

# boundary-aware match: a bare substring (not hyphen-delimited) is NOT a match
not_boundary="$(rst 40 Insight 'shopping cart service' '["proj-cart"]')"
out="$(filterp art "$not_boundary")"
assert_empty "$out" "substring-but-not-boundary proj tag treated as foreign"

# feedback is exempt even if it somehow carries a foreign proj-* tag
fb_foreign="$(rst 40 LessonLearned '[feedback_verbosity_depth] terse please' '["proj-piebald","feedback"]')"
out="$(filterp brainspike "$fb_foreign")"
assert_contains "$out" "terse please" "feedback exempt from project filter"

# no current project => filter inactive (cross-project hit retained)
payload "$foreign" > "$TMP/p.json"
out="$(MENTIS_PROJECT='' _mentis_filter "$TMP/p.json")"
assert_contains "$out" "piebald deploy notes" "no project scope => foreign hit retained"

echo "mentisdb probe tests passed"
