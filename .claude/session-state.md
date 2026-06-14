# brainspike — session state

## 2026-06-14 — PreToolUse STRONG gate build
Deliverable: working STRONG-scope PreToolUse query-reconstruction hook wired through `install.sh`.
- Built installer support for a second generated hook at `~/.claude/hooks/brainspike-pretool.sh` (`--pretool-hook` override) and registration under `hooks.PreToolUse` with matcher `Grep|Glob|Task|Agent|WebSearch|WebFetch`.
- Scope is exactly STRONG: reconstructs queries from `Grep/Glob.pattern`, `Task/Agent.prompt`, `WebSearch.query`, and `WebFetch.url + prompt`; no `Bash`, `Read`, `Edit`, `Write`, or other `file_path` tools.
- Reuses the existing embedded probe code path and `probe_query`/`probe_breadcrumb`; no new retrieval layer was added.
- PreToolUse emits JSON `hookSpecificOutput.additionalContext` with `permissionDecision:"allow"` and never intentionally blocks the gated tool.
- Added per-session surfaced-state files at `${TMPDIR:-/tmp}/brainspike/<session_id>.surfaced`; UserPromptSubmit now seeds that set, and PreToolUse dedups against it before appending newly surfaced keys.
- Added hot-path controls: `BRAINSPIKE_PRETOOL=0` kill switch, per-probe timeout default `1.5s`, ~3s total wall cap, and fire telemetry to `~/.claude/brainspike-pretool.log`.
- Updated `uninstall.sh` to remove/unregister the PreToolUse hook and updated README docs.
- Tests added: `tests/pretooluse_gate_test.sh` for generated-hook behavior and `tests/pretooluse_rate_sanity.sh` for registered matcher firing-rate sanity.
- Verified: `bash tests/pretooluse_gate_test.sh`; `bash tests/pretooluse_rate_sanity.sh` → STRONG/session rate `2.2/100 (1.0x base)` with Agent=181, Grep=11, WebSearch=7, WebFetch=4, Glob=1; `bash -n install.sh uninstall.sh tests/pretooluse_gate_test.sh tests/pretooluse_rate_sanity.sh`; `git diff --check`; `./install.sh --dry-run`.

## 2026-06-14 — PreToolUse gate spec (driftmine handoff)
Deliverable: `spec/pretooluse-gate-spec.md` + `spec/gate_sim.py` (dry-run simulator, reuses driftmine's verified `dm_parse`).
- **Dry-run verdict: PASS for STRONG scope.** Gate restricted to `Grep|Glob|Task|Agent|WebSearch|WebFetch` fires **2.2/100 tool calls = 1.0× the 2.3/100 drift base rate** (precision 26%, recall 9%; fires dominated by Agent sub-agent dispatch=181). Meets the precision-first decision rule → build approved for that scope.
- **Rejected: ALL-scope (adds file_path Read/Edit/Write)** = 3.2–4.7× base (gray zone) → deferred to Phase 2 pending a stronger-than-lexical relevance signal.
- **Injection mechanism confirmed empirically** (from real corpus PreToolUse hooks `canonical-infra-inject.sh`/graphify): JSON stdout `hookSpecificOutput.additionalContext` (plain stdout ignored); block lands **between tool_use and tool_result** → nudges the NEXT step, doesn't block the gated call.
- **Build NOT started** (spec only; confirm scope before implementing the hook). Build steps + telemetry/kill-switch in §6 of the spec. Reproduce numbers: `python3 spec/gate_sim.py`.

## Status
Shipped initial version to https://github.com/leighstillard/brainspike (commit 36d0bd1).

## What was built
Repo at `/home/leigh/workspace/brainspike/` with:
- `install.sh` — probes each file in `probes/`, validates with a test query, generates a tailored `~/.claude/hooks/brainspike.sh`, registers it in `.claude/settings.local.json` (or `~/.claude/settings.json` with `--global`).
- `uninstall.sh` — removes hook + unregisters cleanly.
- `probes/claude-mem.sh` — Python+sqlite3 FTS5 over `~/.claude-mem/claude-mem.db`.
- `probes/auto-memory.sh` — grep across `~/.claude/projects/*/memory/*.md`.
- `probes/graphify.sh` — `graphify query` against `graphify-out/graph.json` in CWD.
- `probes/markdown-docs.sh` — generic grep across `docs/`/`doc/`/`Docs/`/`documentation/`.
- `README.md`, `LICENSE` (MIT), `.gitignore`.

## Verified
- Round-trip install + idempotent re-install + uninstall against an existing settings.local.json (other hooks preserved).
- Hook fires under 250ms with 2 active layers.
- Edge cases handled: empty/missing prompt, malformed JSON, no-match fallback.
- All four probes activate when their preconditions are met (tested in `/home/leigh/workspace/data-worklog` for graphify, fixture dir for markdown-docs).

## Not done / left as-is
- Did NOT install brainspike's own hook in this project — the user's expected workflow is to install in *consumer* projects, not the brainspike repo itself.
- claude-mem CLI binary on disk is Mach-O (won't run on Linux); the probe queries the SQLite DB directly via Python instead.
- Probes don't try to talk to MCP servers; if the user wants Membase/jcodemunch/jdocmunch context, that's a future probe (would need a CLI bridge or mcp-cli).

## Pick up next
- If user wants graphify probe to be smarter, parse `graphify query` JSON output (currently regex-extracts `src=` lines from the human-readable output).
- If they want claude-mem dates without having to know epoch is in ms, that's already fixed in this version.
- Optional: a `~/.local/share/brainspike/probes` dir for user-added probes that survive `git pull`.
