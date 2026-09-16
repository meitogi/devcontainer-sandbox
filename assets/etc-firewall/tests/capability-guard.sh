#!/usr/bin/env bash
# capability-guard.sh — when the container has no CAP_NET_ADMIN, does
# init-firewall.sh say so, and does it say so BEFORE touching netfilter?
#
# Without the guard the boot dies at the iptables reset on "Permission denied
# (you must be root)" — while running as root under sudo. The refusal has to
# name the capability, and it has to come out before that misdirection.
#
# The fixture is the point : root in a container with Docker's DEFAULT
# capability set, which holds NET_RAW but NOT NET_ADMIN. That is literally what
# someone gets when they forget cap_add, so the suite needs root and needs the
# capability to be absent — hence a bare `docker run`, no --cap-add, and the
# two entry guards below refusing the wrong context either way.
#
# It is the mode asymmetry that makes the second half worth asserting :
# FIREWALL_MODE=off boots green and silent with no capability at all, on
# purpose — "off" means no filtering, and that is what you get. Only strict and
# basic refuse. This suite freezes both halves of that.
#
# Usage :
#   docker run --rm -u 0 <image> bash /etc/devcontainer-firewall/tests/capability-guard.sh

set -uo pipefail

INIT="${FW_INIT:-/usr/local/bin/init-firewall.sh}"
FW="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "⚠️  running as $(id -un) — this suite needs root, because the claim under"
  echo "   test is that root is NOT what is missing. Re-run with -u 0."
  exit 2
fi

CAPEFF=$(grep -E '^CapEff:' /proc/self/status 2>/dev/null | awk '{print $2}')
if [ -z "$CAPEFF" ]; then
  echo "⚠️  could not read CapEff from /proc/self/status — no fixture to test."
  exit 2
fi
if (( (16#${CAPEFF: -8} & (1 << 12)) != 0 )); then
  echo "⚠️  this container HOLDS CAP_NET_ADMIN (CapEff=$CAPEFF) — there is nothing"
  echo "   to refuse. Run it on a bare container, without --cap-add."
  exit 2
fi

echo "init     : $INIT"
echo "config   : $FW"
echo "CapEff   : $CAPEFF — no CAP_NET_ADMIN, the fixture"

# The lock is a directory in /tmp and the script removes it on exit; clear any
# leftover so a run is never mistaken for a concurrent one.
rm -rf /tmp/init-firewall.lock

echo
echo "== G1 — strict boot with no capability =="
echo strict > "$FW/default-mode"
out=$("$INIT" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "G1 · exits 3" || ko "G1 · exits 3 — got $rc"
grep -q '🔐 Resetting' <<<"$out" \
  && ko "G1 · refuses before touching netfilter — it reached the reset" \
  || ok "G1 · refuses before touching netfilter"
# iptables' own signature, not the words "you must be root" : the refusal
# quotes those on purpose, so grepping for them matches the fix instead of the
# defect. Measured 2026-09-16, this is the line the boot used to die on.
grep -q 'Could not fetch rule set generation id' <<<"$out" \
  && ko "G1 · no opaque iptables diagnostic — iptables still spoke" \
  || ok "G1 · no opaque iptables diagnostic"
grep -qi 'being root is not the problem' <<<"$out" \
  && ok "G1 · says root is not the problem" || ko "G1 · says root is not the problem"
grep -q 'CAP_NET_ADMIN' <<<"$out" \
  && ok "G1 · names the missing capability" || ko "G1 · names the missing capability"
grep -q 'devcontainer.json' <<<"$out" \
  && ok "G1 · says devcontainer.json cannot grant it" || ko "G1 · says devcontainer.json cannot grant it"
grep -q 'cap_add' <<<"$out" \
  && ok "G1 · hands over the compose block" || ko "G1 · hands over the compose block"
grep -q 'README' <<<"$out" \
  && ok "G1 · points at the README section" || ko "G1 · points at the README section"

echo
echo "== G2 — FIREWALL_MODE=off is left alone =="
rm -rf /tmp/init-firewall.lock
echo off > "$FW/default-mode"
out=$("$INIT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "G2 · exits 0" || ko "G2 · exits 0 — got $rc"
grep -q 'cap_add' <<<"$out" \
  && ko "G2 · the guard stays silent — it refused an off boot" \
  || ok "G2 · the guard stays silent"
grep -q 'Firewall disabled' <<<"$out" \
  && ok "G2 · reports the firewall disabled" || ko "G2 · reports the firewall disabled"

echo
echo "== G3 — an unprivileged caller is not told they are root =="
# A non-root process reads CapEff=0 even in a container that HOLDS both
# capabilities, so a guard that fired on uid alone would answer "you are
# already root" to someone who is not — the exact misdirection it exists to
# remove. Here the uid IS the problem, and iptables' message is the true one.
rm -rf /tmp/init-firewall.lock
echo strict > "$FW/default-mode"
out=$(su node -s /bin/bash -c "$INIT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "G3 · still fails (exit $rc)" || ko "G3 · still fails — it succeeded as node"
grep -q 'Being root is NOT the problem' <<<"$out" \
  && ko "G3 · does not claim the caller is root" \
  || ok "G3 · does not claim the caller is root"
rm -rf /tmp/init-firewall.lock

echo
echo "=========================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
