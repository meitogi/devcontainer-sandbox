#!/usr/bin/env bash
# bake-idempotency.sh — sandbox tests for firewall-docker-setup.sh.
#
# Runs unprivileged, writes only under a temp dir, touches neither the live
# firewall nor /etc. Builds its fixture from the running container's
# /etc/devcontainer-firewall/ (world-readable), split back into a base part
# and a project part so both overlay modes get exercised.
#
# Usage :  bash bake-idempotency.sh          # from the template tree or the image
#          SB=/some/dir bash bake-idempotency.sh
#
# Covers : hardened bake, .local opt-in, idempotency, forged-effective refusal,
# fidelity against the live ruleset, zero-host refusal, digest sensitivity.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sibling first : run from a template checkout, this must exercise the tree it
# sits in, not whatever older copy the image happens to carry.
for c in "${FW_BAKE:-}" "$SELF_DIR/../firewall-docker-setup.sh" \
         /usr/local/bin/firewall-docker-setup.sh; do
  if [ -n "$c" ] && [ -f "$c" ]; then BAKE="$c"; break; fi
done
for c in "${FW_DIGEST_LIB:-}" "$SELF_DIR/../../bin/firewall-digest.sh" \
         /usr/local/bin/firewall-digest.sh; do
  if [ -n "$c" ] && [ -f "$c" ]; then FW_DIGEST_LIB="$c"; break; fi
done
export FW_DIGEST_LIB
for c in "${DEVC_CONF_LIB:-}" "$SELF_DIR/../../bin/devc-conf.sh" \
         /usr/local/bin/devc-conf.sh; do
  if [ -n "$c" ] && [ -f "$c" ]; then DEVC_CONF_LIB="$c"; break; fi
done
export DEVC_CONF_LIB
# shellcheck source=/dev/null
. "$DEVC_CONF_LIB"
export FW_COMPILER="${FW_COMPILER:-/usr/local/bin/compile-policy.py}"
LIVE_FW="${LIVE_FW:-/etc/devcontainer-firewall}"
LIVE_RUN="${LIVE_RUN:-/var/run/devcontainer-firewall}"

SB="${SB:-$(mktemp -d)}"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $*"; }
ko() { FAIL=$((FAIL+1)); echo "  ✘ $*"; }

echo "bake     : $BAKE"
echo "digest   : $FW_DIGEST_LIB"
echo "sandbox  : $SB"

# --- fixture -------------------------------------------------------------
# Split the live merged tree the way the image does : base-image content on
# one side, project overlay on the other.
mkdir -p "$SB/base" "$SB/src"
for f in dnsmasq.conf addons tests; do
  cp -a "$LIVE_FW/$f" "$SB/base/" 2>/dev/null
done
for f in domains.txt domains.local.txt domains.d policy.d policy.local.d \
         default-mode ports.txt CLAUDE.md; do
  cp -a "$LIVE_FW/$f" "$SB/src/" 2>/dev/null
done

bake() { "$BAKE" --base "$SB/base" --src "$SB/src" --dest "$1"; }

# --- T2 : hardened bake --------------------------------------------------
echo
echo "== T2 — hardened bake (no opt-in) =="
out=$(bake "$SB/out-hard" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || { ko "exit $rc"; echo "$out" | sed 's/^/      /'; }
E="$SB/out-hard/effective"
for f in dnsmasq-domains-base.conf policy.compiled.yaml hosts.txt \
         sources.sha256 local-included; do
  if [ -s "$E/$f" ]; then ok "effective/$f present"; else ko "effective/$f missing"; fi
done
[ -f "$E/dnsmasq-domains-local.conf" ] && ok "effective/dnsmasq-domains-local.conf present" \
                                       || ko "effective/dnsmasq-domains-local.conf missing"
[ -s "$SB/out-hard/baked-at" ] && ok "baked-at stamped" || ko "baked-at missing"
if [ -s "$SB/out-hard/domains.local.txt" ]; then
  ko "domains.local.txt NOT excluded ($(wc -l < "$SB/out-hard/domains.local.txt") lines)"
else
  ok "domains.local.txt excluded"
fi
n=$(find "$SB/out-hard/policy.local.d" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 0 ] && ok "policy.local.d/ excluded" || ko "policy.local.d/ kept $n yaml"
[ "$(cat "$E/local-included")" = 0 ] && ok "local-included=0" || ko "local-included wrong"
HARD_HOSTS=$(wc -l < "$E/hosts.txt" | tr -d ' ')

# --- T3 : opt-in ---------------------------------------------------------
echo
echo "== T3 — opted-in bake =="
out=$(FIREWALL_ALLOW_LOCAL_AT_REBUILD=1 bake "$SB/out-local" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || { ko "exit $rc"; echo "$out" | sed 's/^/      /'; }
LOCAL_HOSTS=$(wc -l < "$SB/out-local/effective/hosts.txt" | tr -d ' ')
[ "$(cat "$SB/out-local/effective/local-included")" = 1 ] && ok "local-included=1" \
                                                          || ko "local-included wrong"
# "opt-in adds hosts" must be proven on a SEEDED source, never on the ambient
# one. The fixture copies the domains.local.txt of whatever container runs the
# suite: a dogfood has one, a bare image does not - so the "strictly more"
# assertion could NEVER hold there. That is what made it fail everywhere but
# here (2026-08-10).
cp -a "$SB/src" "$SB/src-seed"
printf '[GET] bake-idempotency-fixture.invalid\n' >> "$SB/src-seed/domains.local.txt"
out=$(FIREWALL_ALLOW_LOCAL_AT_REBUILD=1 "$BAKE" --base "$SB/base" --src "$SB/src-seed" \
      --dest "$SB/out-seed" 2>&1) || echo "$out" | sed 's/^/      /'
SEED_HOSTS=$(wc -l < "$SB/out-seed/effective/hosts.txt" | tr -d ' ')
[ "$SEED_HOSTS" -gt "$HARD_HOSTS" ] \
  && ok "opt-in does add a host ($SEED_HOSTS > $HARD_HOSTS, seeded source)" \
  || ko "opt-in adds nothing: $SEED_HOSTS !> $HARD_HOSTS (seeded source)"
[ "$LOCAL_HOSTS" -ge "$HARD_HOSTS" ] \
  && ok "ambient opt-in drops no host ($LOCAL_HOSTS >= $HARD_HOSTS)" \
  || ko "ambient opt-in LOST hosts: $LOCAL_HOSTS < $HARD_HOSTS"
[ "$(cat "$SB/out-hard/effective/sources.sha256")" \
  != "$(cat "$SB/out-local/effective/sources.sha256")" ] \
  && ok "the two bakes have different digests" || ko "digests collide"

# --- T4 : idempotency ----------------------------------------------------
echo
echo "== T4 — re-run against the same dest =="
cp -a "$SB/out-hard" "$SB/out-hard-snapshot"
out=$(bake "$SB/out-hard" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || ko "exit $rc"
echo "$out" | grep -q 'no-op' && ok "short-circuited on digest match" \
                              || { ko "recompiled"; echo "$out" | sed 's/^/      /'; }
if diff -r "$SB/out-hard-snapshot/effective" "$SB/out-hard/effective" > "$SB/idem.diff" 2>&1; then
  ok "effective/ byte-identical across runs"
else
  ko "effective/ drifted :"; sed 's/^/      /' "$SB/idem.diff"
fi

# --- T4b : a forged effective/ in the sources must not be trusted --------
echo
echo "== T4b — forged effective/ in the project sources =="
# effective/ lives under the workspace firewall/ dir, which any postinstall can
# write. Shipping a hand-made effective/ plus a sources.sha256 matching the
# legitimate sources would otherwise short-circuit the bake and install the
# attacker's ruleset verbatim.
mkdir -p "$SB/src/effective"
cp "$SB/out-hard/effective/sources.sha256" "$SB/src/effective/sources.sha256"
cp "$SB/out-hard/effective/local-included" "$SB/src/effective/local-included"
cp "$SB/out-hard/effective/hosts.txt"      "$SB/src/effective/hosts.txt"
cp "$SB/out-hard/effective/policy.compiled.yaml" "$SB/src/effective/policy.compiled.yaml"
{ cat "$SB/out-hard/effective/dnsmasq-domains-base.conf"
  echo 'server=/evil.example.com/1.1.1.1'
  echo 'ipset=/evil.example.com/allowed-domains-base'
} > "$SB/src/effective/dnsmasq-domains-base.conf"
touch "$SB/src/effective/dnsmasq-domains-local.conf"
echo "1999-01-01T00:00:00Z" > "$SB/src/baked-at"
out=$(bake "$SB/out-forged" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || ko "exit $rc"
if grep -q 'evil.example.com' "$SB/out-forged/effective/dnsmasq-domains-base.conf"; then
  ko "FORGED RULESET INSTALLED — the bake trusted a source-provided effective/"
else
  ok "forged effective/ discarded, ruleset recompiled from sources"
fi
grep -q '1999-01-01' "$SB/out-forged/baked-at" && ko "forged baked-at kept" \
                                               || ok "forged baked-at discarded"
rm -rf "$SB/src/effective" "$SB/src/baked-at"

# --- T5 : fidelity against the live ruleset ------------------------------
echo
echo "== T5 — baked output vs the live running ruleset =="
if [ -r "$LIVE_RUN/dnsmasq-domains-base.conf" ]; then
  # init-firewall.sh deletes server= lines for ollama, claude-bridge and every
  # ports.txt host from the live conf after compiling. Replay that on
  # the candidate, and drop the Generated-at stamp on both sides.
  tcp_hosts=$(ports_entries "$(ports_file "$LIVE_FW")" 2>/dev/null \
              | cut -d: -f1 | sed 's/\./\\./g' | paste -sd'|' -)
  norm() {
    grep -v '^# Generated-at:' "$1" \
      | grep -vE '^server=/(ollama\.(internal|local)|claude-bridge)/' \
      | { [ -n "$tcp_hosts" ] && grep -vE "^server=/($tcp_hosts)/" || cat; }
  }
  norm "$SB/out-local/effective/dnsmasq-domains-base.conf" > "$SB/cand-base.conf"
  norm "$LIVE_RUN/dnsmasq-domains-base.conf"               > "$SB/live-base.conf"
  if diff -u "$SB/live-base.conf" "$SB/cand-base.conf" > "$SB/fidelity.diff" 2>&1; then
    ok "base conf matches live ($(grep -c '^server=' "$SB/cand-base.conf") server lines)"
  else
    ko "base conf diverges :"; head -30 "$SB/fidelity.diff" | sed 's/^/      /'
  fi
  if diff -u <(grep -v '^# Generated-at:' "$LIVE_RUN/dnsmasq-domains-local.conf") \
             <(grep -v '^# Generated-at:' "$SB/out-local/effective/dnsmasq-domains-local.conf") \
             > "$SB/fidelity-local.diff" 2>&1; then
    ok "local conf matches live"
  else
    ko "local conf diverges :"; head -20 "$SB/fidelity-local.diff" | sed 's/^/      /'
  fi
else
  echo "  — skipped ($LIVE_RUN not readable, firewall probably off)"
fi

# --- T6 : zero-host refusal ---------------------------------------------
echo
echo "== T6 — empty ruleset must be refused =="
mkdir -p "$SB/src-empty"
: > "$SB/src-empty/domains.txt"
echo basic > "$SB/src-empty/default-mode"
out=$("$BAKE" --base "$SB/base" --src "$SB/src-empty" --dest "$SB/out-empty" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "refused (exit $rc)" || ko "accepted an empty ruleset"
[ ! -f "$SB/out-empty/effective/hosts.txt" ] && ok "nothing promoted" || ko "promoted anyway"

# --- T7 : digest sensitivity --------------------------------------------
echo
echo "== T7 — the digest must move for every compiler input =="
# shellcheck source=/dev/null
. "$FW_DIGEST_LIB"
D="$SB/dig"; rm -rf "$D"; cp -a "$SB/out-local" "$D"
BASELINE=$(fw_sources_digest "$D" 1)
moved() {
  local label="$1" d
  d=$(fw_sources_digest "$D" "${2:-1}")
  [ "$d" != "$BASELINE" ] && ok "moves on $label" || ko "BLIND to $label"
}
echo x >> "$D/domains.txt";                      moved "domains.txt"
cp -a "$SB/out-local/domains.txt" "$D/"
echo x >> "$D/domains.local.txt";                moved "domains.local.txt"
cp -a "$SB/out-local/domains.local.txt" "$D/"
echo strict > "$D/default-mode";                 moved "default-mode"
cp -a "$SB/out-local/default-mode" "$D/"
echo x > "$D/domains.d/zz-probe.txt";            moved "domains.d/ addition"
rm -f "$D/domains.d/zz-probe.txt"
echo "hosts: {}" > "$D/policy.d/zz-probe.yaml";  moved "policy.d/ addition"
rm -f "$D/policy.d/zz-probe.yaml"
echo "hosts: {}" > "$D/policy.local.d/zz.yaml";  moved "policy.local.d/ addition"
rm -f "$D/policy.local.d/zz.yaml"
cp "$FW_COMPILER" "$SB/drifted-compiler.py"
echo "# drift" >> "$SB/drifted-compiler.py"
( FW_COMPILER="$SB/drifted-compiler.py"; moved "compile-policy.py version" )
moved "local-included flag" 0

echo
echo "=========================================="
echo "PASS=$PASS  FAIL=$FAIL   sandbox=$SB"
[ "$FAIL" -eq 0 ]
