# shellcheck shell=bash
# Shared helpers for forge-* commands. Sourced, not executed.
set -euo pipefail

FORGE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_SESSION="${FORGE_SESSION:-forge}"

die()  { echo "forge: $*" >&2; exit 1; }
info() { echo "forge: $*" >&2; }

# Main repository root, even when called from inside a worktree.
forge_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "not inside a git repository"
  (cd "$common/.." && pwd)
}

ROOT="$(forge_root)"
STATE="$ROOT/.forge"
WT_ROOT="${FORGE_WT_ROOT:-$(dirname "$ROOT")/.forge-wt/$(basename "$ROOT")}"

mkdir -p "$STATE/agents" "$STATE/tasks" "$STATE/logs"
# Keep forge state out of git without touching .gitignore.
exclude="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
grep -qxF '/.forge/' "$exclude" 2>/dev/null || echo '/.forge/' >> "$exclude"

valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die "invalid agent name '$1' (use a-z, 0-9, '-', max 40)"
}

agent_file() { echo "$STATE/agents/$1.json"; }

agent_get() { # agent_get <name> <jq-field>
  local f; f="$(agent_file "$1")"
  [[ -f "$f" ]] || die "no such agent: $1"
  jq -r ".$2 // empty" "$f"
}

# agent_set <name> key=value ...  (merges into the agent's JSON, updates timestamp)
agent_set() {
  local name="$1"; shift
  local f tmp args=() filter='.'
  f="$(agent_file "$name")"; tmp="$f.tmp.$$"
  [[ -f "$f" ]] || echo '{}' > "$f"
  local i=0 kv
  for kv in "$@"; do
    args+=(--arg "k$i" "${kv%%=*}" --arg "v$i" "${kv#*=}")
    filter+=" | .[\$k$i] = \$v$i"
    i=$((i+1))
  done
  filter+=' | .updated = (now | todate)'
  jq "${args[@]}" "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- models (see models.conf) -------------------------------------------------
MODELS_FILE="${FORGE_MODELS_FILE:-$FORGE_HOME/models.conf}"

# Prints "<name>\t<description>" for each configured model.
models_list() {
  [[ -f "$MODELS_FILE" ]] || return 0
  awk '/^[[:space:]]*(#|$)/ {next} $1=="default" {next}
       { n=$1; $1=""; sub(/^[[:space:]]+/, ""); print n "\t" $0 }' "$MODELS_FILE"
}
model_default() {
  [[ -f "$MODELS_FILE" ]] || return 0
  awk '$1=="default" && NF>=2 {print $2; exit}' "$MODELS_FILE"
}
model_allowed() { models_list | cut -f1 | grep -qxF -- "$1"; }

ensure_session() {
  tmux has-session -t "$FORGE_SESSION" 2>/dev/null \
    || tmux new-session -d -s "$FORGE_SESSION" -n orchestrator -c "$ROOT"
}
