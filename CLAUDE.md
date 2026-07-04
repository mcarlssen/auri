# Auri — notes for AI agents

Auri is a native macOS (SwiftUI/AppKit) menu-bar app that runs the BirdNET
CoreML model on live microphone audio (or an audio file) to identify birds.
Source lives under `Auri/` (`App/`, `Audio/`, `Core/`, `Models/`, `Server/`,
`UI/`). See `PROJECT_SPEC.md` for the product spec.

## Code intelligence: use CodeGraph first

This repo ships a **CodeGraph** MCP server (configured in `.mcp.json`). It
indexes every symbol, call edge, and file into a local knowledge graph.

Prefer the `codegraph_explore` tool over reading files by hand to answer
"how does X work / how does X reach Y" and to see a change's blast radius
before editing — it returns verbatim, line-numbered source grouped by file
plus the call paths between symbols, in far fewer tokens and round-trips.

The index (`.codegraph/`) is local and gitignored. In Claude Code on the web
it is (re)built automatically by `.claude/hooks/session-start.sh`; locally,
run `codegraph init` once and it auto-syncs on save.

## Building

Xcode project: `Auri.xcodeproj`. The app builds on macOS via Xcode; there is
no Swift toolchain on Linux web containers, so compilation is verified by CI
(the PR build check), not in-session.
