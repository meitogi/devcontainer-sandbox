#!/usr/bin/env bash
# Tests for bin/devc-sweep. Standalone — no root, no network, no Docker.
# Usage: bash test/devc-sweep.test.sh
#
# Everything runs against a scratch tree (TMP_ROOT / CLAUDE_TMP / LOCAL_DIR):
# the real /tmp and ~/.claude are never read or written here. Every "kept"
# case is the defect this command could cause — deleting something in use —
# so each one is asserted by the path still being there, not by the report.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
SWEEP="${SWEEP:-$REPO/bin/devc-sweep}"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
gone() { [ ! -e "$2" ] && ok "$1" || ko "$1" "still there" "removed"; }
kept() { [ -e "$2" ] && ok "$1" || ko "$1" "removed" "kept"; }

# An empty W would aim TMP_ROOT at the real /tmp and setup()'s rm -rf at /tmp.
W=$(mktemp -d) && [ -d "$W" ] || { echo "$(basename "$0"): mktemp failed (disk full?) — refusing to run on an empty path" >&2; exit 2; }
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null; done; rm -rf "$W"' EXIT

T="$W/tmp"; C="$W/tmp/claude-1000"; L="$W/local"
export TMP_ROOT="$T" CLAUDE_TMP="$C" LOCAL_DIR="$L"

old() { find "$1" -exec touch -h -d '3 days ago' {} +; }      # idle for 3 days
ancient() { find "$1" -exec touch -h -d '40 days ago' {} +; } # past --archive-days
U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333

# A live claude session as the CLI registers it: its pid, and that pid's start
# time read the same way the script reads it.
live_session() {  # <sessionId> → pid of a sleeping stand-in
  sleep 600 & local pid=$!; BG="$BG $pid"
  local start; start=$(python3 -c 'import sys;s=open("/proc/%s/stat"%sys.argv[1]).read();print(s[s.rindex(")")+2:].split()[19])' "$pid")
  mkdir -p "$L/sessions"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","cwd":"/workspace"}\n' "$pid" "$1" "$start" > "$L/sessions/$pid.json"
}

setup() {
  rm -rf "$T" "$L"; mkdir -p "$T" "$C/-workspace" "$L/projects/-workspace"
  # tmp: mkdtemp-shaped and idle → candidate
  mkdir -p "$T/bot-exos-AbC123/deep"; echo x > "$T/bot-exos-AbC123/deep/f"; old "$T/bot-exos-AbC123"
  mkdir -p "$T/tmp.AbCdEf1234"; old "$T/tmp.AbCdEf1234"
  # tmp: idle dir with ONE recent file deep inside → kept
  mkdir -p "$T/recent-XyZ789/a/b"; old "$T/recent-XyZ789"; echo y > "$T/recent-XyZ789/a/b/new"
  # tmp: not mkdtemp-shaped → kept whatever its age
  mkdir -p "$T/node-compile-cache" "$T/vscode-git-4ed88fbb87"; old "$T/node-compile-cache"; old "$T/vscode-git-4ed88fbb87"
  # tmp: a FILE with a mkdtemp-shaped name → kept (directories only)
  echo z > "$T/notadir-QwE456"; touch -d '3 days ago' "$T/notadir-QwE456"
  # tmp: idle but a process sits in it → kept
  mkdir -p "$T/busy-Busy01"; old "$T/busy-Busy01"
  (cd "$T/busy-Busy01" && exec sleep 600) & BG="$BG $!"
  # scratch: ended session, idle → candidate ; live session, idle → kept
  mkdir -p "$C/-workspace/$U1/scratchpad"; echo s > "$C/-workspace/$U1/scratchpad/s"; old "$C/-workspace/$U1"
  mkdir -p "$C/-workspace/$U2/scratchpad"; old "$C/-workspace/$U2"
  live_session "$U2"
  # scratch: a non-session neighbour → kept
  mkdir -p "$C/bash-edit-diff"; old "$C/bash-edit-diff"
  # transcripts: ancient + side dir → archived ; ancient but live → kept ; recent → kept
  P="$L/projects/-workspace"
  printf '{"a":1}\n{"b":2}\n' > "$P/$U1.jsonl"; mkdir -p "$P/$U1/subagents"; echo sub > "$P/$U1/subagents/x.jsonl"
  ancient "$P/$U1.jsonl"; ancient "$P/$U1"
  echo '{}' > "$P/$U2.jsonl"; ancient "$P/$U2.jsonl"
  echo '{}' > "$P/$U3.jsonl"
  sleep 0.3  # let the busy sleeper chdir before the scan
}

echo "devc-sweep"
bash -n "$SWEEP" && ok "parses" || ko "parses" "syntax error" "parses"

echo "-- report only"
setup
OUT=$("$SWEEP" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "exits 0" || ko "exits 0" "$RC" "0"
kept "report touches nothing: tmp candidate"        "$T/bot-exos-AbC123"
kept "report touches nothing: scratch candidate"    "$C/-workspace/$U1"
kept "report touches nothing: transcript"           "$L/projects/-workspace/$U1.jsonl"
echo "$OUT" | grep -q "bot-exos-AbC123" && ok "report lists the tmp candidate" || ko "report lists the tmp candidate" "$OUT" "bot-exos-AbC123"
echo "$OUT" | grep -q "$U2" && ko "report never lists the live session" "$U2 listed" "absent" || ok "report never lists the live session"
echo "$OUT" | grep -qF 'run `devc-sweep --apply`' && ok "the hint names devc-sweep by default" || ko "the hint names devc-sweep by default" "$OUT" 'run `devc-sweep --apply`'
OUT=$(DEVC_SWEEP_APPLY_HINT="wtf cleanup --apply" DEVC_SWEEP_SUMMARY=1 "$SWEEP" 2>&1)
echo "$OUT" | grep -qF 'run `wtf cleanup --apply`' && ok "a wrapper can name its own command" || ko "a wrapper can name its own command" "$OUT" 'run `wtf cleanup --apply`'
got=$(echo "$OUT" | tail -1 | sed -E 's/=([0-9]+):[0-9]+/=\1/g')
[ "$got" = "@@devc-sweep tmp=2 scratch=1 archive=1" ] && ok "the wrapper summary line counts each kind" || ko "the wrapper summary line counts each kind" "$got" "@@devc-sweep tmp=2 scratch=1 archive=1"

echo "-- apply"
OUT=$("$SWEEP" --apply 2>&1); RC=$?
[ "$RC" = 0 ] && ok "exits 0" || ko "exits 0" "$RC — $OUT" "0"
gone "idle mkdtemp dir removed"                     "$T/bot-exos-AbC123"
gone "idle tmp.XXXXXXXXXX dir removed"              "$T/tmp.AbCdEf1234"
kept "one recent file deep inside keeps the dir"    "$T/recent-XyZ789/a/b/new"
kept "a name without mkdtemp's shape is kept"       "$T/node-compile-cache"
kept "a vscode socket dir is kept"                  "$T/vscode-git-4ed88fbb87"
kept "a FILE with a mkdtemp name is kept"           "$T/notadir-QwE456"
kept "a dir a process sits in is kept"              "$T/busy-Busy01"
kept "the CLAUDE_TMP root itself is kept"           "$C"
gone "ended session's scratch dir removed"          "$C/-workspace/$U1"
kept "live session's scratch dir is kept"           "$C/-workspace/$U2"
kept "a non-session dir in CLAUDE_TMP is kept"      "$C/bash-edit-diff"
P="$L/projects/-workspace"; A="$L/archive/projects/-workspace"
gone "ancient transcript moved out of /resume"      "$P/$U1.jsonl"
gone "…with its side dir"                           "$P/$U1"
kept "…into an archive"                             "$A/$U1.tar.gz"
kept "ancient but live transcript is kept"          "$P/$U2.jsonl"
kept "recent transcript is kept"                    "$P/$U3.jsonl"

echo "-- restore"
OUT=$("$SWEEP" list-archived 2>&1)
echo "$OUT" | grep -q "$U1" && ok "list-archived names it" || ko "list-archived names it" "$OUT" "$U1"
OUT=$("$SWEEP" restore 1111 2>&1); RC=$?
[ "$RC" = 0 ] && ok "restore by id prefix exits 0" || ko "restore by id prefix exits 0" "$RC — $OUT" "0"
got=$(cat "$P/$U1.jsonl" 2>/dev/null)
[ "$got" = "$(printf '{"a":1}\n{"b":2}')" ] && ok "transcript is byte-identical" || ko "transcript is byte-identical" "$got" '{"a":1} {"b":2}'
[ "$(cat "$P/$U1/subagents/x.jsonl" 2>/dev/null)" = sub ] && ok "side dir restored" || ko "side dir restored" "missing" "sub"
gone "the archive is consumed"                      "$A/$U1.tar.gz"

echo "-- refusals"
"$SWEEP" --apply >/dev/null 2>&1        # archive U1 again
echo '{"new":1}' > "$P/$U1.jsonl"       # a transcript reappears under the same id
OUT=$("$SWEEP" restore "$U1" 2>&1); RC=$?
[ "$RC" != 0 ] && ok "restore refuses to overwrite" || ko "restore refuses to overwrite" "rc 0" "non-zero"
[ "$(cat "$P/$U1.jsonl")" = '{"new":1}' ] && ok "…and the existing transcript is untouched" || ko "…and the existing transcript is untouched" "$(cat "$P/$U1.jsonl")" '{"new":1}'
OUT=$("$SWEEP" restore 9999 2>&1); RC=$?
[ "$RC" != 0 ] && ok "unknown id is refused" || ko "unknown id is refused" "rc 0" "non-zero"

# A failed archive must leave the originals where they were. A file where the
# archive dir should be, not a chmod 500 dir: root writes through the mode, and
# run-all.sh replays this suite as root inside the image.
setup
mkdir -p "$L/archive/projects"; : > "$L/archive/projects/-workspace"
OUT=$("$SWEEP" --apply 2>&1); RC=$?
rm -f "$L/archive/projects/-workspace"
[ "$RC" != 0 ] && ok "a failed archive exits non-zero" || ko "a failed archive exits non-zero" "rc 0" "non-zero"
kept "a failed archive keeps the transcript"        "$L/projects/-workspace/$U1.jsonl"
kept "…and its side dir"                            "$L/projects/-workspace/$U1/subagents/x.jsonl"

echo "-- archived conversations: list, read, restore"
setup
P="$L/projects/-workspace"; Q="$L/projects/-other"; mkdir -p "$Q"
U4=44444444-4444-4444-4444-444444444444; U5=55555555-5555-5555-5555-555555555555
cat > "$P/$U4.jsonl" <<'J'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the firewall reload"}]},"timestamp":"2026-09-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"SECRET-THOUGHT"},{"type":"text","text":"Reloading now."},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Bash"}]},"timestamp":"2026-09-01T10:00:05Z"}
{"type":"ai-title","aiTitle":"AI named firewall"}
{"type":"custom-title","customTitle":"Firewall reload fix"}
J
printf '%s\n' '{"type":"ai-title","aiTitle":"Docker cleanup talk"}' > "$P/$U5.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Other project chat"}' > "$Q/$U4.jsonl.tmp" && mv "$Q/$U4.jsonl.tmp" "$Q/66666666-6666-6666-6666-666666666666.jsonl"
ancient "$P"; ancient "$Q"
"$SWEEP" --apply >/dev/null 2>&1
LIST=$("$SWEEP" archived --project -workspace 2>&1)
echo "$LIST" | grep -q "Firewall reload fix" && ok "archived shows the custom title" || ko "archived shows the custom title" "$LIST" "Firewall reload fix"
echo "$LIST" | grep -q "AI named firewall" && ko "custom title wins over the AI title" "AI title shown" "custom only" || ok "custom title wins over the AI title"
echo "$LIST" | grep -q "Other project chat" && ko "archived lists the given project only" "other project listed" "absent" || ok "archived lists the given project only"
M=$("$SWEEP" archived --project -workspace --match DOCKER 2>&1)
echo "$M" | grep -q "Docker cleanup talk" && ! echo "$M" | grep -q "Firewall" && ok "--match filters titles, any case" || ko "--match filters titles, any case" "$M" "Docker only"
SHOW=$("$SWEEP" show 4444 --plain 2>&1)
echo "$SHOW" | grep -q "Fix the firewall reload" && echo "$SHOW" | grep -q "Reloading now." && ok "show prints what you and claude said" || ko "show prints what you and claude said" "$SHOW" "both messages"
echo "$SHOW" | grep -q "SECRET-THOUGHT" && ko "show hides the thinking" "thinking shown" "hidden" || ok "show hides the thinking"
echo "$SHOW" | grep -qF "[tools: Bash ×2]" && ok "show folds a run of tool calls" || ko "show folds a run of tool calls" "$SHOW" "[tools: Bash ×2]"
kept "show restores nothing" "$L/archive/projects/-workspace/$U4.tar.gz"
# An archive from before the index: its title is read from the tar, then indexed.
rm -f "$L/archive/index.tsv"
"$SWEEP" archived --project -workspace 2>&1 | grep -q "Firewall reload fix" && ok "a pre-index archive still shows its title" || ko "a pre-index archive still shows its title" "missing" "title"
grep -q "$U4" "$L/archive/index.tsv" 2>/dev/null && ok "…and is indexed for next time" || ko "…and is indexed for next time" "absent" "indexed"
OUT=$("$SWEEP" restore 4444 5555 2>&1); RC=$?
[ "$RC" = 0 ] && [ -f "$P/$U4.jsonl" ] && [ -f "$P/$U5.jsonl" ] && ok "restore takes several ids" || ko "restore takes several ids" "$RC — $OUT" "both back"
"$SWEEP" --apply >/dev/null 2>&1   # archive them again
echo '{"new":1}' > "$P/$U5.jsonl"    # U5 reappears under the same id
OUT=$("$SWEEP" restore --all --yes --project -workspace 2>&1)
[ -f "$P/$U4.jsonl" ] && ok "restore --all brings the project back" || ko "restore --all brings the project back" "$OUT" "U4 back"
[ "$(cat "$P/$U5.jsonl")" = '{"new":1}' ] && ok "…skipping an id already in /resume, untouched" || ko "…skipping an id already in /resume, untouched" "$(cat "$P/$U5.jsonl")" '{"new":1}'
echo "$OUT" | grep -q "skipped 1" && ok "…and says so" || ko "…and says so" "$OUT" "skipped 1"
kept "restore --all leaves another project's archive" "$L/archive/projects/-other/66666666-6666-6666-6666-666666666666.tar.gz"
OUT=$(setsid -w "$SWEEP" restore --all --project -other </dev/null 2>&1); RC=$?   # setsid: no controlling terminal, even when the suite runs in one
[ "$RC" = 2 ] && kept "…and without --yes nor a terminal, asks and does nothing" "$L/archive/projects/-other/66666666-6666-6666-6666-666666666666.tar.gz" || ko "without --yes nor a terminal, refuse" "$RC" "2"

echo "-- gain and current project"
setup
PR="$W/proj"; mkdir -p "$PR/sub"; SL=$(printf '%s' "$PR" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$L/projects/$SL"; U7=77777777-7777-7777-7777-777777777777
for i in $(seq 1 400); do printf '{"type":"user","message":{"content":"the same line again %s"}}\n' "$((i % 3))"; done > "$L/projects/$SL/$U7.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Sub project chat"}' >> "$L/projects/$SL/$U7.jsonl"
ancient "$L/projects/$SL"
OUT=$("$SWEEP" 2>&1)
echo "$OUT" | grep -qE "→ .*archived, .* gained" && ok "the report says what an archive gains" || ko "the report says what an archive gains" "$OUT" "X → Y archived, Z gained"
"$SWEEP" --apply >/dev/null 2>&1
LIST=$(cd "$PR/sub" && "$SWEEP" archived 2>&1)
echo "$LIST" | grep -q "Sub project chat" && ok "from a subdirectory, the project is the parent Claude knows" || ko "from a subdirectory, the project is the parent Claude knows" "$LIST" "Sub project chat"

echo "-- arguments"
"$SWEEP" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option → usage (2)" || ko "unknown option → usage (2)" "$?" "2"
"$SWEEP" --tmp-hours -1 >/dev/null 2>&1; [ $? = 2 ] && ok "negative hours → usage (2)" || ko "negative hours → usage (2)" "$?" "2"

echo
echo "devc-sweep: $PASS pass / $FAIL fail"
[ "$FAIL" = 0 ]
