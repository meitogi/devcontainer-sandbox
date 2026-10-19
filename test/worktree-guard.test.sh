#!/usr/bin/env bash
# Tests for assets/opt/skills/worktree-guard/hook.js — the PreToolUse hook
# that keeps every `git worktree add` under <main repo>/.claude/worktrees/.
# Standalone — no root, no network, no Docker; needs node and git.
# Usage: bash test/worktree-guard.test.sh
#
# The hook is invoked DIRECTLY with a fabricated PreToolUse payload, against a
# throwaway repository. Each case asserts the decision AND, for a refusal, that
# the reason names the allowed directory — a deny that does not say where to
# go instead is the half of the contract a session acts on.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
HOOK="$REPO/assets/opt/skills/worktree-guard/hook.js"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }

TMP=$(mktemp -d)
# Under the dind TMPDIR (/workspace/.tmp) the scratch tree sits inside the
# workspace repository: stop git discovery at $TMP so "not a repository" holds.
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"
git init -q "$R"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$R/sub" "$TMP/elsewhere"
ALLOWED="$R/.claude/worktrees"

# run <cwd> <command> — prints "deny" or "allow"; the raw output lands in $TMP/out
run() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:process.argv[1],cwd:process.argv[2],tool_input:{command:process.argv[3]}}))' \
    "${TOOL:-Bash}" "$1" "$2" | node "$HOOK" > "$TMP/out" 2>"$TMP/err"
  local rc=$?
  [ "$rc" = 0 ] || { echo "exit-$rc"; return; }
  if grep -q '"permissionDecision":"deny"' "$TMP/out"; then echo deny
  elif [ -s "$TMP/out" ]; then echo "garbage"
  else echo allow; fi
}
expect() {  # expect <label> <allow|deny> <cwd> <command>
  local got; got=$(run "$3" "$4")
  if [ "$got" != "$2" ]; then ko "$1" "$got" "$2"; return; fi
  if [ "$2" = deny ] && ! grep -qF "$ALLOWED/<name>" "$TMP/out"; then
    ko "$1 (reason names the allowed dir)" "$(cat "$TMP/out")" "$ALLOWED/<name>"; return
  fi
  ok "$1"
}

echo "worktree-guard"
MANIFEST="$REPO/assets/opt/skills/worktree-guard/hooks.json"
if node --check "$HOOK" 2>/dev/null; then ok "hook.js parses"; else ko "hook.js parses" "syntax error" "parses"; fi
got=$(node -e 'const m=require(process.argv[1]).PreToolUse;console.log(m.length+" "+m[0].matcher+" "+m[0].hooks[0].command.replace(/^node \/workspace\/.devcontainer\/skills\//,""))' "$MANIFEST" 2>&1)
[ "$got" = "1 Bash worktree-guard/hook.js" ] && ok "hooks.json: one PreToolUse entry on Bash, naming the shipped hook.js" \
  || ko "hooks.json shape" "$got" "1 Bash worktree-guard/hook.js"
expect "default path, relative"                 allow "$R" 'git worktree add .claude/worktrees/feat -b feat'
expect "default path, absolute"                 allow "$TMP" "git worktree add $ALLOWED/feat"
expect "default path from a subdirectory"       allow "$R/sub" 'git worktree add ../.claude/worktrees/feat'
expect "default path through git -C"            allow "$TMP" "git -C $R worktree add .claude/worktrees/feat"
expect "default path after cd"                  allow "$TMP" "cd $R && git worktree add .claude/worktrees/feat"
expect "options before the path"                allow "$R" 'git worktree add -f --lock --reason "x y" -b feat .claude/worktrees/feat main'
expect "-- before the path"                     allow "$R" 'git worktree add -b feat -- .claude/worktrees/feat'
expect "other worktree subcommands"             allow "$R" 'git worktree list && git worktree remove .worktrees/old'
expect "not a git repository"                   allow "$TMP/elsewhere" 'git worktree add ../x'
expect "a word worktree that is not git"        allow "$R" 'echo git worktree add /tmp/x'
TOOL=Read expect "not a Bash call"              allow "$R" 'git worktree add .worktrees/x'

expect ".worktrees/ at the repo root"           deny "$R" 'git worktree add .worktrees/feat -b feat'
expect "sibling of the repo"                    deny "$R" 'git worktree add ../feat'
expect "/tmp"                                   deny "$R" 'git worktree add /tmp/feat'
expect "escape through .."                      deny "$R" 'git worktree add .claude/worktrees/../feat'
expect "the worktrees dir itself"               deny "$R" 'git worktree add .claude/worktrees'
expect "-b value is not the path"               deny "$R" 'git worktree add -b .claude/worktrees/x ../feat'
expect "second command of a chain"              deny "$R" 'git status; git worktree add ../feat'
expect "after cd elsewhere"                     deny "$TMP" "cd $R/sub && git worktree add feat"
expect "through git -C"                         deny "$TMP" "git -C $R worktree add ../feat"
expect "env prefix"                             deny "$R" 'GIT_TRACE=1 git worktree add ../feat'
expect "variable target"                        deny "$R" 'git worktree add "$HOME/feat"'
expect "command substitution target"            deny "$R" 'git worktree add $(mktemp -d)'
expect "no target"                              deny "$R" 'git worktree add'

echo
echo "worktree-guard: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
