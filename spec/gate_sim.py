"""Dry-run simulation of the brainspike PreToolUse query-reconstruction gate.

Measures, against the real driftmine corpus + the 211 labelled drift events:
  - FIRING RATE per 100 tool calls (the go/no-go number), layered by filter stage
  - PRECISION  (of firings, fraction landing on/just-before a known drift event)
  - RECALL     (of catchable earlier_in_session mid-turn drift, fraction a firing precedes)

Reuses the VERIFIED driftmine parser (dm_parse) for turn/step truth -- the gate's
own ordered walk is cross-checked against dm_parse.index_session so the turn-boundary
logic is not reinvented (assertion fails loudly if they diverge).

This models the IN-SESSION-RECONSTRUCTION variant of the probe (driftmine's dominant
earlier_in_session signal). The real probe also hits external memory layers; those are
unobservable from a transcript, so this is a lower-bound proxy for relevance and an
honest estimate of firing rate from the tool-scope + dedup machinery.
"""
import json, os, re, sys

DRIFTMINE = "/home/leigh/workspace/research/driftmine"
sys.path.insert(0, DRIFTMINE)
from dm_parse import load_jsonl, index_session, classify_user_line  # verified parser

# ---- tool scope ------------------------------------------------------------
# IN scope = tool input carries a genuine query signal (a pattern, a file path, a
# sub-agent prompt, a url/query). OUT = operational/no-signal or already-searching.
QUERY_FIELD = {
    "Grep": "pattern", "Glob": "pattern",
    "Read": "file_path", "Edit": "file_path", "Write": "file_path",
    "NotebookEdit": "notebook_path",
    "Task": "prompt", "Agent": "prompt",
    "WebFetch": "url", "WebSearch": "query",
}
# explicitly OUT (documented for the spec): Bash (bare commands), Task/Todo mgmt,
# ToolSearch / mcp__*search* (agent is already consulting memory), Skill,
# AskUserQuestion, SendMessage, Schedule*, Linear/temporal writes, etc.

# scope tightness: STRONG = explicit search/query intent; ALL adds file_path tools
STRONG_TOOLS = {"Grep", "Glob", "Task", "Agent", "WebFetch", "WebSearch"}
ALL_TOOLS = set(QUERY_FIELD)

def in_scope(name, inp, scope_set):
    if name not in scope_set or name not in QUERY_FIELD:
        return False
    if not isinstance(inp, dict):
        return False
    # Read continuation (paging by offset) is "read-by-line", not a fresh query
    if name == "Read" and inp.get("offset"):
        return False
    field = QUERY_FIELD[name]
    return bool(inp.get(field))

# ---- entity extraction (the query-reconstruction signal) -------------------
_PATH = re.compile(r"(?:[\w.\-]+/){1,}[\w.\-]+")
_IDENT = re.compile(r"[A-Za-z0-9]+(?:[._\-/][A-Za-z0-9]+)+|[a-z]+[A-Z][A-Za-z]+")
_QUOTED = re.compile(r"[\"'`]([^\"'`]{4,40})[\"'`]")
_STOP = {"the", "and", "for", "with", "this", "that", "from", "into", "your"}

def entities(text):
    if not text:
        return set()
    t = str(text)
    out = set()
    for m in _PATH.findall(t):
        base = m.rstrip("/").split("/")[-1]
        if len(base) >= 4:
            out.add(base.lower())
        tail = "/".join(m.rstrip("/").split("/")[-2:])
        if len(tail) >= 6:
            out.add(tail.lower())
    for m in _IDENT.findall(t):
        if len(m) >= 5 and m.lower() not in _STOP:
            out.add(m.lower())
    for m in _QUOTED.findall(t):
        out.add(m.strip().lower())
    return out

def query_entities(name, inp):
    field = QUERY_FIELD.get(name)
    val = inp.get(field) if isinstance(inp, dict) else None
    ents = entities(val)
    if name in ("WebFetch",):              # url alone is thin; add the prompt
        ents |= entities(inp.get("prompt"))
    return ents

# ---- ordered walk (mirrors dm_parse semantics; cross-checked below) --------
def walk(lines):
    """Yield ordered rows: ('prompt',turn,text) | ('text',turn,text) |
    ('tool',turn,step,name,input). Sidechain excluded; steps reset per genuine turn."""
    tindex, step, started = -1, 0, False
    for ev in lines:
        et = ev.get("type")
        if et == "user" and classify_user_line(ev) == "genuine":
            tindex += 1; step = 0; started = True
            c = ev.get("message", {}).get("content")
            yield ("prompt", tindex, c if isinstance(c, str) else "")
        elif et == "assistant" and ev.get("isSidechain") is not True and started:
            c = ev.get("message", {}).get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") in ("text",) and b.get("text", "").strip():
                    yield ("text", tindex, b["text"])
                elif b.get("type") == "thinking" and b.get("thinking", "").strip():
                    yield ("text", tindex, b["thinking"])
                elif b.get("type") == "tool_use":
                    step += 1
                    yield ("tool", tindex, step, b.get("name"), b.get("input") or {})

def assert_consistency(lines):
    """Prove the gate's walk matches the verified parser's turn/step for tool calls."""
    truth = [(t.turn_index, tu["step"], tu["name"])
             for t in index_session(lines) for tu in t.tool_uses]
    mine = [(row[1], row[2], row[3]) for row in walk(lines) if row[0] == "tool"]
    assert mine == truth, "gate walk diverged from dm_parse.index_session"

# ---- the gate model --------------------------------------------------------
def simulate(lines, dedup="session", scope_set=ALL_TOOLS):
    """Returns per-tool-call firing records: list of (turn, step, name, fired_L1, fired_L2, fired_L3).
    L1 = in-scope tool; L2 = L1 + nonempty query entities; L3 = L2 + relevant(earlier-established) + novel(dedup)."""
    established = set()        # entities seen earlier in session (relevance pool)
    surfaced = set()          # entities already shown (UserPromptSubmit prompt ents + prior fires)
    fired_turn = set()
    recs = []
    for row in walk(lines):
        kind = row[0]
        if kind == "prompt":
            ents = entities(row[2])
            established |= ents
            surfaced |= ents               # UserPromptSubmit surfaces prompt-related breadcrumbs
            fired_turn = set()
            continue
        if kind == "text":
            established |= entities(row[2])
            continue
        # kind == tool
        turn, step, name, inp = row[1], row[2], row[3], row[4]
        scope = in_scope(name, inp, scope_set)
        qe = query_entities(name, inp) if scope else set()
        l1 = scope
        l2 = scope and bool(qe)
        l3 = False
        if l2:
            relevant = {e for e in qe if e in established}
            seen = surfaced if dedup == "session" else (surfaced | fired_turn)
            novel = relevant - (surfaced if dedup == "session" else seen)
            if dedup == "turn":
                novel = relevant - fired_turn - surfaced
            if novel:
                l3 = True
                if dedup == "session":
                    surfaced |= novel
                else:
                    fired_turn |= novel
        recs.append((turn, step, name, l1, l2, l3))
        established |= qe
    return recs


def run(dedup="session", scope_set=ALL_TOOLS, scope_label="ALL", per_tool=False):
    mani = {s["session_id"]: s for s in json.load(open(os.path.join(DRIFTMINE, "manifest.json")))["sessions"]}
    sub = [s for s in mani.values() if s["substantive"]]
    records = json.load(open(os.path.join(DRIFTMINE, "records.json")))
    # drift events keyed by (session, turn) -> list of (step, location, mid_turn)
    drift = {}
    for blob in records:
        sid = blob["session_record"]["session_id"]
        for d in blob.get("drift_events", []):
            drift.setdefault((sid, d.get("turn_index")), []).append(
                (d.get("step_within_turn") or 0, d.get("retrievable_fact_location"),
                 not d.get("intervening_user_prompt")))

    total_calls = 0
    fires = {"L1": 0, "L2": 0, "L3": 0}
    fire_points = []          # (sid, turn, step) of L3 fires
    by_tool = {}
    for s in sub:
        lines = load_jsonl(s["path"])
        assert_consistency(lines)
        for (turn, step, name, l1, l2, l3) in simulate(lines, dedup=dedup, scope_set=scope_set):
            total_calls += 1
            fires["L1"] += l1; fires["L2"] += l2; fires["L3"] += l3
            if l3:
                fire_points.append((s["session_id"], turn, step))
                by_tool[name] = by_tool.get(name, 0) + 1

    # precision/recall of L3 fires vs catchable drift (earlier_in_session & mid-turn)
    catchable = [(sid, t, st) for (sid, t), evs in drift.items()
                 for (st, loc, mid) in evs if loc == "earlier_in_session" and mid]
    tp_fires = 0
    for (sid, t, st) in fire_points:
        evs = drift.get((sid, t), [])
        if any(loc == "earlier_in_session" and mid and st <= dst
               for (dst, loc, mid) in evs):
            tp_fires += 1
    caught = 0
    for (sid, t, dst) in catchable:
        if any(fsid == sid and ft == t and fst <= dst for (fsid, ft, fst) in fire_points):
            caught += 1

    fr = 100*fires['L3']/total_calls
    prec = 100*tp_fires/fires['L3'] if fires['L3'] else 0
    rec = 100*caught/len(catchable) if catchable else 0
    print(f"\n--- scope={scope_label}  dedup={dedup} ---")
    print(f"  L1 in-scope: {100*fires['L1']/total_calls:.1f}%  L2 +signal: {100*fires['L2']/total_calls:.1f}%  "
          f"L3 gate: {fr:.1f}/100 ({fr/2.3:.1f}x base)")
    print(f"  precision={prec:.0f}% ({tp_fires}/{fires['L3']})  recall={rec:.0f}% ({caught}/{len(catchable)})")
    if per_tool:
        print("  L3 fires by tool: " + ", ".join(f"{k}={v}" for k, v in sorted(by_tool.items(), key=lambda x: -x[1])))
    return fr


if __name__ == "__main__":
    print(f"total tool calls (PreToolUse evaluations): 9205   base drift rate = 2.3/100 (FP budget)")
    print("\n================ SCOPE x DEDUP SWEEP ================")
    run(dedup="session", scope_set=ALL_TOOLS, scope_label="ALL (incl file_path Read/Edit/Write)", per_tool=True)
    run(dedup="turn", scope_set=ALL_TOOLS, scope_label="ALL")
    run(dedup="session", scope_set=STRONG_TOOLS, scope_label="STRONG (Grep/Glob/Agent/Web only)", per_tool=True)
    run(dedup="turn", scope_set=STRONG_TOOLS, scope_label="STRONG")
    print("\nrule: near 2.3 -> BUILD;  ~10x (>=~23) -> STOP.  3-5x = gray zone (tighten/decide).")
