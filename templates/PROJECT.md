# Project rules

Shared rules for every agent working in this repo. This file is the **single
source of truth** and is imported by:

- `CLAUDE.md` → Claude Code (forge orchestrator; adds `FORGE.md`),
- `AGENTS.md` → Codex (forge worker; adds the worker rules).

Edit project rules **here**, not in the role files. Don't put anything here
that applies to only one role.

## Environment

- How to install dependencies:
- How to run the app:

## Quality gate

State the exact command a worker must pass before finishing, e.g.:

| Command | What it does |
|---|---|
| `make check` | lint + tests — the acceptance check |

## Code

- Match the style of surrounding code: comment density, naming, idioms.

## Conventions

- Anything an agent could get wrong by guessing: traps, tools that must not be
  run, files that must not be touched.

## Byte-exact data (if any)

If this repo stores downloaded files whose exact bytes are the evidence
(fixtures, specs, samples) and tests compare their hashes, those paths need
`-text` in `.gitattributes`. Otherwise `core.autocrlf` rewrites line endings on
commit: the main checkout keeps the original bytes and the tests pass, while a
fresh worktree gets the normalized blob and they fail for every worker.
List those paths here so an agent knows not to reformat or re-save them.
