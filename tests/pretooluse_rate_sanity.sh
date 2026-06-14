#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

HOME_DIR="$TMPDIR_ROOT/home"
PROJECT_DIR="$TMPDIR_ROOT/project"
PROBES_DIR="$TMPDIR_ROOT/probes"
mkdir -p "$HOME_DIR" "$PROJECT_DIR" "$PROBES_DIR"

cat > "$PROBES_DIR/fixture.sh" <<'PROBE'
PROBE_NAME="fixture"
PROBE_DESCRIPTION="fixture memory layer"
probe_detect() { return 0; }
probe_test_query() { return 0; }
probe_query() { return 0; }
probe_breadcrumb() { echo 'fixture-search "<query>"'; }
PROBE

cd "$PROJECT_DIR"
HOME="$HOME_DIR" "$ROOT/install.sh" \
    --probes "$PROBES_DIR" \
    --hook "$TMPDIR_ROOT/brainspike.sh" \
    --pretool-hook "$TMPDIR_ROOT/brainspike-pretool.sh" \
    --settings "$PROJECT_DIR/.claude/settings.local.json" >/dev/null

matcher="$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]?; .command | endswith("brainspike-pretool.sh"))) | .matcher' "$PROJECT_DIR/.claude/settings.local.json")"

cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 - "$matcher" <<'PY'
import sys
sys.path.insert(0, "spec")
import gate_sim

matcher = sys.argv[1]
scope = set(matcher.split("|")) if matcher else set()
if scope != gate_sim.STRONG_TOOLS:
    raise SystemExit(f"registered matcher drifted from STRONG scope: {matcher!r}")

rate = gate_sim.run(dedup="session", scope_set=scope, scope_label="BUILT STRONG matcher", per_tool=True)
if not (1.8 <= rate <= 2.6):
    raise SystemExit(f"STRONG firing rate sanity check failed: {rate:.1f}/100")

print(f"pretooluse rate sanity passed: {rate:.1f}/100")
PY
