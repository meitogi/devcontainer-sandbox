#!/usr/bin/env bash
# frozen-fastpath.sh — does init-firewall.sh take the baked ruleset, and does
# it correctly refuse to?
#
# init-firewall.sh itself needs root, CAP_NET_ADMIN and a live namespace, so it
# cannot run here. Instead this extracts the frozen-set decision block VERBATIM
# from the real script and evaluates it against sandbox trees. Extracting
# rather than reimplementing is the point : a copy of the logic would pass
# while the shipped code rots.
#
# A false cache hit is a security bug, not a performance one — it means boot
# serving a ruleset that no longer matches the sources, silently. Every case
# below that expects `false` is guarding that.
#
# Usage :  bash frozen-fastpath.sh

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${FW_INIT:-$SELF_DIR/../../init-firewall.sh}"
BAKE="${FW_BAKE:-$SELF_DIR/../firewall-docker-setup.sh}"
export FW_DIGEST_LIB="${FW_DIGEST_LIB:-$SELF_DIR/../../bin/firewall-digest.sh}"
export FW_COMPILER="${FW_COMPILER:-/usr/local/bin/compile-policy.py}"
LIVE_FW="${LIVE_FW:-/etc/devcontainer-firewall}"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $*"; }
ko() { FAIL=$((FAIL+1)); echo "  ✘ $*"; }

SB="$(mktemp -d)"
echo "init     : $INIT"
echo "sandbox  : $SB"

# --- extract the decision block from the shipped script ------------------
sed -n '/^EFFECTIVE_DIR="\$FIREWALL_CONFIG_DIR\/effective"$/,/^fi$/p' "$INIT" > "$SB/decision.sh"
if [ ! -s "$SB/decision.sh" ]; then
  echo "✘ could not extract the decision block from $INIT — did its shape change?"
  exit 1
fi
grep -q 'fw_sources_digest' "$SB/decision.sh" \
  && ok "extracted the real decision block ($(wc -l < "$SB/decision.sh") lines)" \
  || { ko "extraction produced the wrong block"; exit 1; }

decide() {  # $1 = config dir -> prints "<USE_FROZEN> <FROZEN_REASON>"
  ( set -uo pipefail
    FIREWALL_CONFIG_DIR="$1"
    # shellcheck source=/dev/null
    . "$SB/decision.sh"
    echo "$USE_FROZEN|$FROZEN_REASON" )
}

# --- fixture : a real bake -----------------------------------------------
mkdir -p "$SB/base" "$SB/src"
for f in dnsmasq.conf addons tests; do cp -a "$LIVE_FW/$f" "$SB/base/" 2>/dev/null; done
for f in domains.txt domains.local.txt domains.d policy.d policy.local.d \
         default-mode ports.txt; do
  cp -a "$LIVE_FW/$f" "$SB/src/" 2>/dev/null
done
"$BAKE" --base "$SB/base" --src "$SB/src" --dest "$SB/cfg" >/dev/null 2>&1 \
  || { echo "✘ fixture bake failed"; exit 1; }

echo
echo "== C1 — freshly baked tree =="
r=$(decide "$SB/cfg")
[ "${r%%|*}" = true ] && ok "takes the frozen set" || ko "refused: ${r#*|}"

echo
echo "== C2 — sources edited after the bake =="
for probe in "domains.txt:echo drift.example >> \$C/domains.txt" \
             "domains.local.txt:echo drift.example >> \$C/domains.local.txt" \
             "default-mode:echo strict > \$C/default-mode" \
             "domains.d/:echo drift.example > \$C/domains.d/zz-probe.txt" \
             "policy.d/:printf 'hosts: {}\n' > \$C/policy.d/zz-probe.yaml" \
             "policy.local.d/:printf 'hosts: {}\n' > \$C/policy.local.d/zz-probe.yaml"; do
  label="${probe%%:*}"; cmd="${probe#*:}"
  rm -rf "$SB/mut"; cp -a "$SB/cfg" "$SB/mut"; C="$SB/mut"; eval "$cmd"
  r=$(decide "$SB/mut")
  if [ "${r%%|*}" = false ] && [[ "${r#*|}" == *"sources changed"* ]]; then
    ok "refuses after a change to $label"
  else
    ko "STALE HIT after a change to $label → $r"
  fi
done

echo
echo "== C3 — the .local layer smuggled in after a hardened bake =="
# reload-local.sh used to copy workspace .local files into /etc. Anything that
# lands there post-bake must invalidate the frozen set, or boot would keep
# serving the baked ruleset while the sources say otherwise.
rm -rf "$SB/mut"; cp -a "$SB/cfg" "$SB/mut"
# The content is irrelevant: what we simulate is a .local file APPEARING after
# a hardened bake. So write one instead of copying the ambient file - a bare
# image has none, the `cp` failed, the scenario was never set up and the
# assertion fell over (2026-08-10).
printf '[GET] smuggled-fixture.invalid\n' > "$SB/mut/domains.local.txt"
r=$(decide "$SB/mut")
[ "${r%%|*}" = false ] && ok "refuses when domains.local.txt appears in /etc" \
                       || ko "STALE HIT — smuggled .local ignored → $r"

echo
echo "== C4 — a legacy image with no bake at all =="
rm -rf "$SB/mut"; cp -a "$SB/cfg" "$SB/mut"; rm -rf "$SB/mut/effective"
r=$(decide "$SB/mut")
[ "${r%%|*}" = false ] && [[ "${r#*|}" == *"no baked"* ]] \
  && ok "falls back to compiling" || ko "unexpected: $r"

echo
echo "== C5 — a truncated or partial effective/ =="
for f in dnsmasq-domains-base.conf policy.compiled.yaml; do
  rm -rf "$SB/mut"; cp -a "$SB/cfg" "$SB/mut"; : > "$SB/mut/effective/$f"
  r=$(decide "$SB/mut")
  if [ "${r%%|*}" = false ] && [[ "${r#*|}" == *"incomplete"* ]]; then
    ok "refuses an empty $f"
  else
    ko "accepted an empty $f → $r"
  fi
done
rm -rf "$SB/mut"; cp -a "$SB/cfg" "$SB/mut"; rm -f "$SB/mut/effective/dnsmasq-domains-local.conf"
r=$(decide "$SB/mut")
[ "${r%%|*}" = false ] && ok "refuses a missing dnsmasq-domains-local.conf" \
                       || ko "accepted a missing local conf → $r"

echo
echo "== C6 — the compiler itself changed (base-image bump) =="
cp "$FW_COMPILER" "$SB/drifted-compiler.py"; echo "# drift" >> "$SB/drifted-compiler.py"
r=$(FW_COMPILER="$SB/drifted-compiler.py" decide "$SB/cfg")
[ "${r%%|*}" = false ] && ok "refuses when compile-policy.py changed" \
                       || ko "STALE HIT — compiler drift ignored → $r"

rm -rf "$SB"
echo
echo "=========================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
