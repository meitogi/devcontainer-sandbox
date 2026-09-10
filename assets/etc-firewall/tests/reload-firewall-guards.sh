#!/usr/bin/env bash
# reload-firewall-guards.sh — what can be proven about reload-firewall from
# inside the container, as the unprivileged `node` user.
#
# Covers the --dry-run path end to end (it is designed to work with no
# privileges) and the unprivileged half of the guard cascade. The root+TTY half
# — confirmation prompt, abort on anything but `yes`, actual apply — needs
# `docker exec -it -u 0` from the host and lives in TEST-PLAN-2.md.
#
# Usage :  bash reload-firewall-guards.sh

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "${FW_RELOAD:-}" "$SELF_DIR/../../bin/reload-firewall" \
         /usr/local/bin/reload-firewall; do
  if [ -n "$c" ] && [ -f "$c" ]; then RELOAD="$c"; break; fi
done

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $*"; }
ko() { FAIL=$((FAIL+1)); echo "  ✘ $*"; }

SB="$(mktemp -d)"
echo "reload   : $RELOAD"
echo "sandbox  : $SB"
[ "$(id -u)" -eq 0 ] && { echo "run this as an unprivileged user"; exit 2; }

# --- prerequisites ---------------------------------------------------------
# This suite drives the real reload-firewall, which refuses to run without a
# firewall INSTALLED (default-mode, produced by the project's fw-bake stage)
# and STARTED (runtime confs). Both hold in a project container, neither does
# in a bare `docker run` of the base image - where the suite used to fail
# twelve assertions for a reason unrelated to what it tests, and pass two by
# accident (both sha256sum calls failed identically, so "live runtime confs
# untouched" was comparing two errors).
MODE_FILE=/etc/devcontainer-firewall/default-mode
RUNDIR=/var/run/devcontainer-firewall
if [ ! -s "$MODE_FILE" ] || ! ls "$RUNDIR"/dnsmasq-domains-*.conf >/dev/null 2>&1; then
  echo "  - whole suite skipped: needs a container where the firewall is"
  echo "    INSTALLED and STARTED. Here: $([ -s "$MODE_FILE" ] || echo 'no default-mode')" \
       "$(ls "$RUNDIR"/dnsmasq-domains-*.conf >/dev/null 2>&1 || echo '/ empty runtime')"
  echo "    (that is a bare \`docker run\` of the base image - run it on a"
  echo "     project container instead, cf. TEST-PLAN-4 'Frontiere', bucket C)"
  exit 0
fi

# A project layer with one extra host, so the dry run has something to show.
# Falls back to the installed config: a project may ship no layer 2 at all.
WS_FW=/workspace/.devcontainer/firewall
[ -d "$WS_FW" ] || WS_FW=/etc/devcontainer-firewall
cp -a "$WS_FW" "$SB/fw"
touch "$SB/fw/domains.local.txt"
printf '\n# added by reload-firewall-guards.sh\nreload-guard-probe.example\n' \
  >> "$SB/fw/domains.local.txt"

echo
echo "== T8 — --dry-run as an unprivileged user =="
out=$(WORKSPACE_FW_DIR="$SB/fw" "$RELOAD" --dry-run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || { ko "exit $rc"; echo "$out" | sed 's/^/      /'; }
grep -q 'local sources'      <<<"$out" && ok "prints the .local source hashes"  || ko "no source hashes"
grep -q 'host allowlist delta' <<<"$out" && ok "prints the host delta"          || ko "no host delta"
grep -q '+ reload-guard-probe.example' <<<"$out" && ok "the added host shows as +" \
  || { ko "added host not shown"; echo "$out" | sed 's/^/      /' | head -40; }
grep -q 'ruleset diff'       <<<"$out" && ok "prints the unified diff"          || ko "no unified diff"
grep -q 'was NOT modified'   <<<"$out" && ok "states nothing was applied"       || ko "no reassurance line"

# Nothing may be written outside the scratch dir.
live_before=$(sha256sum /var/run/devcontainer-firewall/dnsmasq-domains-*.conf | sha256sum)
WORKSPACE_FW_DIR="$SB/fw" "$RELOAD" --dry-run >/dev/null 2>&1
live_after=$(sha256sum /var/run/devcontainer-firewall/dnsmasq-domains-*.conf | sha256sum)
[ "$live_before" = "$live_after" ] && ok "live runtime confs untouched" || ko "LIVE CONFS MUTATED BY A DRY RUN"
[ -z "$(find /etc/devcontainer-firewall -newermt '-30 seconds' 2>/dev/null)" ] \
  && ok "/etc/devcontainer-firewall untouched" || ko "/etc was written during a dry run"

echo
echo "== T8b — dry run with no local overrides =="
cp -a "$WS_FW" "$SB/fw-empty"
: > "$SB/fw-empty/domains.local.txt"
rm -f "$SB/fw-empty/policy.local.d"/*.yaml 2>/dev/null
out=$(WORKSPACE_FW_DIR="$SB/fw-empty" "$RELOAD" --dry-run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || ko "exit $rc"
grep -q 'no domains.local.txt\|(no host change)\|- ' <<<"$out" \
  && ok "renders the empty-overlay case" || ko "unexpected output"

echo
echo "== T9 — guard cascade (unprivileged half) =="
out=$("$RELOAD" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "apply refused as non-root (exit $rc)" || ko "apply NOT refused as non-root"
grep -q 'must run as root'   <<<"$out" && ok "names the reason"                 || ko "no reason given"
grep -q 'wtf firewall reload' <<<"$out" && ok "names the host-side alternative"  || ko "no alternative named"
grep -q -- '--dry-run'       <<<"$out" && ok "names the unprivileged preview"    || ko "no preview named"
grep -qi 'passwordless sudo' <<<"$out" && ok "states why sudo is not granted"    || ko "sudo rationale missing"

# Guard ORDER : the EUID check must fire before the CLAUDECODE check, so an
# agent on a host terminal is told about root rather than about itself.
out=$(CLAUDECODE=1 "$RELOAD" 2>&1)
grep -q 'must run as root' <<<"$out" && ok "EUID guard precedes the CLAUDECODE guard" \
                                     || ko "guard order wrong"

# Piping into the apply path must not slip past anything.
out=$(printf 'yes\n' | "$RELOAD" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "piped 'yes' still refused (exit $rc)" || ko "piped 'yes' got through"

echo
echo "== T9c — mode wall-guard =="
# Gates both --dry-run and apply : there is nothing to reload when the firewall
# is off, and `okeish` is a removed alias someone may still have on disk.
mkdir -p "$SB/fw-off"
cp -a /etc/devcontainer-firewall/dnsmasq.conf "$SB/fw-off/" 2>/dev/null
for m in off okeish nonsense; do
  echo "$m" > "$SB/fw-off/default-mode"
  out=$(SYSTEM_FW_DIR="$SB/fw-off" "$RELOAD" --dry-run 2>&1); rc=$?
  [ $rc -ne 0 ] && ok "mode '$m' refused (exit $rc)" || ko "mode '$m' accepted"
done
echo off > "$SB/fw-off/default-mode"
out=$(SYSTEM_FW_DIR="$SB/fw-off" "$RELOAD" --dry-run 2>&1)
grep -q 'nothing to do' <<<"$out" && ok "'off' explains there is nothing to reload" \
                                  || ko "'off' gives no explanation"
echo okeish > "$SB/fw-off/default-mode"
out=$(SYSTEM_FW_DIR="$SB/fw-off" "$RELOAD" --dry-run 2>&1)
grep -q 'legacy alias' <<<"$out" && ok "'okeish' names the replacement" || ko "'okeish' unexplained"

echo
echo "== T9b — unknown flags and help =="
"$RELOAD" --frobnicate >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown flag exits 2" || ko "unknown flag not rejected"
"$RELOAD" --help 2>&1 | grep -q 'EPHEMERAL BY DESIGN' && ok "--help prints the header" || ko "--help broken"

rm -rf "$SB"
echo
echo "=========================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
