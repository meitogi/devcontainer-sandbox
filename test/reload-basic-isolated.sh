#!/usr/bin/env bash
# reload-basic-isolated.sh — E2E: basic-mode hot-reload + port-gate contract
#
# HOST-RUNNABLE ONLY (needs Docker). Boots the image under test in basic mode
# (DNS + ipset, no mitmproxy L7), drives direct curl through the firewall,
# triggers reload-firewall, and asserts twelve things — of which the last four
# are the security frontier this suite exists for:
#
#   [3]  allowlisted host reaches upstream directly (no L7 proxy in basic)
#   [4]  non-allowlisted host blocked (dnsmasq NXDOMAIN → curl 000)
#   [5]  reload-firewall applies a new host, exit 0
#   [6]  … in under 500 ms
#   [7]  the new host is reachable afterwards
#   [8]  allowed-domains-base survived the reload (baseline still up)
#   [9]  portal-test:4242 ALLOWED     — per-port ACCEPT fires before the REJECT
#   [10] portal-test:4241 BLOCKED     — same host, unlisted port: not all-or-nothing
#   [11] host.docker.internal:<unlisted> BLOCKED — the host is not open
#   [12] host.docker.internal:<seeded>   ALLOWED — … except the port opted into
#
# [9]-[12] are the whole promise of `ports.txt`: opening a host port opens THAT
# PORT, not the host. init-firewall.sh emits `-d <ip> -p tcp --dport <port> -j
# ACCEPT` per entry, before the 10/8 + 172.16/12 + 192.168/16 REJECTs. They are
# shared with the strict suite (pg_assert_port_gate) because the contract is the
# same on both sides of the mode branch — see test/lib/portgate-common.sh, which
# also documents the witness and why the bench is built the way it is.
#
# Usage (from packages/devcontainer-sandbox):
#   bash test/reload-basic-isolated.sh
#   IMG=ghcr.io/…/devcontainer-sandbox:0.5.0-cc2.1.220 bash test/reload-basic-isolated.sh
#
# Success: exit 0, "✔ VALIDATION PASSED", "__END__" sentinel. Any failed
# assertion increments FAIL and the script exits 1 — silence is not success.

set -uo pipefail

PG_TAG=basic
PG_MODE=basic
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portgate-common.sh"

echo "═══ reload-basic-isolated.sh — image under test: $IMG ═══"

pg_bring_up_bench
pg_witness
pg_seed_and_boot

# [3], [4], [7], [8] cross the real internet. A dead uplink and a working
# firewall produce the same 000, so say so in the failure text rather than
# reporting a regression the code did not cause.
NET_NOTE="(or the host uplink is down — check before blaming the firewall)"

echo
echo "═══ [3] Baseline — api.anthropic.com must reach upstream ═══"
CODE=$(curl_direct "https://api.anthropic.com/v1/models")
case "$CODE" in
  200) echo "  ✔ baseline HTTP=200" ;;
  401|403) echo "  ✔ baseline reached upstream (HTTP=$CODE — no L7 in basic)" ;;
  *) fail "baseline HTTP=$CODE (expected 200/401/403) $NET_NOTE" ;;
esac

echo
echo "═══ [4] Pre-reload — example.org must be blocked (dnsmasq NXDOMAIN) ═══"
CODE=$(curl_direct "https://example.org")
[ "$CODE" = "000" ] \
  && echo "  ✔ example.org HTTP=000 (L3 DNS blocked as expected)" \
  || fail "example.org HTTP=$CODE (expected 000 from NXDOMAIN in basic)"

echo
echo "═══ [5] Append example.org to the .local layer + reload ═══"
dex sh -c "printf '\nexample.org\n' >> $WS_FW_DIR/domains.local.txt"
echo "  ✔ $WS_FW_DIR/domains.local.txt appended"
# reload-firewall demands a TTY and an interactive `yes`. `script -qec` supplies
# both — the very bypass its own header documents as trivial. Using it here is
# the point: the TTY and CLAUDECODE checks are honesty guards, so a test
# simulating a human may look like one. The barrier that actually holds is root,
# and `docker exec -u 0` is how we cross it.
RELOAD_OUT=$(printf 'yes\n' | docker exec -i -u 0 -e "WORKSPACE_FW_DIR=$WS_FW_DIR" "$CONTAINER" \
               script -qec /usr/local/bin/reload-firewall /dev/null 2>&1)
RELOAD_RC=$?
echo "$RELOAD_OUT" | sed 's/^/    /'
[ $RELOAD_RC -eq 0 ] && echo "  ✔ reload-firewall exited 0" || fail "reload-firewall exit=$RELOAD_RC"

echo
echo "═══ [6] Elapsed < 500 ms ═══"
ELAPSED=$(echo "$RELOAD_OUT" | grep -oE 'elapsed: [0-9]+ms' | grep -oE '[0-9]+' | head -1)
if [ -n "$ELAPSED" ] && [ "$ELAPSED" -lt 500 ]; then
  echo "  ✔ elapsed=${ELAPSED}ms (< 500ms budget)"
elif [ -n "$ELAPSED" ]; then
  fail "elapsed=${ELAPSED}ms (over the 500ms budget)"
else
  fail "elapsed line not parseable from the reload output"
fi

echo
echo "═══ [7] Post-reload — example.org must now reach upstream ═══"
CODE=$(curl_direct "https://example.org")
[ "$CODE" = "200" ] \
  && echo "  ✔ example.org HTTP=200 (DNS + ipset cooperated on reload)" \
  || fail "example.org HTTP=$CODE (expected 200 after reload) $NET_NOTE"

echo
echo "═══ [8] Baseline survived the reload ═══"
CODE=$(curl_direct "https://api.anthropic.com/v1/models")
case "$CODE" in
  200|401|403) echo "  ✔ baseline still reachable (HTTP=$CODE) — allowed-domains-base preserved" ;;
  *) fail "baseline regressed after reload (HTTP=$CODE) — allowed-domains-base flushed? $NET_NOTE" ;;
esac

# [9]-[12] — the port-gate + host isolation contract, shared with strict.
pg_assert_port_gate

pg_verdict
