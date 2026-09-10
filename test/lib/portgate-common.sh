#!/usr/bin/env bash
# portgate-common.sh — the shared bench for the port-gate E2E suites.
#
# SOURCED, never executed. reload-basic-isolated.sh and reload-strict-isolated.sh
# assert different things about the SAME contract: a port listed in ports.txt is
# reachable, and nothing else is. The bench that establishes that — the network,
# the sibling, the two "host" servers, and above all the witness — is identical,
# so it lives here exactly once.
#
# That is not tidiness. Every subtlety below was paid for in a debugging round,
# and a second copy would rot away from this one the way the v2 suites did:
#
#   - the host servers are CONTAINERS with published ports, not host processes.
#     bash 3.2 (macOS) does not keep a job backgrounded inside a command
#     substitution, and a server lost that way reports nothing at all.
#   - the port is chosen by binding 127.0.0.1:<port> SPECIFICALLY. Docker
#     Desktop forwards host.docker.internal to the Mac's loopback, so a process
#     holding that address wins; a wildcard 0.0.0.0 publish coexists beside it
#     with no conflict for Docker to report. VS Code's Code Helper sits on
#     127.0.0.1:8765 and defeated three different implementations this way.
#   - the witness has ONE vantage point: an unconfined sibling on the same
#     network. Never the host loopback — that is a different network path from
#     the one under test, and it fails for reasons that are not the firewall.
#
# Caller contract, before sourcing:
#   PG_TAG   — short suite id, used in container/network names (e.g. basic)
#   PG_MODE  — basic | strict, written to default-mode
# After sourcing, call pg_bring_up_bench, then pg_witness, then pg_seed_and_boot.

IMG="${IMG:-devcontainer-sandbox:local}"

NET_NAME="fw-portgate-${PG_TAG}-net-$$"
CONTAINER="fw-portgate-${PG_TAG}-$$"
PORTAL="fw-portgate-${PG_TAG}-portal-$$"
HOST_SRV_BLOCKED="fw-portgate-${PG_TAG}-hostsrv-blocked-$$"
HOST_SRV_ALLOWED="fw-portgate-${PG_TAG}-hostsrv-allowed-$$"

# Starting candidates only — the real pair is whatever Docker can publish on a
# free loopback. A developer Mac is a crowded place.
HOST_PORT_BLOCKED="8765"
HOST_PORT_ALLOWED="8766"

# Scratch stand-in for the workspace .local layer. The container under test gets
# NO workspace mount: reload-firewall reads WORKSPACE_FW_DIR, so the layer lives
# inside the container and the host tree is never touched.
WS_FW_DIR="/tmp/fw-local"

FAIL=0
fail() { echo "  ❌ $*"; FAIL=$((FAIL + 1)); }

setup_fatal() {
  echo "  ❌ FATAL setup — $*" >&2
  echo "     An endpoint unreachable from OUTSIDE the sandbox makes every" >&2
  echo "     'blocked' result below meaningless. Refusing to report a green" >&2
  echo "     run measured against a broken bench." >&2
  exit 1
}

pg_cleanup() {
  docker rm -f "$HOST_SRV_BLOCKED" >/dev/null 2>&1
  docker rm -f "$HOST_SRV_ALLOWED" >/dev/null 2>&1
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  docker rm -f "$PORTAL"    >/dev/null 2>&1
  docker network rm "$NET_NAME" >/dev/null 2>&1
  return 0
}
trap 'pg_cleanup; echo "__END__"' EXIT

command -v docker >/dev/null 2>&1 || { echo "❌ FATAL: docker not on PATH" >&2; exit 1; }
docker image inspect "$IMG" >/dev/null 2>&1 || {
  echo "❌ FATAL: image $IMG not found — build it, or set IMG=<tag>" >&2; exit 1; }

dex() { docker exec -u 0 "$CONTAINER" "$@"; }

# Direct curl, no proxy. This is the ADVERSARIAL framing and the only honest one
# for a port test: a hostile process in the container does not politely honour
# HTTPS_PROXY, it opens a socket. So the port gate is interrogated at the packet
# filter, in both modes.
curl_direct() {
  local url="$1" code
  code=$(dex curl -sS -m 15 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  echo "${code:0:3}"
}

# Through mitmproxy — strict only, for the L7 assertions.
curl_proxy() {
  local method="$1" url="$2" code
  code=$(dex curl -sS -m 15 -x http://127.0.0.1:8080 -o /dev/null \
           -w "%{http_code}" -X "$method" "$url" 2>/dev/null || echo "000")
  if [ "$code" = "000" ]; then
    sleep 2
    code=$(dex curl -sS -m 15 -x http://127.0.0.1:8080 -o /dev/null \
             -w "%{http_code}" -X "$method" "$url" 2>/dev/null || echo "000")
  fi
  echo "${code:0:3}"
}

start_host_server() {          # start_host_server <name> <port> <label>
  docker run -d --name "$1" -p "$2:80" busybox sh -c "
    mkdir -p /w
    echo 'host mini-server $2 ($3)' > /w/index.html
    httpd -f -p 0.0.0.0:80 -h /w
  " >/dev/null 2>&1
}

# Publishing on 0.0.0.0 neither establishes nor detects that the LOOPBACK is
# free — and the loopback is what host.docker.internal lands on. Probe with a
# throwaway container so no host runtime is needed; publish the real server on
# 0.0.0.0 so this still works on plain Linux Docker, where the gateway is the
# bridge and a loopback-only publish would be unreachable.
port_free_on_loopback() {      # port_free_on_loopback <port>
  docker run --rm -p "127.0.0.1:$1:80" busybox true >/dev/null 2>&1
}

claim_port() {                 # claim_port <name> <first candidate> <label>
  local name="$1" p="$2" label="$3" limit=$(( $2 + 40 ))
  while [ "$p" -lt "$limit" ]; do
    if port_free_on_loopback "$p" && start_host_server "$name" "$p" "$label"; then
      echo "$p"; return 0
    fi
    docker rm -f "$name" >/dev/null 2>&1
    p=$(( p + 1 ))
  done
  return 1
}

pg_bring_up_bench() {
  echo
  echo "═══ [Setup 1/4] Isolated Docker network ═══"
  docker network create "$NET_NAME" >/dev/null || setup_fatal "could not create network $NET_NAME"
  echo "  ✔ network created: $NET_NAME"

  echo
  echo "═══ [Setup 2/4] portal-test sibling (busybox httpd :4242 + :4241) ═══"
  docker run -d --name "$PORTAL" \
    --network "$NET_NAME" \
    --network-alias portal-test \
    --entrypoint sh \
    busybox -c '
      mkdir -p /w4242 /w4241
      echo "portal 4242 OK" > /w4242/index.html
      echo "portal 4241 OK" > /w4241/index.html
      httpd -f -p 0.0.0.0:4242 -h /w4242 &
      httpd -f -p 0.0.0.0:4241 -h /w4241 &
      wait
    ' >/dev/null || setup_fatal "could not start the portal-test sibling"
  echo "  ✔ portal-test sibling started (aliases: portal-test:4242 + portal-test:4241)"

  echo
  echo "═══ [Setup 3/4] Host mini-servers, published from Docker ═══"
  HOST_PORT_BLOCKED=$(claim_port "$HOST_SRV_BLOCKED" "$HOST_PORT_BLOCKED" unauthorized) \
    || setup_fatal "no publishable host port in 8765-8805 for the unlisted server"
  HOST_PORT_ALLOWED=$(claim_port "$HOST_SRV_ALLOWED" $(( HOST_PORT_BLOCKED + 1 )) allowed) \
    || setup_fatal "no publishable host port after $HOST_PORT_BLOCKED for the seeded server"
  echo "  ✔ host servers published: :$HOST_PORT_BLOCKED (unlisted) + :$HOST_PORT_ALLOWED (seeded)"

  echo
  echo "═══ [Setup 4/4] Container under test ($PG_MODE mode, no workspace mount) ═══"
  # Faithful to templates/v3 docker-compose.yml: the two caps init-firewall.sh
  # needs, and nothing else. No --privileged, no bind mount — the image is the
  # thing under test, not the repo.
  docker run -d \
    --name "$CONTAINER" \
    --network "$NET_NAME" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --add-host=host.docker.internal:host-gateway \
    --entrypoint sleep \
    "$IMG" infinity >/dev/null || setup_fatal "could not start the container under test"
  echo "  ✔ container running: $CONTAINER"
}

witness_sibling() {            # witness_sibling <url> — retries; run -d returns early
  local i=0
  while [ "$i" -lt 20 ]; do
    docker run --rm --network "$NET_NAME" \
      --add-host=host.docker.internal:host-gateway \
      busybox wget -q -T 5 -O /dev/null "$1" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 0.5
  done
  return 1
}

host_srv_fatal() {             # host_srv_fatal <port> <container> <why>
  echo "  ── docker logs $2 ──" >&2
  docker logs "$2" 2>&1 | tail -10 | sed 's/^/     /' >&2
  echo "  ── port publication ──" >&2
  docker port "$2" 2>&1 | sed 's/^/     /' >&2
  setup_fatal "host.docker.internal:$1 unreachable from an UNCONFINED sibling —
     the server is not serving, or the host gateway does not route there. $3"
}

# Every endpoint proven reachable from outside the sandbox BEFORE anything is
# measured through the firewall. A "blocked" result is only evidence if the
# target was answering in the first place; otherwise a dead bench reads exactly
# like a working firewall.
pg_witness() {
  echo
  echo "═══ [Witness] Each endpoint answers from OUTSIDE the firewall ═══"

  witness_sibling "http://portal-test:4242/" \
    && echo "  ✔ portal-test:4242 answers (unconfined sibling)" \
    || setup_fatal "portal-test:4242 does NOT answer — the allowed-port assertion would be meaningless"

  witness_sibling "http://portal-test:4241/" \
    && echo "  ✔ portal-test:4241 answers (unconfined sibling)" \
    || setup_fatal "portal-test:4241 does NOT answer — the blocked-port assertion would be a false pass"

  witness_sibling "http://host.docker.internal:$HOST_PORT_BLOCKED/" \
    && echo "  ✔ host.docker.internal:$HOST_PORT_BLOCKED answers (unconfined sibling)" \
    || host_srv_fatal "$HOST_PORT_BLOCKED" "$HOST_SRV_BLOCKED" "Host isolation would be a false 'blocked'."

  witness_sibling "http://host.docker.internal:$HOST_PORT_ALLOWED/" \
    && echo "  ✔ host.docker.internal:$HOST_PORT_ALLOWED answers (unconfined sibling)" \
    || host_srv_fatal "$HOST_PORT_ALLOWED" "$HOST_SRV_ALLOWED" "The host opt-in would be a false failure."
}

# Forces the mode, seeds the port gate, boots the firewall. Leaves the output in
# INIT_OUT for the caller to assert on.
pg_seed_and_boot() {
  echo
  echo "═══ [1] Force $PG_MODE mode + seed the port gate ═══"
  dex sh -c "echo $PG_MODE > /etc/devcontainer-firewall/default-mode"
  # Container-scoped, transient: no workspace mutation, nothing to snapshot.
  # Two entries prove both ways of the gate — sibling container AND host
  # gateway via the `host` keyword.
  dex sh -c "printf 'portal-test:4242\nhost:$HOST_PORT_ALLOWED\n' >> /etc/devcontainer-firewall/ports.txt"
  dex mkdir -p "$WS_FW_DIR"
  echo "  ✔ $PG_MODE mode, portal-test:4242 + host:$HOST_PORT_ALLOWED seeded"

  echo
  echo "═══ [2] Boot the firewall (init-firewall.sh) ═══"
  INIT_OUT=$(dex /usr/local/bin/init-firewall.sh 2>&1)
  INIT_RC=$?
  echo "$INIT_OUT" | tail -25 | sed 's/^/    /'
  [ $INIT_RC -ne 0 ] && echo "  ⚠ non-zero exit ($INIT_RC) — inspecting state anyway"
  if echo "$INIT_OUT" | grep -q "Firewall ready ($PG_MODE"; then
    echo "  ✔ $PG_MODE marker present in init-firewall output"
  else
    fail "$PG_MODE marker MISSING — init-firewall did not complete"
  fi

  # Which IP the `host` keyword resolved to decides the two host assertions.
  # Print it: when they disagree with expectation, this line says whether the
  # rule was ever emitted or the resolution went somewhere else entirely.
  HOST_RULE=$(echo "$INIT_OUT" | grep -E "Direct TCP allow: host " || true)
  [ -n "$HOST_RULE" ] \
    && echo "  ℹ  $(echo "$HOST_RULE" | sed 's/^[[:space:]]*//')" \
    || echo "  ℹ  no 'Direct TCP allow: host' line — the host: seed resolved to nothing"
  sleep 1
}

# The four port-gate assertions. IDENTICAL in both modes by construction: the
# ports.txt ACCEPT rules and the RFC1918 REJECTs are emitted before any
# mode branch, so OUTPUT evaluates them the same way with or without mitmproxy.
# Running them in both modes is what turns that reading of the code into a
# measurement — and if strict ever diverges, this is where it shows.
pg_assert_port_gate() {
  echo
  echo "═══ Port-gate — portal-test:4242 ALLOWED (per-port ACCEPT) ═══"
  CODE=$(curl_direct "http://portal-test:4242/")
  [ "$CODE" = "200" ] \
    && echo "  ✔ portal-test:4242 HTTP=200 (ports.txt ACCEPT beats the RFC1918 REJECT)" \
    || fail "portal-test:4242 HTTP=$CODE (expected 200 from the ports.txt seed)"

  echo
  echo "═══ Port-gate — portal-test:4241 BLOCKED (same host, unlisted port) ═══"
  CODE=$(curl_direct "http://portal-test:4241/")
  case "$CODE" in
    000) echo "  ✔ portal-test:4241 HTTP=000 (RFC1918 REJECT catches the unlisted port)" ;;
    200) fail "portal-test:4241 HTTP=200 — an unlisted port on a listed host is OPEN: the gate is all-or-nothing" ;;
    *)   fail "portal-test:4241 HTTP=$CODE (expected 000 — RFC1918 REJECT should catch)" ;;
  esac

  echo
  echo "═══ Host isolation — host.docker.internal:$HOST_PORT_BLOCKED BLOCKED ═══"
  CODE=$(curl_direct "http://host.docker.internal:$HOST_PORT_BLOCKED/")
  case "$CODE" in
    000) echo "  ✔ host.docker.internal:$HOST_PORT_BLOCKED HTTP=000 (host isolated)" ;;
    200) fail "host.docker.internal:$HOST_PORT_BLOCKED HTTP=200 — HOST PORT REACHED FROM THE CONTAINER.
       This is a sandbox escape, not a test nit: any process in the container
       can reach arbitrary host services. The witness proved this port was
       serving, so the firewall is what failed." ;;
    *)   fail "host.docker.internal:$HOST_PORT_BLOCKED HTTP=$CODE (expected 000)" ;;
  esac

  echo
  echo "═══ Host opt-in — host.docker.internal:$HOST_PORT_ALLOWED ALLOWED ═══"
  CODE=$(curl_direct "http://host.docker.internal:$HOST_PORT_ALLOWED/")
  [ "$CODE" = "200" ] \
    && echo "  ✔ host.docker.internal:$HOST_PORT_ALLOWED HTTP=200 (per-port ACCEPT for the \`host\` keyword)" \
    || fail "host.docker.internal:$HOST_PORT_ALLOWED HTTP=$CODE (expected 200 — the host: seed did not punch through)"
}

pg_verdict() {                 # pg_verdict <suite label>
  echo
  echo "═══ FULL VALIDATION COMPLETE ═══"
  if [ "$FAIL" -gt 0 ]; then
    echo "❌ VALIDATION FAILED — $FAIL assertion(s) failed"
    exit 1
  fi
  echo "✔ VALIDATION PASSED"
  exit 0
}
