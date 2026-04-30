#!/usr/bin/env bash
# brainspike probe: claude-mem
# Searches the claude-mem cross-session memory SQLite database via FTS5.

PROBE_NAME="claude-mem"
PROBE_DESCRIPTION="claude-mem cross-session memory database"
PROBE_DB="${CLAUDE_MEM_DB:-$HOME/.claude-mem/claude-mem.db}"

probe_detect() {
    [ -f "$PROBE_DB" ] && command -v python3 >/dev/null 2>&1
}

probe_test_query() {
    timeout 3 python3 - "$PROBE_DB" <<'PY' >/dev/null 2>&1
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=2)
con.execute("SELECT 1 FROM observations_fts LIMIT 1").fetchone()
PY
}

probe_query() {
    local query="$1"
    timeout 3 python3 - "$PROBE_DB" "$query" <<'PY'
import sqlite3, sys, re

db, raw = sys.argv[1], sys.argv[2]

stop = {"that","this","with","from","what","when","where","which","were","have","does","they","there","then","also","into","like","want","need","please","make","tell","just","about","some","find","show","look","using","could","would","should"}
words = [w for w in re.findall(r"[A-Za-z][A-Za-z0-9_-]{2,}", raw) if w.lower() not in stop]
seen = set()
words = [w for w in words if not (w.lower() in seen or seen.add(w.lower()))][:6]
if not words:
    sys.exit(0)

match = " OR ".join(f'"{w}"' for w in words)

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
    rows = con.execute(
        """
        SELECT o.title, o.subtitle, o.project,
               date(o.created_at_epoch / 1000, 'unixepoch') AS day
        FROM observations_fts fts
        JOIN observations o ON o.id = fts.rowid
        WHERE observations_fts MATCH ?
        ORDER BY bm25(observations_fts), o.created_at_epoch DESC
        LIMIT 5
        """,
        (match,)
    ).fetchall()
    for title, subtitle, project, day in rows:
        title = (title or subtitle or "(untitled)").strip()
        title = re.sub(r"\s+", " ", title)
        if len(title) > 80:
            title = title[:77] + "..."
        meta = f"{project or 'unknown'}, {day or 'unknown'}"
        print(f'  - "{title}" ({meta})')
except Exception:
    pass
PY
}

probe_breadcrumb() {
    echo 'mcp__plugin_claude-mem_mcp-search__search query="<query>"  (or /mem-search)'
}
