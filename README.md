# brainspike

> A `UserPromptSubmit` hook that searches whatever memory layers it finds in
> your environment and injects pointers — titles, summaries, paths, IDs — into
> Claude's context, so it knows what's available before it starts working.

`brainspike` does not feed Claude full memory contents. It feeds Claude
**breadcrumbs**: "here are 3 things in `claude-mem` that look relevant; if you
want them, run `claude-mem search ...`". The point is to teach the model what
to look for, not to dump prior context into every turn.

## What it does

On every prompt:

1. The installed hook reads the prompt from stdin (`jq -r '.prompt'`).
2. For each memory layer discovered at install time it runs a quick
   keyword/FTS query (capped at 3s per layer).
3. It prints a small summary block per layer — title-style results plus a
   breadcrumb command you (or Claude) can run for the full results.
4. If everything comes back empty, it prints a structural reminder of *which*
   layers exist and how to query them, so Claude knows the option is there.

Output is wrapped in `=== brainspike ===` markers so it shows up cleanly in
Claude's context but is easy to ignore or filter.

### Example output

```
=== brainspike ===
claude-mem (5 matches, run `mcp__plugin_claude-mem_mcp-search__search query="<query>"  (or /mem-search)` for more):
  - "Restructured PM autonomy guideline" (data-worklog, 2026-04-23)
  - "ADR-028 consume trickle pattern" (slurpy, 2026-04-19)
  - ...

graphify (3 matches, run `graphify query "<query>" --graph graphify-out/graph.json` for more):
  - YamlConfigSchema
  - parseTrickleEvent
  - ...

auto-memory (2 matches, run `grep -rli '<query>' /home/leigh/.claude/projects/*/memory --include='*.md'` for more):
  - "Use LSP for navigation" (cc-connect/feedback_use_lsp)
  - ...

markdown-docs: no matches

Consult these before asking the user for context you could find yourself.
Top 5 results shown per layer — use the commands above for deeper searches.
=== end brainspike ===
```

## Install

From a project directory:

```bash
git clone git@github.com:leighstillard/brainspike.git
cd brainspike
./install.sh                                  # probe + register in this project
./install.sh --global                         # or register globally
./install.sh --dry-run                        # see what would happen
```

The installer:

- Probes each file in `probes/`. A probe must declare itself detectable
  *and* respond to a test query before it's accepted.
- Generates a tailored hook at `~/.claude/hooks/brainspike.sh` that embeds
  only the probes that passed.
- Adds a `UserPromptSubmit` entry pointing at that hook to either
  `.claude/settings.local.json` (default) or `~/.claude/settings.json`
  (with `--global`). Existing hooks are preserved; double-registration is
  prevented.

Re-run `install.sh` any time to re-probe and rebuild the hook (e.g. after
installing a new memory tool).

## Uninstall

```bash
./uninstall.sh                # remove hook + unregister from project settings
./uninstall.sh --global       # unregister from ~/.claude/settings.json
```

## Built-in probes

The repo ships with four sample probes. None are required — drop or add
as you like.

| Probe          | Detects                                                     | Query                                              |
| -------------- | ----------------------------------------------------------- | -------------------------------------------------- |
| `claude-mem`   | `~/.claude-mem/claude-mem.db` + `python3`                   | FTS5 over the `observations` table                 |
| `auto-memory`  | `~/.claude/projects/*/memory/*.md`                          | `grep -rli` across project memory markdown files   |
| `graphify`     | `graphify` on PATH + `graphify-out/graph.json` in CWD       | `graphify query` (parsed for cited nodes)          |
| `markdown-docs`| `docs/`, `doc/`, `Docs/`, or `documentation/` in CWD        | `grep -rli` across markdown files                  |

## Writing a custom probe

A probe is a sourceable shell file under `probes/` that declares a name,
description, and four functions. Drop a new file in and re-run `install.sh`.

```bash
#!/usr/bin/env bash
# probes/my-thing.sh

PROBE_NAME="my-thing"
PROBE_DESCRIPTION="my custom memory layer"

probe_detect() {
    # 0 = installed/available, non-zero = skip
    command -v my-tool >/dev/null 2>&1
}

probe_test_query() {
    # 0 = my-tool actually responds. Keep this fast and cheap.
    timeout 3 my-tool ping >/dev/null 2>&1
}

probe_query() {
    # Print up to 5 result lines. Each line is one breadcrumb.
    # Format suggested: '  - "title" (metadata)'
    local query="$1"
    timeout 3 my-tool search "$query" --limit 5 \
        | awk '{ printf "  - \"%s\"\n", $0 }'
}

probe_breadcrumb() {
    # The exact command a human (or Claude) can run to dig deeper.
    echo 'my-tool search "<query>"'
}
```

The installer runs `probe_detect && probe_test_query` in a clean subshell.
If either fails (or the file has a syntax error) the probe is skipped and
the hook is built without it.

## Constraints / promises

The generated hook:

- is a plain shell script — no compiled deps beyond `jq` (and whatever each
  active probe needs);
- caps each external query at 3 seconds (`timeout`);
- caps total wall time at ~9 seconds and kills any straggling probes;
- runs probes concurrently in the background;
- never exits non-zero — even if every probe explodes, the hook prints a
  short fallback and returns 0;
- emits well under 500 tokens of context per turn (headlines + paths, not
  content).

Layer names, query commands, and breadcrumb syntax are all decided at
install time from whatever probes match — nothing is hardcoded to a
specific tool. Removing a tool from your machine and re-running
`install.sh` cleanly drops it from the hook.

## Development

```bash
./install.sh --dry-run                        # see the plan
./install.sh --hook /tmp/bs.sh --no-register  # write a throwaway hook
echo '{"prompt":"YAML config validation"}' | /tmp/bs.sh
```

## License

MIT — see [LICENSE](./LICENSE).
