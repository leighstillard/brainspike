# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`brainspike` generates two Claude Code hooks that search whatever memory layers
exist in your environment and inject **breadcrumbs** (titles, summaries, paths,
IDs + the command to dig deeper) — never full memory contents — into Claude's
context. The point is to teach the model what to look for, not to dump prior
context into every turn.

- **UserPromptSubmit hook** (`brainspike.sh`): fires at every human turn, probes
  active layers with the user's prompt, prints a `=== brainspike ===` block.
- **PreToolUse hook** (`brainspike-pretool.sh`): fires mid-turn on eligible tool
  calls (`Grep|Glob|Task|Agent|WebSearch|WebFetch` only), reconstructs a query
  from the tool input, and injects novel breadcrumbs via
  `hookSpecificOutput.additionalContext`. This is the precision-first
  "drift gate" — see `spec/pretooluse-gate-spec.md`.

## Commands

```bash
./install.sh                                  # probe + register in this project (.claude/settings.local.json)
./install.sh --global                         # register in ~/.claude/settings.json
./install.sh --dry-run                        # print plan, write nothing
./uninstall.sh [--global]                     # remove hooks + unregister

# Tests (no test runner — just run the scripts; both exit non-zero on failure)
./tests/pretooluse_gate_test.sh               # end-to-end: install, register, fire, dedup, scope
./tests/pretooluse_rate_sanity.sh             # asserts built matcher == STRONG scope and sim firing rate stays 1.8–2.6/100

# Dev loop — build throwaway hooks and pipe hook-shaped JSON at them
./install.sh --hook /tmp/bs.sh --pretool-hook /tmp/bs-pre.sh --no-register
echo '{"prompt":"YAML config validation"}' | /tmp/bs.sh
echo '{"session_id":"s","tool_name":"Task","tool_input":{"prompt":"YAML config validation"}}' | /tmp/bs-pre.sh

python3 spec/gate_sim.py                       # reproduce the dry-run firing-rate measurement
```

`BRAINSPIKE_PRETOOL=0` disables the hot-path hook without uninstalling.
PreToolUse fires are logged as JSON lines to `~/.claude/brainspike-pretool.log`.

## Architecture

The core idea: **the installer is a code generator.** It does not ship the
hooks — it probes the environment, then *emits* two self-contained bash scripts
that embed only the probes that passed. Removing a tool and re-running
`install.sh` cleanly drops it from the generated hook.

- **`probes/*.sh`** — each probe is a sourceable shell file defining
  `PROBE_NAME`, `PROBE_DESCRIPTION`, and four functions:
  `probe_detect` (is the layer present?), `probe_test_query` (does it actually
  respond? — keep fast/cheap), `probe_query "$q"` (print ≤5 breadcrumb lines,
  format `  - "title" (metadata)`), `probe_breadcrumb` (the dig-deeper command).
  The installer accepts a probe only if `probe_detect && probe_test_query`
  succeed in a clean subshell; a syntax error or failure silently skips it.
- **`install.sh`** — probes `PROBES_DIR`, then builds `$tmp_hook` and
  `$tmp_pretool_hook` line by line via a large `{ echo ...; } > file` block.
  Each active probe's file is `cat`'d *verbatim* into the generated hook inside
  a `( set +u; ... ) &` subshell so probes run concurrently. Registration is an
  idempotent `jq` merge that preserves existing hooks and refuses to clobber
  invalid JSON.
- The two generated hooks share `emit_shared_helpers` (session-state file path +
  breadcrumb dedup key via `cksum`). Dedup state lives at
  `$TMPDIR/brainspike/<session_id>.surfaced`. **Both** hooks now suppress
  breadcrumbs already in this set: the UserPromptSubmit hook dedups across turns
  (a breadcrumb shown on a prior prompt won't re-surface) *and* seeds the set, so
  the PreToolUse hook won't re-fire anything already shown at any prompt. Each
  layer caps at `MENTIS_MAX` (default 4) breadcrumbs (top by score, after
  threshold + scope); already-surfaced ones are then suppressed, so a repeated
  query can show fewer or go quiet.

### Hard constraints the generated hooks must keep

- Never exit non-zero (even if every probe explodes — print a fallback, exit 0).
- Cap each probe at 3s (`timeout`); UserPromptSubmit total ~9s, PreToolUse hot-path
  ~3s with a tighter ~1.5s per-probe cap (`BRAINSPIKE_PROBE_TIMEOUT`).
- Emit well under 500 tokens per turn — breadcrumbs, not content.
- PreToolUse must print a JSON object on stdout (plain stdout is ignored, unlike
  UserPromptSubmit which injects raw stdout); use `permissionDecision:"allow"` —
  it annotates, never blocks.

### PreToolUse scope is evidence-gated — do not widen casually

The STRONG scope (`Grep|Glob|Task|Agent|WebSearch|WebFetch`) was chosen because a
dry-run over 9205 real tool calls showed it fires at 2.2/100 — the drift base
rate. Adding `Bash` or `file_path` tools (`Read|Edit|Write`) pushes firing to
3.2–4.7× base (mostly noise) and is **deferred to Phase 2**. Any change to the
matcher must keep `tests/pretooluse_rate_sanity.sh` green (it re-runs `gate_sim`
and asserts the built matcher still equals STRONG scope). Read
`spec/pretooluse-gate-spec.md` before touching scope, dedup, or injection.

### Probe notes

- `probes/mentisdb.sh` queries the mentisdb daemon's `/v1/ranked-search` and is
  **relevance-filtered, not a recency dump**: it sorts by `score.total`, drops
  anything below `MENTIS_MIN_SCORE` (default 10), never pads to a fixed count,
  drops `tasksquad_kind` session-handoff blobs (the dedicated probe handles
  those), and privileges `[feedback_*]` notes with a lower `MENTIS_FEEDBACK_MIN_SCORE`
  (default 5). See `tests/mentisdb_probe_test.sh`.
- **Hard project scope**: drops hits whose *structured* `tags` array names a
  different project. The signal is a `<prefix><name>` tag convention
  (`MENTIS_PROJECT_TAG_PREFIX`, default `proj-`); the current project comes from
  the git repo basename (override `MENTIS_PROJECT`). A hit is foreign iff it
  carries ≥1 `proj-*` tag and none match the current project — so untagged hits
  (e.g. the partseeker ASG note, tagged `asg`/`scraper-worker`) and `[feedback_*]`
  notes are **never** scoped away. Generic by design: it no-ops entirely when no
  project is known or the response carries no `proj-*` tags, so non-mentisdb
  platforms are unaffected. `probe_query` caps output to `MENTIS_MAX` (default 4).
  Note: project identity lives in the structured `tags` array, **not** a content
  `[bracket]` prefix — claude-mem imports show `[synapse-ai]` etc. in content but
  the scoping tag is `proj-synapse-ai`.
- The deployed hooks on this machine are a **hand-curated fork** that the stock
  `install.sh` cannot yet reproduce: only `mentisdb` + `tasksquad-handoff` run on
  the per-prompt path (others are on-demand), and the PreToolUse gate is
  mentisdb-only. `install.sh` currently embeds *every* detected probe into *both*
  hooks — it has no per-hook / per-prompt membership concept. Do not regenerate
  the live hooks via `install.sh` without accounting for this, or you re-introduce
  the per-prompt noise the curation removed.

## Conventions

- Pure bash + `jq`; probes may depend on their own tools (e.g. `claude-mem`
  needs `python3` + the SQLite DB; `mentisdb` needs `curl` + a daemon on
  `MENTISDB_HOST`). No build step, no package manager.
- Custom layers = drop a new `probes/<name>.sh` in and re-run `install.sh`.
- Probe filtering logic that's correctness-critical lives in a sourceable shell
  function (e.g. `_mentis_filter`, `_tasksquad_filter`) reading a JSON file, so it
  stays embeddable verbatim in the generated hook *and* unit-testable from
  `tests/`.
- TDD applies to the fire-condition logic (scope filter, query reconstruction,
  dedup) — `gate_sim.py`'s `in_scope`/`query_entities`/dedup model is the
  executable reference.
