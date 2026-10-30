# shellcheck shell=bash
# Shared helpers for forge-* commands. Sourced, not executed.
set -euo pipefail

# -P resolves symlinks, because the guard below compares this against a path
# from git, which is always fully resolved. On macOS /tmp and /var are symlinks
# into /private, so an unresolved FORGE_HOME would never match and the guard
# would silently stop protecting.
FORGE_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

# forge is itself a git repo, so running forge-* inside the tool directory would
# treat the tool as the project and create state there. Catch that early.
if [[ "$ROOT" == "$FORGE_HOME" ]]; then
  die "run forge-* from your project repo, not from the forge tool directory ($FORGE_HOME)"
fi
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

# Prints "<name>\t<provider>\t<role>\t<description>" for each configured model.
# A line missing the provider/role columns is read as an old two-column file
# (name + description) and treated as a codex worker, so an existing
# models.conf keeps working after an upgrade.
models_list() {
  [[ -f "$MODELS_FILE" ]] || return 0
  awk '/^[[:space:]]*(#|$)/ {next} $1=="default" || $1=="slug" {next}
       {
         n=$1; p=$2; r=$3
         if (p ~ /^(codex|claude|antigravity)$/ && r ~ /^(worker|orchestrator|both)$/) {
           $1=$2=$3=""
         } else { p="codex"; r="worker"; $1="" }
         sub(/^[[:space:]]+/, "")
         print n "\t" p "\t" r "\t" $0
       }' "$MODELS_FILE"
}

# Models that may be spawned as workers (role worker or both).
models_workers() { models_list | awk -F'\t' '$3=="worker" || $3=="both"'; }
model_role() { models_list | awk -F'\t' -v m="$1" '$1==m {print $3; exit}'; }
model_default() {
  [[ -f "$MODELS_FILE" ]] || return 0
  awk '$1=="default" && NF>=2 {print $2; exit}' "$MODELS_FILE"
}
model_allowed() { models_list | cut -f1 | grep -qxF -- "$1"; }

ensure_session() {
  tmux has-session -t "$FORGE_SESSION" 2>/dev/null \
    || tmux new-session -d -s "$FORGE_SESSION" -n orchestrator -c "$ROOT"
}

# --- providers -----------------------------------------------------------------
# A provider is a CLI that can run a worker non-interactively. Each one differs
# in three ways that forge has to know about, so they are kept together here
# rather than spread across forge-run/forge-spawn/forge-usage:
#
#   argv      how to ask for a one-shot run, a model and a reasoning effort
#   usage     where the token counts land afterwards, and in what shape
#   limits    whether the plan's remaining quota is knowable at all
#
# Verified 2026-10-30 against codex-cli 0.163.0, claude 2.1.312, agy 1.4.11.
#
# The `gemini` provider was removed on 2026-10-30: Google stopped serving
# Gemini CLI to personal accounts (IneligibleTierError / UNSUPPORTED_CLIENT)
# and redirected them to Antigravity. `antigravity` reaches the Gemini models
# — and Claude and GPT-OSS besides — through the one CLI that still works.

provider_of() { # provider_of <model-name> -> codex|claude|antigravity
  local p
  p="$(awk -v m="$1" '/^[[:space:]]*(#|$)/ {next} $1=="default" || $1=="slug" {next}
                      $1==m {print $2; exit}' "$MODELS_FILE" 2>/dev/null)"
  echo "${p:-codex}"
}

provider_cmd() { # provider_cmd <provider> -> the executable to run
  case "$1" in
    codex)  echo "${FORGE_CODEX_CMD:-codex}" ;;
    claude) echo "${FORGE_CLAUDE_CMD:-claude}" ;;
    antigravity) echo "${FORGE_AGY_CMD:-agy}" ;;
    *) die "unknown provider '$1' (use: codex, claude, antigravity)" ;;
  esac
}

provider_known() { case "$1" in codex|claude|antigravity) return 0 ;; *) return 1 ;; esac; }

# The model slug that reaches the provider's CLI. For codex and claude the
# models.conf name IS the slug. Antigravity exposes three model families
# through one CLI, and two of them are also reachable through a provider of
# their own (`claude-sonnet-4-6` vs `sonnet`), so a forge name like
# "agy-sonnet" has to be mapped to the slug `agy models` prints — otherwise
# the name alone would not say which CLI to run it on.
provider_slug() { # provider_slug <provider> <model-name> -> slug for the CLI
  case "$1" in
    antigravity)
      awk -v m="$2" '/^[[:space:]]*(#|$)/ {next} $1=="slug" && $2==m {print $3; exit}' \
        "$MODELS_FILE" 2>/dev/null ;;
    *) echo "$2" ;;
  esac
}

# Antigravity auto-denies any tool it would otherwise have to prompt for, and
# still exits 0 with status SUCCESS — so a worker that was never allowed to
# write looks like a worker that chose not to. forge grants an explicit
# allowlist instead, and forge-run treats a denial as a failure.
#
# Rule syntax is action(target). Measured against agy 1.4.11:
#   - the target must be a glob: write_file(.) does not match, write_file(*) does
#   - the shell action is named `command`, not `run_shell_command`
#   - command(X) matches on the command's FIRST WORD and does not glob:
#     command(pytest) allows `pytest test_x.py`, but command(python3) does NOT
#     allow `python3 -m pytest`, and command(python3*) matches nothing.
# So FORGE_AGY_COMMANDS must name every binary a worker may invoke, and the
# task brief should ask for the plain form (`pytest x.py`, not `python3 -m
# pytest x.py`). command(*) allows anything and is the operator's call.
agy_permissions() {
  local cmds="${FORGE_AGY_COMMANDS:-}" rules
  rules='"write_file(*)","replace(*)","read_file(*)","list_directory(*)","glob(*)","search_file_content(*)"'
  # Narrow by design: a build worker needs its acceptance check to run, and
  # naming the binaries keeps that from becoming "any command at all".
  # command(python3) was measured to allow python3 and refuse curl.
  local c
  for c in $cmds; do rules="$rules,\"command($c)\""; done
  printf '{"permissions":{"allow":[%s]}}' "$rules"
}
