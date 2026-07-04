#!/bin/bash
set -euo pipefail

# Build the CodeGraph index so the `codegraph` MCP server (declared in
# .mcp.json) has a knowledge graph to serve. The index lives in .codegraph/
# and is local to each machine (gitignored), so every fresh web session
# rebuilds it from the current checkout.
#
# Only needed in ephemeral remote (Claude Code on the web) containers; a local
# checkout keeps its own persistent .codegraph/ index that auto-syncs on save.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

export CODEGRAPH_TELEMETRY=0
cd "${CLAUDE_PROJECT_DIR:-.}"

# `init --force` is idempotent: it (re)builds the full graph in one step.
npx -y @colbymchenry/codegraph init --force
