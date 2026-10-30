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

# agent_set is a read-modify-write: jq reads the file, mv replaces it a moment
# later. mv is atomic, so the file is never torn — but two writers racing on the
# same agent would both read the old JSON and the second mv would discard the
# first one's field. The symptom is a status that appears to move backwards,
# which is why this is locked rather than left to chance.
#
# mkdir is the primitive: atomic on every POSIX filesystem, and present
# everywhere. flock is Linux-only (macOS has no such binary — checked), and
# shlock is built around PID files for long-lived daemons, not for a critical
# section measured in milliseconds.
#
# Held only around one jq+mv, so waiting is short. A holder killed mid-write
# (Ctrl-C in a worker window, a tmux window closed) would otherwise leave the
# directory behind and block every later write forever, so the lock records its
# owner's pid and a waiter reclaims it once that process is gone. The timeout
# is only how long to wait before checking that; a LIVE holder is waited on for
# as long as it takes.
FORGE_LOCK_TIMEOUT="${FORGE_LOCK_TIMEOUT:-10}"

agent_lock() { # agent_lock <lockdir> — blocks until held, or reclaims a dead one
  local lock="$1" waited=0 holder
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [[ $waited -lt $((FORGE_LOCK_TIMEOUT * 10)) ]] && continue
    waited=0

    # Liveness, not age. The first version of this compared the lock
    # directory's mtime against the timeout and robbed a holder that was simply
    # slow — measured: a writer holding the lock for 6s lost it after 3. A
    # directory's mtime does not advance while it is held, so age says when the
    # lock was TAKEN, never whether its owner is still working.
    #
    # kill -0 tests for a live process without signalling it. A PID can be
    # reused, but only after the original exited, and then the lock is free to
    # take anyway. A lock with no readable PID (killed between mkdir and the
    # write below) is also reclaimed: nothing can be waiting on it.
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      info "waiting for $(basename "$lock") held by pid $holder"
      continue
    fi
    info "reclaiming $(basename "$lock") from dead pid ${holder:-unknown}"
    rm -rf "$lock"
  done
  # $$ inside a subshell is the PARENT's pid, which is correct here: that is
  # the process whose death should release the lock.
  echo $$ > "$lock/pid" 2>/dev/null || true
}

# agent_set <name> key=value ...  (merges into the agent's JSON, updates timestamp)
agent_set() {
  local name="$1"; shift
  local f tmp lock args=() filter='.'
  f="$(agent_file "$name")"; lock="$f.lock"
  local i=0 kv
  for kv in "$@"; do
    args+=(--arg "k$i" "${kv%%=*}" --arg "v$i" "${kv#*=}")
    filter+=" | .[\$k$i] = \$v$i"
    i=$((i+1))
  done
  filter+=' | .updated = (now | todate)'

  agent_lock "$lock"
  # mktemp, not "$f.tmp.$$": a subshell inherits its parent's $$, so parallel
  # `( agent_set ... ) &` writers all built the SAME temp name and clobbered
  # each other's file mid-write — measured, it left unreadable JSON behind.
  # The lock alone would prevent that now, but a temp name that is unique on
  # its own does not depend on the lock being correct.
  tmp="$(mktemp "$f.tmp.XXXXXX")"
  # The trap covers a kill between here and the release below: without it the
  # directory would outlive the process and every later write would pay the
  # full timeout before stealing it.
  trap 'rm -rf "$lock"; rm -f "$tmp"' EXIT INT TERM
  # Inside the lock, so a concurrent writer cannot create it between the test
  # and the write.
  [[ -f "$f" ]] || echo '{}' > "$f"
  jq "${args[@]}" "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
  local rc=$?
  rm -f "$tmp"
  rm -rf "$lock"
  trap - EXIT INT TERM
  return $rc
}

# --- models (see models.conf) -------------------------------------------------
MODELS_FILE="${FORGE_MODELS_FILE:-$FORGE_HOME/models.conf}"
COMMANDS_FILE="${FORGE_COMMANDS_FILE:-$FORGE_HOME/commands.conf}"

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
#   - command(X) names a program, not a pattern: command(pytest) allows
#     `pytest test_x.py`, and command(pytest*) matches nothing.
#   - EVERY program in a compound command needs its own rule. agy does not run
#     a bare `pytest test_t.py`; it builds
#         cd <worktree> && pytest test_t.py; echo "EXIT_STATUS: $?"
#     which needs cd, pytest AND echo. With only command(pytest) the whole
#     command is denied, and denied_actions says just "command" — never which
#     part was missing. cd and echo are therefore in commands.conf by default;
#     dropping them breaks almost every acceptance check.
# So the allowlist must name every program a worker may invoke, not just the
# one the task is about.
#
# The outer bound comes from commands.conf (or FORGE_AGY_COMMANDS, which
# replaces it). A worker may be given a narrower subset — see commands_narrow.

# The operator's upper bound, as a whitespace-separated list.
commands_bound() {
  if [[ -n "${FORGE_AGY_COMMANDS:-}" ]]; then
    echo "${FORGE_AGY_COMMANDS}"
    return
  fi
  # Strip comments (whole-line and trailing) and fold to one line.
  awk '{ sub(/#.*/, ""); print }' "$COMMANDS_FILE" 2>/dev/null | tr -s '[:space:]' ' '
}

# commands_narrow <requested...> -> the requested commands, refusing any that
# the bound does not permit. Called with no arguments it returns the whole
# bound, so a worker spawned without --commands is unchanged by this feature.
#
# The orchestrator reads task briefs, so it can be talked into asking for more
# than a task needs. It may therefore only ever pick a SUBSET: a request for
# something outside the bound fails the spawn and names it, making the decision
# to widen the operator's, taken once in commands.conf.
commands_narrow() {
  local bound; bound="$(commands_bound)"
  if [[ $# -eq 0 ]]; then echo "$bound"; return; fi
  # A bound of `*` is a literal rule for agy, not a shell glob, so pathname
  # expansion is off while splitting it — otherwise `*` would become the names
  # of the files in the current directory and grant those instead.
  set -f
  local unbounded=0 b
  for b in $bound; do [[ "$b" == "*" ]] && unbounded=1; done
  local out="" req ok
  for req in "$@"; do
    ok=$unbounded
    for b in $bound; do [[ "$req" == "$b" ]] && ok=1; done
    [[ $ok -eq 1 ]] || die "command '$req' is not allowed by $COMMANDS_FILE (allowed:$bound).
Ask the operator to add it there — widening the bound is their decision, not a worker's."
    out="$out $req"
  done
  set +f
  echo "$out"
}

# Explains a denial in terms of whichever limit actually caused it: a worker
# given a subset is usually fixed by widening that spawn's --commands, while a
# worker holding the whole bound needs commands.conf changed.
agy_denial_hint() {
  if [[ $# -gt 0 ]]; then
    echo " $* (a subset of $COMMANDS_FILE, chosen by --commands).
    Respawn with the command added to --commands, or add it to $COMMANDS_FILE if it is not there either."
  else
    echo " $(commands_bound)(everything in $COMMANDS_FILE).
    Add the command to $COMMANDS_FILE."
  fi
}

# agy_permissions [command...] — the --settings JSON for one agy run.
# With no arguments every command in the bound is granted.
agy_permissions() {
  local cmds rules
  cmds="$(commands_narrow "$@")"
  rules='"write_file(*)","replace(*)","read_file(*)","list_directory(*)","glob(*)","search_file_content(*)"'
  # Narrow by design: a build worker needs its acceptance check to run, and
  # naming the binaries keeps that from becoming "any command at all".
  # command(python3) was measured to allow python3 and refuse curl.
  # Same reason as in commands_narrow: `*` is a rule, not a glob.
  set -f
  local c
  for c in $cmds; do rules="$rules,\"command($c)\""; done
  set +f
  printf '{"permissions":{"allow":[%s]}}' "$rules"
}
