#!/usr/bin/env bash
# reload-strict-isolated.sh — E2E: strict-mode hot-reload + port-gate contract
#
# HOST-RUNNABLE ONLY (needs Docker). The strict-mode twin of
# reload-basic-isolated.sh: same bench, same port-gate contract, plus the L7
# layer that only exists here (mitmproxy as a forward proxy, method policing,
# zero-downtime addon reload).
#
#   [3]  mitmdump is running — strict actually started its L7 layer
#   [4]  allowlisted host reaches upstream THROUGH the proxy
#   [5]  non-allowlisted host blocked (L3 DNS, or L7 403 from the addon)
#   [6]  reload-firewall applies a new host, exit 0
#   [7]  … in under 500 ms
#   [8]  the new host answers a GET afterwards
#   [9]  … but a POST to it is still 403 — L7 method policing survived reload
#   [10] baseline still reachable — no regression
#   [11] mitmdump PID unchanged — the reload was in-place, not a restart
#   [12] portal-test:4242 ALLOWED           — per-port ACCEPT
#   [13] portal-test:4241 BLOCKED           — same host, unlisted port
#   [14] host.docker.internal:<unlisted> BLOCKED — the host is not open
#   [15] host.docker.internal:<seeded>   ALLOWED — … except the port opted into
#
# WHY [12]-[15] ARE RUN AGAIN HERE
# --------------------------------
# The packet-filter rules are emitted BEFORE the mode branch in
# init-firewall.sh: the per-entry `--dport … -j ACCEPT` and the RFC1918 REJECTs
# are the same iptables chain in both modes, and OUTPUT evaluates them the same
# way whether or not mitmproxy exists. So strict *should* behave identically —
# but "should, by reading the code" is not a measurement, and the whole point of
# this session was that an unmeasured promise is not a promise. If strict ever
# diverges, these four are where it surfaces.
#
# They are asserted with a DIRECT curl, no proxy, deliberately. In strict the
# shell exports HTTPS_PROXY, but a hostile process does not honour it — it opens
# a socket. Testing through the proxy would measure the application's manners
# instead of the sandbox. Note the consequence, which is by design and worth
# knowing: a `ports.txt` entry is a hole in the L7 audit too, not just in the
# packet filter. Traffic to an opted-in port never reaches mitmproxy.
#
# Usage (from packages/devcontainer-sandbox):
#   bash test/reload-strict-isolated.sh
#   IMG=ghcr.io/…/devcontainer-sandbox:0.5.0-cc2.1.220 bash test/reload-strict-isolated.sh
#
# Success: exit 0, "✔ VALIDATION PASSED", "__END__" sentinel.

set -uo pipefail

PG_TAG=strict
PG_MODE=strict
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portgate-common.sh"

echo "═══ reload-strict-isolated.sh — image under test: $IMG ═══"

pg_bring_up_bench
pg_witness
pg_seed_and_boot

NET_NOTE="(or the host uplink is down — check before blaming the firewall)"

echo
echo "═══ [3] mitmdump is running (strict actually started its L7 layer) ═══"
PID_BEFORE=$(dex pgrep -x mitmdump 2>/dev/null | head -1)
[ -n "$PID_BEFORE" ] \
  && echo "  ✔ mitmdump PID=$PID_BEFORE" \
  || fail "mitmdump not running — strict boot failed, every L7 assertion below is vacuous"

echo
echo "═══ [4] Baseline through the proxy — api.anthropic.com must reach upstream ═══"
CODE=$(curl_proxy GET "https://api.anthropic.com/v1/models")
case "$CODE" in
  200) echo "  ✔ baseline HTTP=200" ;;
  401|403) echo "  ✔ baseline reached upstream (HTTP=$CODE)" ;;
  *) fail "baseline HTTP=$CODE (expected 200/401/403) $NET_NOTE" ;;
esac

echo
echo "═══ [5] Pre-reload — example.org must be blocked (L3 DNS or L7 403) ═══"
CODE=$(curl_proxy GET "https://example.org")
case "$CODE" in
  403)         echo "  ✔ example.org HTTP=403 (L7 addon rejected the host)" ;;
  000|502|504) echo "  ✔ example.org HTTP=$CODE (L3 DNS/gateway blocked)" ;;
  *)           fail "example.org HTTP=$CODE (expected 403 L7, or 000/502/504 L3)" ;;
esac

echo
echo "═══ [6] Append example.org to the .local layer + reload ═══"
dex sh -c "printf '\nexample.org\n' >> $WS_FW_DIR/domains.local.txt"
echo "  ✔ $WS_FW_DIR/domains.local.txt appended"
RELOAD_OUT=$(printf 'yes\n' | docker exec -i -u 0 -e "WORKSPACE_FW_DIR=$WS_FW_DIR" "$CONTAINER" \
               script -qec /usr/local/bin/reload-firewall /dev/null 2>&1)
RELOAD_RC=$?
echo "$RELOAD_OUT" | sed 's/^/    /'
[ $RELOAD_RC -eq 0 ] && echo "  ✔ reload-firewall exited 0" || fail "reload-firewall exit=$RELOAD_RC"

echo
echo "═══ [7] Elapsed < 500 ms ═══"
ELAPSED=$(echo "$RELOAD_OUT" | grep -oE 'elapsed: [0-9]+ms' | grep -oE '[0-9]+' | head -1)
if [ -n "$ELAPSED" ] && [ "$ELAPSED" -lt 500 ]; then
  echo "  ✔ elapsed=${ELAPSED}ms (< 500ms budget)"
elif [ -n "$ELAPSED" ]; then
  fail "elapsed=${ELAPSED}ms (over the 500ms budget)"
else
  fail "elapsed line not parseable from the reload output"
fi

echo
echo "═══ [8] Post-reload — example.org GET must reach upstream ═══"
CODE=$(curl_proxy GET "https://example.org")
[ "$CODE" = "200" ] \
  && echo "  ✔ example.org GET HTTP=200 (DNS + ipset + addon mtime-reload cooperated)" \
  || fail "example.org GET HTTP=$CODE (expected 200 after reload) $NET_NOTE"

echo
echo "═══ [9] Post-reload L7 — example.org POST must still be 403 ═══"
# Widening the allowlist must not widen the METHOD policy: a host added at
# runtime is readable, not writable. If this returns 200 the reload quietly
# dropped L7 policing, and strict has silently become basic.
CODE=$(curl_proxy POST "https://example.org")
[ "$CODE" = "403" ] \
  && echo "  ✔ example.org POST HTTP=403 (strict L7 method-policing fired)" \
  || fail "example.org POST HTTP=$CODE (expected 403 method:POST — L7 policy lost on reload?)"

echo
echo "═══ [10] Baseline survived the reload ═══"
CODE=$(curl_proxy GET "https://api.anthropic.com/v1/models")
case "$CODE" in
  200|401|403) echo "  ✔ baseline still reachable (HTTP=$CODE) — no regression" ;;
  *) fail "baseline regressed after reload (HTTP=$CODE) $NET_NOTE" ;;
esac

echo
echo "═══ [11] Zero-downtime — mitmdump PID unchanged ═══"
PID_AFTER=$(dex pgrep -x mitmdump 2>/dev/null | head -1)
if [ -n "$PID_BEFORE" ] && [ "$PID_BEFORE" = "$PID_AFTER" ]; then
  echo "  ✔ mitmdump PID=$PID_AFTER (unchanged — addon mtime-reload in-place)"
elif [ -z "$PID_AFTER" ]; then
  fail "mitmdump is GONE after the reload — strict lost its L7 layer entirely"
else
  fail "mitmdump PID_BEFORE=$PID_BEFORE PID_AFTER=$PID_AFTER (process restarted, in-flight connections dropped)"
fi

# [12]-[15] — the same port-gate contract as basic, measured rather than assumed.
pg_assert_port_gate

pg_verdict
