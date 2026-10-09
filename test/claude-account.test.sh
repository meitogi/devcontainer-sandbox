#!/usr/bin/env bash
# Tests for bin/claude-account and the three places that reuse its resolver
# (bin/sync-creds, post-start.d/60-claude-json-sync.sh — shell-init only
# prints). Standalone — no root, no network, no Docker.
# Usage: bash test/claude-account.test.sh
#
# Everything runs against a fake HOME in a tmp dir (LOCAL_DIR / SHARED_DIR):
# the real /home/node/.claude-creds volume is shared by every container of
# the user and is never read or written here. Payloads are asserted exactly
# (accessToken, email, userID) — a file that exists with the wrong account's
# token in it is the defect this command can cause.
#
# 1.9.x compatibility is proved with the real v1.9.4 sync-creds (git show),
# run with `sh` as the Stop hooks do, against the multi-account layout.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
BIN="$REPO/bin"
CA="$BIN/claude-account"
HOOK60="$REPO/assets/opt/hooks/post-start.d/60-claude-json-sync.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }

TMP=$(mktemp -d)
FAKE_PIDS=""
trap 'for p in $FAKE_PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT

L="$TMP/local"     # stands for /home/node/.claude        (per-project volume)
S="$TMP/shared"    # stands for /home/node/.claude-creds  (shared volume)
mkdir -p "$L" "$S"
export LOCAL_DIR="$L" SHARED_DIR="$S" TZ=UTC PATH="$BIN:$PATH"
unset LOCAL_CRED SHARED_CRED VERBOSE DEBUG

# jget <file> <dotted.path> — the value, <absent> or <unreadable>
jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    print('<unreadable>'); sys.exit()
for k in sys.argv[2].split('.'):
    if not isinstance(v, dict) or k not in v:
        print('<absent>'); sys.exit()
    v = v[k]
print(v)
PY
}
# jset <file> <key> <json-value> — top-level key, file created if missing
jset() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
d[sys.argv[2]] = json.loads(sys.argv[3])
json.dump(d, open(p, 'w'), indent=2)
PY
}
creds() {  # creds <file> <token> <expiresAt-ms>
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"ref-%s","expiresAt":%s}}\n' "$2" "$2" "$3" > "$1"
}
root_hash()     { cat "$S/.credentials.json" "$S/.claude.json" | sha256sum | cut -d' ' -f1; }
accounts_hash() { (cd "$S" && find accounts -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1; }

FUT=4070952000000            # 2099-01-01 12:00 UTC
PAST=1577836800000           # 2020-01-01 00:00 UTC

# A container on account default after its boot: root and local agree.
creds "$S/.credentials.json" tok-default-1 "$FUT"
cat > "$S/.claude.json" <<'EOF'
{"oauthAccount": {"emailAddress": "default@ex", "accountUuid": "u-default"}, "userID": "uid-default", "numStartups": 1}
EOF
cp "$S/.credentials.json" "$L/.credentials.json"; chmod 600 "$L/.credentials.json"
cp "$S/.claude.json" "$L/.claude.json"

echo "== the fake HOME is the only target =="
eq "path resolves inside the tmp HOME (never the real volume)" "$("$CA" path)" "$S/.credentials.json"
eq "no .active-account = default" "$("$CA" status --short)" \
   "Claude account : default (default@ex) · token valid until 2099-01-01 12:00"
ROOT0=$(root_hash)

echo "== use to an empty slot =="
OUT=$("$CA" use perso --yes 2>/dev/null); RC=$?
eq "use perso exits 0" "$RC" "0"
eq ".active-account = perso" "$(cat "$L/.active-account")" "perso"
eq "path follows the active account" "$("$CA" path)" "$S/accounts/perso/.credentials.json"
eq "local creds removed (empty slot)" "$([ -e "$L/.credentials.json" ] && echo present || echo absent)" "absent"
eq "local oauthAccount removed" "$(jget "$L/.claude.json" oauthAccount)" "<absent>"
eq "local userID removed" "$(jget "$L/.claude.json" userID)" "<absent>"
eq "the rest of local .claude.json kept" "$(jget "$L/.claude.json" numStartups)" "1"
case "$OUT" in *"run \`claude\`, then /login"*) ok "empty slot prints the /login hint" ;; *) ko "empty slot prints the /login hint" "$OUT" "…run \`claude\`, then /login…" ;; esac
case "$OUT" in *"Reload Window"*) ok "always ends with restart / Reload Window" ;; *) ko "always ends with restart / Reload Window" "$OUT" "…Reload Window…" ;; esac
eq "root byte-identical after the switch" "$(root_hash)" "$ROOT0"
eq "status --short, not signed in" "$("$CA" status --short)" \
   "Claude account : perso · not signed in, run claude then /login"

echo "== /login on the new account is filed into its slot =="
creds "$L/.credentials.json" tok-perso-1 "$FUT"
jset "$L/.claude.json" oauthAccount '{"emailAddress": "perso@ex", "accountUuid": "u-perso"}'
jset "$L/.claude.json" userID '"uid-perso"'
sync-creds
eq "slot holds the exact new token" "$(jget "$S/accounts/perso/.credentials.json" claudeAiOauth.accessToken)" "tok-perso-1"
eq "root byte-identical after filing" "$(root_hash)" "$ROOT0"
eq "status --short, signed in" "$("$CA" status --short)" \
   "Claude account : perso (perso@ex) · token valid until 2099-01-01 12:00"

echo "== a refreshed token goes to the slot, never the root =="
creds "$L/.credentials.json" tok-perso-2 "$((FUT + 3600000))"
sh "$BIN/sync-creds"    # the Stop hook runs it with sh
eq "slot holds the refreshed token" "$(jget "$S/accounts/perso/.credentials.json" claudeAiOauth.accessToken)" "tok-perso-2"
eq "root byte-identical after the refresh" "$(root_hash)" "$ROOT0"
eq "root token still default's" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-default-1"

echo "== switch back to default =="
"$CA" use default --yes >/dev/null 2>&1; RC=$?
eq "use default exits 0" "$RC" "0"
eq ".active-account removed (absent = default)" "$([ -e "$L/.active-account" ] && echo present || echo absent)" "absent"
eq "local accessToken = default's" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-default-1"
eq "local creds are 600" "$(stat -c %a "$L/.credentials.json")" "600"
eq "local email = default's" "$(jget "$L/.claude.json" oauthAccount.emailAddress)" "default@ex"
eq "local userID = default's" "$(jget "$L/.claude.json" userID)" "uid-default"
eq "outgoing identity saved: email" "$(jget "$S/accounts/perso/account.json" oauthAccount.emailAddress)" "perso@ex"
eq "outgoing identity saved: userID" "$(jget "$S/accounts/perso/account.json" userID)" "uid-perso"
eq "root byte-identical after switching back" "$(root_hash)" "$ROOT0"
eq "list marks default, shows both emails" "$("$CA" list)" \
"* default      default@ex
  perso        perso@ex"

echo "== switch to perso again, no new login =="
"$CA" use perso --yes >/dev/null 2>&1
eq "local accessToken = perso's refreshed one" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-perso-2"
eq "local email = perso's" "$(jget "$L/.claude.json" oauthAccount.emailAddress)" "perso@ex"
eq "local userID = perso's" "$(jget "$L/.claude.json" userID)" "uid-perso"
eq "root byte-identical" "$(root_hash)" "$ROOT0"
mkdir -p "$S/accounts/work"
eq "list marks perso, an empty slot is not signed in" "$("$CA" list)" \
"  default      default@ex
* perso        perso@ex
  work         (not signed in)"

echo "== post-start.d/60 on a non-default account keeps identities apart =="
jset "$L/.claude.json" numStartups 7
touch -d '2020-01-01' "$S/.claude.json"
bash "$HOOK60" >/dev/null
eq "local→root: the non-identity key syncs" "$(jget "$S/.claude.json" numStartups)" "7"
eq "local→root: root email stays default's" "$(jget "$S/.claude.json" oauthAccount.emailAddress)" "default@ex"
eq "local→root: root userID stays default's" "$(jget "$S/.claude.json" userID)" "uid-default"
jset "$S/.claude.json" numStartups 9
touch -d '2020-01-01' "$L/.claude.json"
bash "$HOOK60" >/dev/null
eq "root→local: the non-identity key syncs" "$(jget "$L/.claude.json" numStartups)" "9"
eq "root→local: local email stays perso's" "$(jget "$L/.claude.json" oauthAccount.emailAddress)" "perso@ex"
eq "root→local: local userID stays perso's" "$(jget "$L/.claude.json" userID)" "uid-perso"
rm "$L/.claude.json"
bash "$HOOK60" >/dev/null
eq "restore: local gets the settings" "$(jget "$L/.claude.json" numStartups)" "9"
eq "restore: but never default's identity" "$(jget "$L/.claude.json" oauthAccount)" "<absent>"
eq "restore: local .claude.json is 600" "$(stat -c %a "$L/.claude.json")" "600"
ROOT0=$(root_hash)   # the root .claude.json legitimately took numStartups

echo "== leaving an account with no identity keeps its account.json =="
"$CA" use default --yes >/dev/null 2>&1
eq "account.json still perso's" "$(jget "$S/accounts/perso/account.json" oauthAccount.emailAddress)" "perso@ex"
eq "local email = default's" "$(jget "$L/.claude.json" oauthAccount.emailAddress)" "default@ex"

echo "== post-start.d/60 on default is today's whole-file copy =="
jset "$L/.claude.json" numStartups 11
touch -d '2020-01-01' "$S/.claude.json"
bash "$HOOK60" >/dev/null
eq "root is byte-identical to local" "$(cmp -s "$L/.claude.json" "$S/.claude.json" && echo same || echo differ)" "same"

echo "== 1.9.x compatibility: v1.9.4 sync-creds on this layout =="
if git -C "$REPO" show v1.9.4:bin/sync-creds > "$TMP/sync-creds-194" 2>/dev/null; then
  ACC0=$(accounts_hash)
  C194="$TMP/c194"; mkdir -p "$C194"
  LOCAL_CRED="$C194/.credentials.json" SHARED_CRED="$S/.credentials.json" sh "$TMP/sync-creds-194"
  eq "1.9.4 container restores default's exact token" "$(jget "$C194/.credentials.json" claudeAiOauth.accessToken)" "tok-default-1"
  creds "$C194/.credentials.json" tok-default-2 "$((FUT + 7200000))"
  LOCAL_CRED="$C194/.credentials.json" SHARED_CRED="$S/.credentials.json" sh "$TMP/sync-creds-194"
  eq "1.9.4 refresh lands at the root" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-default-2"
  eq "accounts/ untouched by the 1.9.4 container" "$(accounts_hash)" "$ACC0"
  sync-creds
  eq "a default container here picks that refresh up" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-default-2"
  eq "the perso slot never saw it" "$(jget "$S/accounts/perso/.credentials.json" claudeAiOauth.accessToken)" "tok-perso-2"
else
  ko "git show v1.9.4:bin/sync-creds" "tag missing" "the v1.9.4 tag (git fetch --tags)"
fi

echo "== status --short wording =="
X="$TMP/st"; mkdir -p "$X/l" "$X/s"
st() { LOCAL_DIR="$X/l" SHARED_DIR="$X/s" "$CA" status --short; }
creds "$X/l/.credentials.json" tok-x "$PAST"
eq "expired token" "$(st)" "Claude account : default · token expired at 2020-01-01 00:00"
NOW_S=$(date +%s); EXP_S=$((NOW_S + 120))
creds "$X/l/.credentials.json" tok-x "${EXP_S}000"
if [ "$(date -u -d "@$EXP_S" +%F)" = "$(date -u +%F)" ]; then W=$(date -u -d "@$EXP_S" +%H:%M); else W=$(date -u -d "@$EXP_S" '+%F %H:%M'); fi
eq "today's expiry shows the time only" "$(st)" "Claude account : default · token valid until $W"
printf '../../etc\n' > "$X/l/.active-account"
eq "a tampered .active-account resolves to default" "$(LOCAL_DIR="$X/l" SHARED_DIR="$X/s" "$CA" path)" "$X/s/.credentials.json"
case "$(LOCAL_DIR="$X/l" SHARED_DIR="$X/s" "$CA" status)" in
  *"Slot    : $X/s/.credentials.json"*) ok "status (long) names the slot" ;;
  *) ko "status (long) names the slot" "$(LOCAL_DIR="$X/l" SHARED_DIR="$X/s" "$CA" status)" "…Slot    : $X/s/.credentials.json" ;;
esac

echo "== refusals =="
rc() { "$@" >/dev/null 2>&1 </dev/null; echo $?; }
eq "use ../x refused" "$(rc "$CA" use ../x --yes)" "1"
eq "use Bad refused" "$(rc "$CA" use Bad --yes)" "1"
# .sync-creds.lock is sync-creds' own lock (creds-watch rollout), not an account.
eq "nothing created outside accounts/" "$(ls -A "$S" | tr '\n' ' ')" ".claude.json .credentials.json .sync-creds.lock accounts "
eq "remove default refused" "$(rc "$CA" remove default --yes)" "1"
"$CA" use perso --yes >/dev/null 2>&1
eq "remove the active account refused" "$(rc "$CA" remove perso --yes)" "1"
eq "  …and its slot is still there" "$(jget "$S/accounts/perso/.credentials.json" claudeAiOauth.accessToken)" "tok-perso-2"
eq "remove a missing account refused" "$(rc "$CA" remove ghost --yes)" "1"
eq "remove without --yes and no tty refused" "$(rc "$CA" remove work)" "1"
eq "remove work --yes" "$(rc "$CA" remove work --yes)" "0"
eq "  …work is gone" "$([ -e "$S/accounts/work" ] && echo present || echo absent)" "absent"
eq "use the active account is a no-op" "$(rc "$CA" use perso --yes)" "0"
eq "no subcommand is a usage error" "$(rc "$CA")" "2"

echo "== a corrupt .claude.json stops the switch, and the hook =="
cp "$L/.claude.json" "$TMP/good.json"
echo '{not json' > "$L/.claude.json"
L0=$(sha256sum "$L/.credentials.json" | cut -d' ' -f1)
eq "use refused on a corrupt local .claude.json" "$(rc "$CA" use default --yes)" "1"
eq "  ….active-account unchanged" "$(cat "$L/.active-account")" "perso"
eq "  …local creds unchanged" "$(sha256sum "$L/.credentials.json" | cut -d' ' -f1)" "$L0"
R0=$(sha256sum "$S/.claude.json" | cut -d' ' -f1)
touch -d '2020-01-01' "$S/.claude.json"
HOUT=$(bash "$HOOK60" 2>&1); RC=$?
eq "the 60 hook exits 0 on it" "$RC" "0"
case "$HOUT" in *"sync skipped"*✓*|*✓*"sync skipped"*|*"✓"*) ko "  …and says it skipped, with no ✓" "$HOUT" "⚠ … sync skipped (no ✓ line)" ;; *"sync skipped"*) ok "  …and says it skipped, with no ✓" ;; *) ko "  …and says it skipped, with no ✓" "$HOUT" "⚠ … sync skipped" ;; esac
eq "  …and copies nothing to the root" "$(sha256sum "$S/.claude.json" | cut -d' ' -f1)" "$R0"
cp "$TMP/good.json" "$L/.claude.json"

echo "== guard: a running claude process =="
cp /bin/sleep "$TMP/claude"; "$TMP/claude" 30 & FAKE_PIDS="$FAKE_PIDS $!"
L0=$(sha256sum "$L/.credentials.json" | cut -d' ' -f1)
eq "use without --yes and no tty refused" "$(rc "$CA" use default)" "1"
eq "  ….active-account unchanged" "$(cat "$L/.active-account")" "perso"
eq "  …local creds unchanged" "$(sha256sum "$L/.credentials.json" | cut -d' ' -f1)" "$L0"
eq "use --yes goes through" "$(rc "$CA" use default --yes)" "0"
eq "  …and switched" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-default-2"

echo
echo "claude-account: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
