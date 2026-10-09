#!/usr/bin/env bash
# session-signals.test.sh — the two session signals this image bakes.
#
# They live in different skill dirs on purpose : rollout-debt watches
# prepare-plan's own artifacts (plans/*/STATUS.md), so it ships beside that
# skill the way rollout-debt' hook ships beside /rollout-debt. session-gap watches
# the transcript clock and owns no skill's artifacts, so it stands alone.
#
# Both scripts are invoked DIRECTLY, never through ~/.claude/settings.json :
# sync-skills.sh only runs at container boot and only ever ADDS commands, so
# going through settings.json would test whenever the container last booted
# rather than what is on disk now.
#
# Fixtures are generated, not committed — mtimes (touch -d) and transcript
# timestamps (date -u -d) have to be relative to now for staleness and gap
# arithmetic to mean anything.
#
# Helpers are underscore-prefixed on purpose : run_tests discovers cases with
# `declare -F | awk '$3 ~ /^test_/'`, so a helper named test_* would be run as
# a test.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The skills this suite tests are the BAKED ones — assets/opt/skills/ is what
# the Dockerfile COPYs to /opt/devcontainer/base/skills/, and sync-skills then
# links them into a project. Testing a project's copy, as this suite did while
# it lived in a project tree, tested whatever that one tree happened to carry.
DEBT_DIR="$REPO/assets/opt/skills/prepare-plan"
GAP_DIR="$REPO/assets/opt/skills/session-gap"
DEBT="$DEBT_DIR/rollout-debt.js"
GAP="$GAP_DIR/hook.js"
AVAIL="$DEBT_DIR/model-availability.js"

# Resolved once : the availability tests below replace $PATH to control what
# spawnSync('claude', …) can find, which would also hide `node` itself if we
# invoked it by bare name under the same env wrapper.
NODE_BIN="$(command -v node)"

# The harness, inline. Every suite in this repo defines its own and there is no
# shared lib.sh here, deliberately: a second copy of one would be exactly the
# "canonical elsewhere" debt this image keeps paying off. lib.sh's signatures
# are preserved verbatim so the ~300 lines of test logic below are the same
# bytes they were in the project tree — a port of the harness, not a rewrite of
# the assertions, which is the only way to move 348 lines without silently
# changing what one of them demands.
PASS=0; FAIL=0; SKIP=0
_CURRENT_TEST=""
_FAILURES=()
_ok()  { PASS=$((PASS+1)); printf '  ✔ %s :: %s\n' "$_CURRENT_TEST" "$1"; }
_nok() { FAIL=$((FAIL+1)); _FAILURES+=("$_CURRENT_TEST :: $1")
         printf '  ✘ %s :: %s\n' "$_CURRENT_TEST" "$1" >&2; }

assert_true() {   # assert_true <cmd...> -- "label"
  local label="" arg; local cmd=(); local seen=0
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then seen=1; continue; fi
    if [ "$seen" -eq 1 ]; then label="$arg"; else cmd+=("$arg"); fi
  done
  if "${cmd[@]}" 2>/dev/null; then _ok "$label"
  else _nok "$label (cmd failed : ${cmd[*]})"; fi
}
assert_eq() {
  local expected="$1" actual="$2" label="${3:-eq}"
  if [ "$expected" = "$actual" ]; then _ok "$label"
  else _nok "$label : expected '$expected', got '$actual'"; fi
}
assert_file_exists() {
  local path="$1" label="${2:-file $1}"
  [ -f "$path" ] && _ok "$label" || _nok "$label : '$path' missing"
}
assert_contains() {
  local path="$1" needle="$2" label="${3:-contains}"
  [ -f "$path" ] || { _nok "$label : '$path' missing"; return; }
  grep -qF "$needle" "$path" && _ok "$label" || _nok "$label : '$needle' not in $path"
}
assert_not_contains() {
  local path="$1" needle="$2" label="${3:-not contains}"
  if [ -f "$path" ] && grep -qF "$needle" "$path"; then
    _nok "$label : '$needle' found in $path"
  else _ok "$label"; fi
}
assert_match() {
  local path="$1" re="$2" label="${3:-match}"
  [ -f "$path" ] || { _nok "$label : '$path' missing"; return; }
  grep -qE "$re" "$path" && _ok "$label" || _nok "$label : ERE '$re' no match in $path"
}

# Discovery is `declare -F`, which is why every helper here is underscore
# prefixed: a helper named test_* would be run as a case.
run_tests() {
  local fns n
  fns=$(declare -F | awk '$3 ~ /^test_/ {print $3}')
  if [ -z "$fns" ]; then
    printf '  no test_* functions found\n' >&2
    return 1
  fi
  for n in $fns; do _CURRENT_TEST="$n"; "$n"; done
  echo
  printf 'session-signals: %d pass / %d fail\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# --- helpers ---------------------------------------------------------------

# _iso_ago "4 hours" → 2026-07-30T06:03:40.000Z
_iso_ago() { date -u -d "-$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# _mk_plan <root> <name> <age> — STATUS.md body on stdin, whole dir aged.
_mk_plan() {
  local root="$1" name="$2" age="$3"
  mkdir -p "$root/$name"
  cat > "$root/$name/STATUS.md"
  touch -d "$age ago" "$root/$name"/*.md
}

# _mk_transcript <path> <pad-kb> — ISO timestamps on stdin, one per line.
_mk_transcript() {
  local path="$1" kb="${2:-0}" ts
  : > "$path"
  if [ "$kb" -gt 0 ]; then
    printf '{"type":"assistant","timestamp":"%s","pad":"%s"}\n' \
      "$(_iso_ago '30 days')" "$(head -c $((kb * 1024)) /dev/zero | tr '\0' 'x')" >> "$path"
  fi
  while IFS= read -r ts; do
    [ -n "$ts" ] && printf '{"type":"user","timestamp":"%s"}\n' "$ts" >> "$path"
  done
}

# The current submission burst : the incoming prompt is already in the
# transcript ~35ms before the hook runs (measured), so every fixture that
# stands in for a live UserPromptSubmit must carry it.
_burst() { _iso_ago '1 second'; _iso_ago '1 second'; _iso_ago '1 second'; }

_run_debt() { # _run_debt <out> <root> [days]
  ROLLOUT_DEBT_ROOT="$2" ROLLOUT_DEBT_DAYS="${3:-7}" node "$DEBT" > "$1" 2>/dev/null
}

_run_gap() { # _run_gap <out> <transcript> [hours] [min_kb]
  printf '{"session_id":"t","transcript_path":"%s","cwd":"/workspace","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$2" \
    | SESSION_GAP_HOURS="${3:-1}" SESSION_GAP_MIN_KB="${4:-0}" node "$GAP" > "$1" 2>/dev/null
}

_assert_silent() { assert_eq "" "$(cat "$1")" "$2"; }

# jq -e prints the matched value ; assert_true only silences stderr, so wrap it.
_jq_ok() { jq -e "$@" > /dev/null 2>&1; }

_assert_signal() { # _assert_signal <out> <expected event> <label>
  assert_eq "$2" "$(jq -r '.hookSpecificOutput.hookEventName' "$1" 2>/dev/null)" "$3 : event name"
  assert_true _jq_ok '.hookSpecificOutput.additionalContext | length > 40' "$1" -- "$3 : carries context"
}

_LEGEND='✅ delivered · 🚧 in progress · 📋 planned · ⚠️ blocked · ❌ cancelled'

# --- static contract -------------------------------------------------------

test_static_contract() {
  assert_file_exists "$DEBT" "rollout-debt.js exists"
  assert_file_exists "$GAP" "session-gap hook.js exists"
  assert_file_exists "$AVAIL" "model-availability.js exists"
  assert_true node --check "$DEBT" -- "rollout-debt.js parses"
  assert_true node --check "$GAP" -- "session-gap hook.js parses"
  assert_true node --check "$AVAIL" -- "model-availability.js parses"
  assert_true _jq_ok . "$DEBT_DIR/hooks.json" -- "prepare-plan hooks.json is valid JSON"
  assert_true _jq_ok . "$GAP_DIR/hooks.json" -- "session-gap hooks.json is valid JSON"
  assert_eq "startup" "$(jq -r '.SessionStart[0].matcher' "$DEBT_DIR/hooks.json")" \
    "SessionStart matcher is 'startup'"
  assert_eq "" "$(jq -r '.UserPromptSubmit[0].matcher' "$GAP_DIR/hooks.json")" \
    "UserPromptSubmit matcher is empty"

  # sync-skills.sh dedups by exact command string and never removes an entry :
  # a renamed script leaves a dead command running on every session start.
  #
  # The command names the RUNTIME path — /workspace/.devcontainer/skills/… —
  # which is where sync-skills links the baked skill, and which exists only in
  # a container that has a project. Checked literally, this assertion passes or
  # fails on where the suite happens to run, and in a devcontainer it passes by
  # accident: a false green on exactly the drift it exists to catch. The
  # invariant that IS checkable here is the one that matters — the script each
  # command names must exist in the skill directory that ships it.
  local cmd target dir
  while IFS= read -r cmd; do
    target="${cmd##* }"
    case "$target" in
      */skills/prepare-plan/*) dir="$DEBT_DIR" ;;
      */skills/session-gap/*)  dir="$GAP_DIR" ;;
      *) _nok "hooks.json command names an unknown skill : $target"; continue ;;
    esac
    assert_file_exists "$dir/${target##*/}" \
      "hooks.json command target ships : ${target##*/}"
  done < <(jq -r '.[][].hooks[].command' "$DEBT_DIR/hooks.json" "$GAP_DIR/hooks.json")
}

# `0` is a legitimate override, but `Number(x) || fallback` silently swallows
# it — the two hooks must honour it rather than fall back to their defaults.
test_env_overrides_honour_zero() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  # 2 days old : silent at the default 7, fires at 0 — so a fallback-to-7 bug
  # is indistinguishable from silence unless 0 is genuinely honoured.
  _mk_plan "$TMP" barely-open "2 days" <<MD
| Session | Status |
|---|---|
| 1 | 📋 |
MD
  _run_debt "$TMP/out.json" "$TMP" 0
  _assert_signal "$TMP/out.json" "SessionStart" "ROLLOUT_DEBT_DAYS=0"
  assert_contains "$TMP/out.json" "plans/barely-open" "days=0 flags a 2-day-old plan"

  _mk_transcript "$TMP/t.jsonl" 0 < <(_iso_ago '10 minutes'; _burst)
  _run_gap "$TMP/gap.json" "$TMP/t.jsonl" 0 0
  _assert_signal "$TMP/gap.json" "UserPromptSubmit" "SESSION_GAP_HOURS=0"

  # A non-numeric override falls back rather than turning into NaN.
  _run_debt "$TMP/junk.json" "$TMP" "not-a-number"
  _assert_silent "$TMP/junk.json" "a junk threshold falls back to the default"
}

# --- rollout-debt ----------------------------------------------------------

test_debt_no_plans_dir() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _run_debt "$TMP/out.json" "$TMP/does-not-exist"
  assert_eq "0" "$?" "missing plans root exits 0"
  _assert_silent "$TMP/out.json" "missing plans root is silent"
}

test_debt_skips_closed_plan() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" closed "90 days" <<MD
| Session | Status |
|---|---|
| 1 | ✅ |
| 2 | ✅ |
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_silent "$TMP/out.json" "a fully-closed plan is not debt"
}

test_debt_skips_fresh_plan() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" fresh "0 days" <<MD
| Session | Status |
|---|---|
| 1 | 📋 |
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_silent "$TMP/out.json" "an open but freshly-touched plan is not debt"
}

test_debt_reports_stale_open_plan() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" abandoned "30 days" <<MD
| Session | Brief | Status | Prompt |
|---|---|---|---|
| 1 | groundwork — the part that shipped | ✅ | — |
| 2 | host-daemon — LaunchAgent and installer | 📋 | [→ prompt](sessions/s2.md) |
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_signal "$TMP/out.json" "SessionStart" "stale open plan"
  assert_contains "$TMP/out.json" "plans/abandoned" "names the plan"
  assert_match "$TMP/out.json" '30 days' "names the age in days"
  assert_contains "$TMP/out.json" "1 open row" "counts the open rows"
  assert_contains "$TMP/out.json" "host-daemon" "quotes the first open row's brief"
  assert_contains "$TMP/out.json" "close" "proposes closing out"
  assert_contains "$TMP/out.json" "Do not edit any STATUS.md autonomously" "propose, never act"
}

# The single highest-value regression : every STATUS.md carries a legend line
# naming 🚧 and 📋, so a naive grep flags plans that are entirely finished.
test_debt_ignores_legend_line() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" done-with-legend "90 days" <<MD
| Session | Status |
|---|---|
| 1 | ✅ |
| 2 | ❌ |

## Legend

$_LEGEND
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_silent "$TMP/out.json" "the legend line is not an open row"
}

test_debt_french_legend() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" francais "90 days" <<MD
| Étape | Statut |
|---|---|
| tout | ✅ |

✅ fait · 📋 à faire · ⚠️ bloqué / partiel · ❌ annulé
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_silent "$TMP/out.json" "a French legend line is not an open row"
}

test_debt_trailing_text_and_bold() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" mixed "30 days" <<MD
| Étape | Statut |
|---|---|
| shipped | ✅ voir [design/FINDINGS.md](design/FINDINGS.md) |
| commits | ✅ 13 en session 2 (\`41952f8\` → \`8f74dcc\`) |
| pending work | **📋** |
| blocked work | ⚠️ waiting on the host |
MD
  _run_debt "$TMP/out.json" "$TMP"
  _assert_signal "$TMP/out.json" "SessionStart" "mixed cells"
  assert_contains "$TMP/out.json" "2 open rows" \
    "trailing text on ✅ stays closed ; bold 📋 and ⚠️ count as open"
}

test_debt_brief_column_varies() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" two-col "30 days" <<MD
| Étape | Statut |
|---|---|
| deux colonnes seulement | 📋 |
MD
  _mk_plan "$TMP" five-col "40 days" <<MD
| Session | Brief | Model | Status | Prompt |
|---|---|---|---|---|
| 1 | cinq colonnes avec un modele | B (opus-5) | 📋 | [→ prompt](s.md) |
MD
  _run_debt "$TMP/out.json" "$TMP"
  assert_contains "$TMP/out.json" "deux colonnes seulement" "brief found in a 2-column table"
  assert_contains "$TMP/out.json" "cinq colonnes avec un modele" "brief found in a 5-column table"
  # Stalest first.
  assert_match "$TMP/out.json" 'plans/five-col.*plans/two-col' "stalest plan is listed first"
}

# Staleness is the newest *.md in the plan dir, not STATUS.md alone : working
# a plan and only updating LOG.md must not make it look abandoned.
test_debt_uses_newest_md_in_dir() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_plan "$TMP" worked-yesterday "30 days" <<MD
| Session | Status |
|---|---|
| 1 | 📋 |
MD
  echo "# Log" > "$TMP/worked-yesterday/LOG.md"
  touch -d "1 day ago" "$TMP/worked-yesterday/LOG.md"
  _run_debt "$TMP/out.json" "$TMP"
  _assert_silent "$TMP/out.json" "a recent LOG.md keeps the plan out of debt"
}

test_debt_tolerates_junk() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  touch "$TMP/.DS_Store" "$TMP/loose-note.md"
  mkdir -p "$TMP/empty-dir" "$TMP/no-status/sessions"
  ln -s "$TMP/does-not-exist" "$TMP/broken-link"
  _mk_plan "$TMP" real "30 days" <<MD
| Session | Status |
|---|---|
| 1 | 📋 |
MD
  _run_debt "$TMP/out.json" "$TMP"
  assert_eq "0" "$?" "junk entries do not crash the hook"
  _assert_signal "$TMP/out.json" "SessionStart" "junk entries"
  assert_contains "$TMP/out.json" "plans/real" "reports the one real plan"
  assert_not_contains "$TMP/out.json" "loose-note" "ignores loose .md files"
  assert_not_contains "$TMP/out.json" "no-status" "ignores dirs without STATUS.md"
}

# --- session-gap -----------------------------------------------------------

test_gap_no_stdin() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  node "$GAP" < /dev/null > "$TMP/out.json" 2>/dev/null
  assert_eq "0" "$?" "no stdin exits 0"
  _assert_silent "$TMP/out.json" "no stdin is silent"
}

test_gap_missing_transcript() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _run_gap "$TMP/out.json" "$TMP/nope.jsonl"
  assert_eq "0" "$?" "missing transcript exits 0"
  _assert_silent "$TMP/out.json" "missing transcript is silent"
}

test_gap_fresh_session() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_transcript "$TMP/t.jsonl" 0 < <(_burst)
  _run_gap "$TMP/out.json" "$TMP/t.jsonl"
  _assert_silent "$TMP/out.json" "a session with only the current burst is silent"
}

test_gap_below_threshold() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_transcript "$TMP/t.jsonl" 0 < <(_iso_ago '10 minutes'; _burst)
  _run_gap "$TMP/out.json" "$TMP/t.jsonl"
  _assert_silent "$TMP/out.json" "a 10-minute pause does not fire"
}

test_gap_above_threshold() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_transcript "$TMP/t.jsonl" 0 < <(_iso_ago '9 hours'; _iso_ago '4 hours'; _burst)
  _run_gap "$TMP/out.json" "$TMP/t.jsonl"
  _assert_signal "$TMP/out.json" "UserPromptSubmit" "4h gap"
  assert_match "$TMP/out.json" '4h' "names the gap duration"
  assert_contains "$TMP/out.json" "Do not end or clear the session yourself" "propose, never act"
}

# The burst must be excluded from the reference point, not from `now` : the
# incoming prompt is already in the transcript when this hook runs.
test_gap_burst_does_not_mask_the_gap() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_transcript "$TMP/t.jsonl" 0 < <(_iso_ago '3 hours'; _burst)
  _run_gap "$TMP/out.json" "$TMP/t.jsonl"
  _assert_signal "$TMP/out.json" "UserPromptSubmit" "burst excluded"
  assert_match "$TMP/out.json" '3h' "measures back to the pre-burst event"
}

test_gap_out_of_order_and_malformed() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  # Transcript lines are NOT ordered by timestamp in practice.
  _mk_transcript "$TMP/t.jsonl" 0 < <(_iso_ago '1 second'; _iso_ago '4 hours'; _iso_ago '1 second'; _iso_ago '9 hours'; _iso_ago '1 second')
  echo 'not json at all' >> "$TMP/t.jsonl"
  printf '{"type":"user","timestamp":"2026-' >> "$TMP/t.jsonl"
  _run_gap "$TMP/out.json" "$TMP/t.jsonl"
  _assert_signal "$TMP/out.json" "UserPromptSubmit" "unordered + malformed"
  assert_match "$TMP/out.json" '4h' "still measures the right gap"
}

test_gap_min_size_gate() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  _mk_transcript "$TMP/small.jsonl" 0 < <(_iso_ago '4 hours'; _burst)
  _run_gap "$TMP/out.json" "$TMP/small.jsonl" 1 250
  _assert_silent "$TMP/out.json" "a tiny transcript has no context worth abandoning"

  _mk_transcript "$TMP/big.jsonl" 300 < <(_iso_ago '4 hours'; _burst)
  _run_gap "$TMP/out2.json" "$TMP/big.jsonl" 1 250
  _assert_signal "$TMP/out2.json" "UserPromptSubmit" "past the size gate"
}

# --- model-availability ----------------------------------------------------

# The bug this hook exists to fix : a project .env can export a stale
# CLAUDE_CODE_VERSION, but the running binary never lies about its own build.
test_avail_stale_env_loses_to_binary() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "2.1.280 (Claude Code)"
SH
  chmod +x "$TMP/bin/claude"
  env -u CLAUDE_CODE_EXECPATH PATH="$TMP/bin:$PATH" CLAUDE_CODE_VERSION=2.1.258 \
    node "$AVAIL" > "$TMP/out.json" 2>/dev/null
  assert_contains "$TMP/out.json" "Claude Code 2.1.280" \
    "the binary's own version wins over a stale CLAUDE_CODE_VERSION"
}

test_avail_execpath_wins_without_binary() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  mkdir -p "$TMP/empty-bin"
  env PATH="$TMP/empty-bin" \
    CLAUDE_CODE_EXECPATH="/x/anthropic.claude-code-2.1.272-linux-arm64/resources/native-binary/claude" \
    CLAUDE_CODE_VERSION=2.1.258 \
    "$NODE_BIN" "$AVAIL" > "$TMP/out.json" 2>/dev/null
  assert_contains "$TMP/out.json" "Claude Code 2.1.272" \
    "CLAUDE_CODE_EXECPATH wins when there is no claude binary to shell out to"
}

test_avail_nothing_readable_is_silent() {
  local TMP; TMP=$(mktemp -d); trap "rm -rf '$TMP'" RETURN
  mkdir -p "$TMP/empty-bin"
  env -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_VERSION PATH="$TMP/empty-bin" \
    "$NODE_BIN" "$AVAIL" > "$TMP/out.json" 2>/dev/null
  assert_eq "0" "$?" "nothing readable still exits 0"
  _assert_silent "$TMP/out.json" "nothing readable emits no context line"
}

run_tests
exit $?
