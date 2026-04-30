#!/usr/bin/env bash
# brainspike probe: graphify
# Searches a graphify-out/graph.json knowledge graph for the current project.

PROBE_NAME="graphify"
PROBE_DESCRIPTION="graphify knowledge graph"
PROBE_GRAPH="${GRAPHIFY_GRAPH:-graphify-out/graph.json}"

probe_detect() {
    command -v graphify >/dev/null 2>&1 && [ -f "$PROBE_GRAPH" ]
}

probe_test_query() {
    timeout 3 graphify query "test" --budget 50 --graph "$PROBE_GRAPH" >/dev/null 2>&1
}

probe_query() {
    local query="$1"
    # graphify query returns a free-form answer with cited nodes; we extract the
    # node references that show up as bullet/labelled lines.
    timeout 3 graphify query "$query" --budget 600 --graph "$PROBE_GRAPH" 2>/dev/null \
        | grep -oE '(\* |- |\* \*|^Node: |"[^"]{5,80}"|\[[^][]{3,80}\])' \
        | sed -E 's/^[* -]+//' \
        | sed -E 's/^"|"$//g' \
        | sed -E 's/^\[|\]$//g' \
        | awk 'NF && !seen[$0]++' \
        | head -5 \
        | while IFS= read -r node; do
            echo "  - $node"
        done
}

probe_breadcrumb() {
    echo "graphify query \"<query>\" --graph $PROBE_GRAPH"
}
