#!/usr/bin/env bash
# privilege.sh — control-plane pentest: can the container user change the
# firewall itself?
#
# bypass.sh attacks the network path (DNS, L4, SNI, proxies). This suite
# attacks the machinery: sudo grants, file ownership, the reload command,
# the frozen bake. Every check asserts that an UNPRIVILEGED process cannot
# widen the allowlist, and that the two supported paths still work
# (whitelisted self-heal, unprivileged --dry-run).
#
# Run as the container user (node), NOT as root :
#   bash /etc/devcontainer-firewall/tests/privilege.sh
#   docker run --rm <image> bash /etc/devcontainer-firewall/tests/privilege.sh
#
# Checks that need a running firewall self-skip on a bare `docker run`.

set -u

FW="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"
RUNDIR=/var/run/devcontainer-firewall
RELOAD="${FW_RELOAD:-/usr/local/bin/reload-firewall}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  – $1 (skipped: $2)"; }

# assert_denied "label" cmd...  — the command MUST fail.
assert_denied() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ko "$label — SUCCEEDED, that is a privilege hole"
  else
    ok "$label — denied"
  fi
}

# assert_works "label" cmd...  — the command MUST succeed.
assert_works() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    ko "$label — failed, the supported path is broken"
  fi
}

if [ "$(id -u)" -eq 0 ]; then
  echo "⚠️  running as root — this suite only means something as the container user."
  echo "   Re-run without -u 0."
  exit 2
fi

echo "═══ privilege.sh — running as $(id -un) (uid $(id -u)) ═══"
echo

echo "== 1. sudo grants =="
# The whole boundary: reload-firewall must NEVER be passwordless, and the
# node user has no password, so it must be unreachable altogether.
assert_denied "sudo -n reload-firewall"          sudo -n "$RELOAD" --dry-run
assert_denied "sudo -n arbitrary command (sh)"   sudo -n /bin/sh -c true
assert_denied "sudo -n compile-policy.py"        sudo -n /usr/local/bin/compile-policy.py --help
if sudo -n -l >/dev/null 2>&1; then
  GRANTS=$(sudo -n -l 2>/dev/null | grep -c 'NOPASSWD' || true)
  ALLOWED=$(sudo -n -l 2>/dev/null | grep -oE '/usr/local/bin/[a-z-]+\.sh' | sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$ALLOWED" = "/usr/local/bin/init-firewall.sh /usr/local/bin/test-firewall.sh" ] \
    && ok "NOPASSWD limited to init-firewall.sh + test-firewall.sh" \
    || ko "unexpected NOPASSWD grants: ${ALLOWED:-none} (${GRANTS} lines)"
else
  skip "sudo -l inventory" "sudo -n -l not permitted"
fi
assert_denied "read /etc/sudoers.d (0440 root)"  cat /etc/sudoers.d/node-firewall

echo
echo "== 2. firewall sources are image content, not workspace content =="
for f in "$FW/domains.d/00-base.txt" "$FW/dnsmasq.conf"; do
  [ -e "$f" ] || { skip "write $f" "absent"; continue; }
  assert_denied "write $(basename "$f")" bash -c ": >> '$f'"
done
assert_denied "create a file in $FW"         bash -c "touch '$FW/pwned.txt'"
assert_denied "create a file in $FW/policy.d" bash -c "touch '$FW/policy.d/pwned.yaml'"
assert_denied "create a file in $FW/domains.d" bash -c "touch '$FW/domains.d/99-pwned.txt'"

echo
echo "== 3. the machinery itself is not rewritable =="
for b in init-firewall.sh compile-policy.py firewall-digest.sh reload-firewall firewall-docker-setup.sh; do
  [ -e "/usr/local/bin/$b" ] || { skip "write $b" "absent"; continue; }
  assert_denied "write /usr/local/bin/$b" bash -c ": >> '/usr/local/bin/$b'"
done

echo
echo "== 4. the frozen bake cannot be forged =="
if [ -d "$FW/effective" ]; then
  assert_denied "write effective/sources.sha256" bash -c ": >> '$FW/effective/sources.sha256'"
  assert_denied "add to effective/"              bash -c "touch '$FW/effective/pwned'"
else
  skip "effective/ tamper checks" "image not baked (supported: base-only boot)"
fi

echo
echo "== 5. the live ruleset is root-owned =="
if [ -d "$RUNDIR" ]; then
  assert_denied "write the compiled policy" bash -c ": >> '$RUNDIR/policy.compiled.yaml'"
  assert_denied "write the dnsmasq conf"    bash -c ": >> '$RUNDIR/dnsmasq-domains-base.conf'"
  assert_denied "add to $RUNDIR"            bash -c "touch '$RUNDIR/pwned'"
else
  skip "runtime ruleset checks" "firewall not started (bare docker run)"
fi

echo
echo "== 6. netfilter state is unreachable without CAP_NET_ADMIN =="
assert_denied "ipset add to the base set"  ipset add allowed-domains-base 1.2.3.4
assert_denied "ipset flush"                ipset flush allowed-domains-base
assert_denied "iptables -F"                iptables -F
assert_denied "kill dnsmasq"               pkill -x dnsmasq
assert_denied "kill mitmdump"              pkill -x mitmdump

echo
echo "== 7. supported paths still work =="
# --dry-run is deliberately unprivileged: previewing the diff is safe, and
# an agent that wants a wider firewall must show a human what it is asking for.
if [ -x "$RELOAD" ]; then
  # --dry-run diffs the candidate against the LIVE ruleset, so it needs a
  # started firewall — on a bare `docker run` there is nothing to diff.
  if [ -d "$RUNDIR" ]; then
    assert_works "reload-firewall --dry-run (unprivileged preview)" "$RELOAD" --dry-run
  else
    skip "reload-firewall --dry-run" "firewall not started (nothing to diff against)"
  fi
  assert_denied "reload-firewall apply as $(id -un)"               "$RELOAD"
else
  skip "reload-firewall checks" "binary absent"
fi
# init-firewall.sh IS whitelisted — the self-heal path after a restart. It
# must stay reachable, or a restarted container boots with no firewall.
if sudo -n -l /usr/local/bin/init-firewall.sh >/dev/null 2>&1; then
  ok "init-firewall.sh reachable via NOPASSWD (self-heal path intact)"
else
  ko "init-firewall.sh NOT reachable — a restarted container cannot re-init"
fi

echo
echo "═══════════════════════════════════════════════════════"
echo "  privilege : $((PASS+FAIL)) run | ✔ $PASS | ❌ $FAIL | – $SKIP skipped"
echo "═══════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
