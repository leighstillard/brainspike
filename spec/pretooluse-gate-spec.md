# brainspike — PreToolUse Query-Reconstruction Gate (spec v1)

**Status:** dry-run PASSED for the STRONG-scope variant (firing rate 1.0× base). Build approved for that scope; `file_path` expansion deferred (gray-zone, 3–4× base).
**Date:** 2026-06-14 · **Author:** driftmine → brainspike handoff
**Evidence base:** `research/driftmine/FINDINGS.md`, `research/driftmine/records.json` (211 labelled drift events). Measurement is reproducible: `brainspike/spec/gate_sim.py` (reuses the verified `dm_parse` turn/step parser; asserts walk-consistency against it).

---

## 1. Why this gate exists (one paragraph)

driftmine proved agent drift is **80% mid-turn** (170/211 events have no intervening human prompt) and that in **73%** of mid-turn cases a relevant fact was already available `earlier_in_session`. A `UserPromptSubmit` hook fires only at human turn boundaries, so it structurally cannot catch 4-in-5 drift events. driftmine also **killed the step-counter approach** (drift spreads across all tool-call depths — step 0→41, 1–5→26, 6–10→19, 11–20→18, 21+→21; no threshold works). The supported trigger is **query reconstruction**: on `PreToolUse`, probe brainspike's memory layers using the *tool input* as the query (not the original user prompt), and surface any relevant breadcrumb the agent appears not to have consulted. Hard constraint: drift occurs at **2.3 events / 100 tool calls** — an unconditional gate is 98% noise, so the gate is **precision-first**.

---

## 2. Gate design

### 2.1 Tool scope — what fires (precision-first)

A `PreToolUse` evaluation is **eligible to fire** only for tools whose input carries a genuine *query signal*. Everything else is excluded — the gate never even probes.

| In scope (STRONG, v1) | query field | rationale |
|---|---|---|
| `Grep`, `Glob` | `pattern` | explicit search intent |
| `Task`, `Agent` | `prompt` | sub-agent dispatch is a rich query and a high-drift moment |
| `WebSearch` | `query` | explicit external lookup |
| `WebFetch` | `url` + `prompt` | external lookup |

**Out of scope (v1), with reason:**
- `Bash` — **57% of all tool calls (5207/9205)**; bare operational commands (`ls`, `cd`, `git status`) carry no probeable query. Including it is the single biggest noise source.
- `Read`/`Edit`/`Write`/`NotebookEdit` (`file_path`) — **deferred to Phase 2** (see §6). A file path is a thin query that fires often; including these tools moves firing from 1.0× to 3.2–4.7× base (gray zone) for +24pp recall. Needs a stronger relevance signal than lexical path overlap before it earns hot-path cost.
- `Read` with `offset` — paging/"read-by-line", not a fresh query.
- `ToolSearch`, `mcp__*search*`, `Skill` — the agent is *already* consulting a layer; re-probing is redundant.
- `TaskCreate/Update`, `TodoWrite`, `AskUserQuestion`, `SendMessage`, `Schedule*`, Linear/temporal writes — no query signal.

Matcher (Claude Code `matcher` field, pipe-delimited exact names):
```
"Grep|Glob|Task|Agent|WebSearch|WebFetch"
```

### 2.2 Query reconstruction

For an eligible tool call, build the probe query from its query field (§2.1). Run brainspike's **existing probes** (`probe_query "$reconstructed_query"`) — the same `claude-mem` / `auto-memory` / `graphify` / `markdown-docs` / `slack-agent-mem` probes the UserPromptSubmit hook already uses. No new retrieval code; only the *query source* changes (tool input instead of `.prompt`).

### 2.3 Fire condition (relevance + novelty)

Fire **iff** the probe returns a breadcrumb that is:
1. **relevant** — a non-empty probe result for the reconstructed query, AND
2. **novel** — not already surfaced this session (see §3 dedup).

If it fires, inject the breadcrumb(s) via `additionalContext` (§4). If not, inject nothing (the common case — the gate is silent on ~98 of every 100 tool calls).

---

## 3. Per-session dedup (against what UserPromptSubmit already showed)

The gate must not re-show breadcrumbs the session has already seen. Maintain per-session state keyed by `session_id` (available on hook stdin) at e.g. `$TMPDIR/brainspike/<session_id>.surfaced`:

- **Seed from UserPromptSubmit:** when the UserPromptSubmit hook surfaces breadcrumbs, it appends their keys (layer + result identity) to the same per-session `surfaced` set. (Requires a one-line addition to the existing hook.)
- **PreToolUse dedups against it:** a breadcrumb fires only if its key ∉ `surfaced`; on firing, add its key.
- **Dedup strictness = once-per-session** (the measured, precision-first policy). Turn-level dedup raises firing ~40% (2.2→2.3 STRONG; 7.5→10.7 ALL) for negligible recall gain — not worth it.

This is exactly the lever that keeps firing at base rate: without dedup the STRONG gate would fire on every relevant in-scope call; session-dedup collapses repeats so each distinct breadcrumb surfaces at most once.

State file is best-effort (drift in `/tmp`, cleaned on session end); a missing file just means "nothing surfaced yet."

---

## 4. Injection mechanism (empirically confirmed)

Confirmed against real transcripts in the corpus (an existing `canonical-infra-inject.sh` / graphify PreToolUse hook), not just docs:

- **Output channel:** a `PreToolUse` hook must print a **JSON object on stdout**; plain stdout is ignored (unlike UserPromptSubmit, which injects raw stdout). Shape:
  ```json
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "additionalContext": "=== brainspike (mid-turn) ===\n<breadcrumbs>\n=== end ==="
    }
  }
  ```
  `permissionDecision:"allow"` + `additionalContext` coexist — we never block the tool; we annotate it.
- **Where it lands (empirical):** the injected block threads **between the `tool_use` and its `tool_result`** (observed line order: `tool_use` → hook attachment → `tool_result`). It is therefore visible to the model on its **next reasoning step**, after the tool result — not before the tool executes.
- **Design implication:** the gate **cannot prevent the immediate drifting call**; it nudges the *next* decision. That is the correct lever — drift is a trajectory, and driftmine showed deep mid-turn drift is where the agent is otherwise unassisted. (If hard prevention is ever wanted, `permissionDecision:"deny"` is available, but that is out of scope here.)
- **Budget:** keep the block small (reuse brainspike's ≤500-token discipline) and the probe fast (the existing 3s `timeout` per layer applies; PreToolUse is hot-path, so prefer a tighter ~1.5s cap — see §7).

---

## 5. DRY-RUN MEASUREMENT (decision gate — runs before any build)

**Method.** Simulate the gate over all 41 substantive driftmine sessions (9205 main-chain tool calls). For every tool call, apply the §2–§3 filters; count firings. Score firings against the 211 labelled drift events (precision = fires landing at/before an `earlier_in_session` mid-turn drift in the same turn; recall = catchable such events with a preceding fire). The in-session-reconstruction proxy is a **lower bound** on the real probe (which also hits external memory, invisible from transcripts). Reproduce: `python3 brainspike/spec/gate_sim.py`.

**Decision rule (given):** firing rate near base (2.3/100) → BUILD. ~10× base (~23/100) → design wrong, STOP. (3–5× = gray zone → tighten/decide.)

**Results:**

| scope | dedup | firing rate /100 | × base | precision | recall |
|---|---|---|---|---|---|
| ALL (incl `file_path`) | session | 7.5 | 3.2× | 22% | 33% |
| ALL | turn | 10.7 | 4.7× | 18% | 37% |
| **STRONG (Grep/Glob/Task/Agent/Web)** | **session** | **2.2** | **1.0×** | **26%** | 9% |
| STRONG | turn | 2.3 | 1.0× | 25% | 9% |

Stage breakdown (STRONG, session): in-scope tools = 3.3% of calls → +query-signal 3.1% → +relevance+dedup **2.2%**. Fires by tool: `Agent`=181, `Grep`=11, `WebSearch`=7, `WebFetch`=4, `Glob`=1. (ALL adds `Edit`=238, `Read`=136, `Write`=108 — the noise.)

**Verdict: PASS for STRONG scope.** At 2.2/100 the gate fires at the drift base rate — it is *not* noise (precision 26%: ~1-in-4 fires coincides with real in-session drift, and that undercounts usefulness since a fire that prevents drift produces no drift label). The naive ALL-tools design **fails** the precision-first bar (3.2–4.7× base) and is correctly rejected here rather than after shipping. Recall is modest (9%) — by design; v1 buys the cheap, safe wins (dominated by sub-agent dispatch + Grep) at zero FP-budget overrun.

> If the dry-run had landed at ~10× base, this document would stop here with "design rejected." It did not; build instructions follow.

---

## 6. Build instructions (approved scope only)

1. **Extend the probe contract — none needed.** Reuse `probe_query`/`probe_breadcrumb` as-is. The gate is a *new hook*, not new probes.
2. **Generate a `PreToolUse` hook** (`install.sh` gains a `--pretooluse` path or a second emitted hook `brainspike-pretool.sh`):
   - Read stdin JSON: `tool_name=$(jq -r '.tool_name')`, `tool_input` per tool, `session_id`.
   - If `tool_name` ∉ `{Grep,Glob,Task,Agent,WebSearch,WebFetch}` → `exit 0` (emit nothing).
   - Reconstruct query from the tool's query field (§2.1). If empty → `exit 0`.
   - Run the embedded probes concurrently (reuse the installer's probe-embedding machinery) with a **tight per-probe timeout (~1.5s)** and ~3s total wall cap (hot-path).
   - Drop any breadcrumb whose key ∈ the per-session `surfaced` set (§3). If nothing novel remains → `exit 0`.
   - Else print the JSON of §4 with the surviving breadcrumbs in a `=== brainspike (mid-turn) ===` block; append their keys to `surfaced`.
   - Never exit non-zero (same promise as the UserPromptSubmit hook).
3. **Seed dedup from UserPromptSubmit:** add one append to the existing hook so prompt-surfaced breadcrumb keys land in `$TMPDIR/brainspike/<session_id>.surfaced`.
4. **Register** in settings under `hooks.PreToolUse` with `"matcher": "Grep|Glob|Task|Agent|WebSearch|WebFetch"`, preserving existing hooks (same idempotent `jq` merge the installer already uses).
5. **Telemetry + kill-switch (required for a hot-path hook):**
   - Log every fire (session, tool, query, breadcrumb keys, durationMs) to `~/.claude/brainspike-pretool.log` so the live firing rate can be checked against the predicted 2.2/100.
   - Honor `BRAINSPIKE_PRETOOL=0` env to disable instantly.
   - After ~1 week live, recompute firing rate from the log; if it materially exceeds the predicted ~2–3/100, tighten scope or dedup before considering Phase 2.

**TDD note:** the fire-condition logic (scope filter, query reconstruction, dedup) is correctness-critical and should be built test-first, mirroring driftmine's parser discipline. `gate_sim.py`'s `in_scope` / `query_entities` / dedup model is the executable reference.

---

## 7. Out of scope / later

- **`file_path` tools (Read/Edit/Write) — Phase 2.** Measured at 3.2–4.7× base with lexical relevance. Revisit only with a *stronger relevance signal* (e.g. the probe matching a decision/ADR about that file, not mere path overlap) or per-file once-ever dedup, and only if v1 telemetry shows headroom. Expected payoff: recall 9%→33%.
- **Embedding-distance drift detection — Phase 3 (justified-but-cost-gated).** driftmine's 57 `contradiction`+`abandoned_thread` events are semantic drift a lexical/query gate cannot see; embedding distance from the originating prompt could catch them. Justified by evidence but gated on hot-path embedding cost — prototype offline against those 57 cases before putting it inline.
- **The actual hook implementation** beyond this spec (a separate task; confirm scope before writing the hook).

---

## 8. Caveats

- Single user, CC 2.1.x corpus; firing-rate estimate reflects Leigh's tool mix (Bash-heavy). Re-measure if the population changes.
- Precision/recall scored against the lexical in-session proxy and the 211 LLM-labelled events — both undercount the real probe (external memory invisible) and real usefulness (prevented drift leaves no label). Treat 2.2/100 as the firing-rate anchor and 26%/9% as conservative precision/recall floors.
- The gate informs the *next* step (injection lands after the tool result), so it shapes trajectory, not the immediately-gated call.
