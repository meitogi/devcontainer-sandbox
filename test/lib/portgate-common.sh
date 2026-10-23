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
PUB_NET="fw-portgate-${PG_TAG}-pub-$$"
PUB_ECHO="fw-portgate-${PG_TAG}-pub-echo-$$"
PRIV_ECHO="fw-portgate-${PG_TAG}-priv-echo-$$"

# Starting candidates only — the real pair is whatever Docker can publish on a
# free loopback. A developer Mac is a crowded place.
HOST_PORT_BLOCKED="8765"
HOST_PORT_ALLOWED="8766"

# Scratch stand-in for the workspace .local layer. The container under test gets
# NO workspace mount: reload-firewall reads WORKSPACE_FW_DIR, so the layer lives
# inside the container and the host tree is never touched.
WS_FW_DIR="/tmp/fw-local"

# inbound.txt bench: two UDP listeners and one TCP listener inside the container
# under test, only one UDP and the TCP port listed. Fixed ports are safe here —
# they are bound inside the container's own namespace, nothing is published.
INBOUND_UDP=50101           # listed, with the `out` flag
INBOUND_UDP_UNLISTED=50102  # listening, NOT listed
INBOUND_TCP=50103           # listed
INBOUND_UDP_PLAIN=50104     # listed, NO flag — opens nothing outbound

# The `out` bench needs a destination that is not RFC1918 and still answers
# offline : a second network on TEST-NET-2 (198.51.100.0/24, RFC 5737 — never
# routed on the internet, so it cannot collide with anything the daemon has),
# an echo sibling on it, and the container under test attached to both. A
# datagram to 198.51.100.x is "public" as far as the REJECTs are concerned.
# A /28 slice per suite : the basic and strict suites run side by side
# (everything else here is suffixed with $$), and Docker refuses two networks
# on overlapping pools — measured, the second run died at setup. The slot comes
# from the mode, not the pid, so two concurrent runs can never share one.
case "$PG_MODE" in basic) PUB_SLOT=0 ;; strict) PUB_SLOT=1 ;; *) PUB_SLOT=$(( $$ % 14 + 2 )) ;; esac
PUB_SUBNET="198.51.100.$(( PUB_SLOT * 16 ))/28"
ECHO_PORT=4000

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
  docker rm -f "$PUB_ECHO"  >/dev/null 2>&1
  docker rm -f "$PRIV_ECHO" >/dev/null 2>&1
  docker network rm "$NET_NAME" >/dev/null 2>&1
  docker network rm "$PUB_NET"  >/dev/null 2>&1
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

# Echo servers, one thread per `proto:port` argument: every payload comes back
# prefixed with `echo:`. A reply proves the round trip — the datagram got IN
# and the answer got OUT — which "the listener saw a packet" would not: the
# reply path is its own rule (init-firewall.sh § 5a).
INBOUND_SERVER_PY='
import socket, sys, threading
def udp(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", p))
    while True:
        d, a = s.recvfrom(2048); s.sendto(b"echo:" + d, a)
def tcp(p):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", p)); s.listen()
    while True:
        c, _ = s.accept(); c.sendall(b"echo:" + c.recv(2048)); c.close()
ts = []
for a in sys.argv[1:]:
    proto, port = a.split(":")
    ts.append(threading.Thread(target=udp if proto == "udp" else tcp, args=(int(port),), daemon=True))
for t in ts: t.start()
for t in ts: t.join()
'

# Prints the reply, or nothing. UDP is retried three times: one lost datagram
# must not read as a closed port.
INBOUND_CLIENT_PY='
import socket, sys
proto, host, port, msg = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4].encode()
try:
    if proto == "udp":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
        for _ in range(3):
            s.sendto(msg, (host, port))
            try:
                print(s.recv(2048).decode()); break
            except socket.timeout:
                pass
    else:
        s = socket.create_connection((host, port), timeout=3); s.sendall(msg)
        print(s.recv(2048).decode())
except OSError:
    pass
'

# From INSIDE the container under test, as node, from a CHOSEN source port, to
# an address outside : the `out` contract is about which source port may open
# a flow. Prints the reply, `EPERM` when the firewall rejects the send (the
# OUTPUT REJECT answers with an ICMP admin-prohibited, which the kernel hands
# back as errno 1 on the very sendto), or nothing on a timeout — three
# different readings, so a REJECT is never mistaken for a lost datagram.
OUTBOUND_CLIENT_PY='
import errno, socket, sys
host, port, sport, msg = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
s.bind(("0.0.0.0", sport))
try:
    for _ in range(3):
        s.sendto(msg, (host, port))
        try:
            print(s.recv(2048).decode()); break
        except socket.timeout:
            pass
except OSError as e:
    print("EPERM" if e.errno == errno.EPERM else f"errno {e.errno}")
'
outbound_probe() {           # outbound_probe <dest ip> <dest port> <source port> <payload>
  docker exec -u node "$CONTAINER" python3 -c "$OUTBOUND_CLIENT_PY" "$1" "$2" "$3" "$4" 2>/dev/null
}

# The address of a sibling on a given network — the container under test
# resolves nothing but the allowlist (dnsmasq, no-resolv), so names are out.
sibling_ip() {               # sibling_ip <container> <network>
  docker inspect -f "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1" 2>/dev/null
}

# From INSIDE the container under test, as node, over loopback (always accepted).
inbound_probe_local() {        # inbound_probe_local <proto> <port> <payload>
  docker exec -u node "$CONTAINER" python3 -c "$INBOUND_CLIENT_PY" "$1" 127.0.0.1 "$2" "$3" 2>/dev/null
}

# From an UNCONFINED sibling on the same network: the image itself, firewall
# never started — the same client code as the local probe, so a client bug
# cannot pass one side and fail the other.
inbound_probe_sibling() {      # inbound_probe_sibling <proto> <port> <payload>
  docker run --rm --network "$NET_NAME" --entrypoint python3 "$IMG" \
    -c "$INBOUND_CLIENT_PY" "$1" "$CONTAINER" "$2" "$3" 2>/dev/null
}

pg_bring_up_bench() {
  echo
  echo "═══ [Setup 1/5] Isolated Docker networks (RFC1918 + TEST-NET-2) ═══"
  docker network create "$NET_NAME" >/dev/null || setup_fatal "could not create network $NET_NAME"
  echo "  ✔ network created: $NET_NAME"
  docker network create --subnet "$PUB_SUBNET" "$PUB_NET" >/dev/null \
    || setup_fatal "could not create network $PUB_NET on $PUB_SUBNET"
  echo "  ✔ network created: $PUB_NET ($PUB_SUBNET, public-like)"

  echo
  echo "═══ [Setup 2/5] portal-test sibling (busybox httpd :4242 + :4241) ═══"
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
  echo "═══ [Setup 3/5] Host mini-servers, published from Docker ═══"
  HOST_PORT_BLOCKED=$(claim_port "$HOST_SRV_BLOCKED" "$HOST_PORT_BLOCKED" unauthorized) \
    || setup_fatal "no publishable host port in 8765-8805 for the unlisted server"
  HOST_PORT_ALLOWED=$(claim_port "$HOST_SRV_ALLOWED" $(( HOST_PORT_BLOCKED + 1 )) allowed) \
    || setup_fatal "no publishable host port after $HOST_PORT_BLOCKED for the seeded server"
  echo "  ✔ host servers published: :$HOST_PORT_BLOCKED (unlisted) + :$HOST_PORT_ALLOWED (seeded)"

  echo
  echo "═══ [Setup 4/5] Container under test ($PG_MODE mode, no workspace mount) ═══"
  # Faithful to the template's docker-compose.yml: the two caps init-firewall.sh
  # needs, and nothing else. No --privileged, no bind mount — the image is the
  # thing under test, not the repo.
  docker run -d \
    --name "$CONTAINER" \
    --network "$NET_NAME" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --add-host=host.docker.internal:host-gateway \
    --entrypoint sleep \
    "$IMG" infinity >/dev/null || setup_fatal "could not start the container under test"
  # Attached to the public-like network too, before the firewall boots, the
  # way a container comes up with every interface it will ever have.
  docker network connect "$PUB_NET" "$CONTAINER" || setup_fatal "could not attach $CONTAINER to $PUB_NET"
  echo "  ✔ container running: $CONTAINER (+ $PUB_NET)"

  echo
  echo "═══ [Setup 5/5] UDP echo siblings — one public-like, one private ═══"
  # The image itself, firewall never started, the same echo code as the
  # inbound listeners : a reply proves the round trip, not just the arrival.
  docker run -d --name "$PUB_ECHO" --network "$PUB_NET" --entrypoint python3 \
    "$IMG" -c "$INBOUND_SERVER_PY" "udp:$ECHO_PORT" >/dev/null \
    || setup_fatal "could not start the public-like echo sibling"
  docker run -d --name "$PRIV_ECHO" --network "$NET_NAME" --entrypoint python3 \
    "$IMG" -c "$INBOUND_SERVER_PY" "udp:$ECHO_PORT" >/dev/null \
    || setup_fatal "could not start the private echo sibling"
  PUB_ECHO_IP=$(sibling_ip "$PUB_ECHO" "$PUB_NET")
  PRIV_ECHO_IP=$(sibling_ip "$PRIV_ECHO" "$NET_NAME")
  [ -n "$PUB_ECHO_IP" ] && [ -n "$PRIV_ECHO_IP" ] || setup_fatal "echo siblings have no address"
  echo "  ✔ echo siblings: $PUB_ECHO_IP:$ECHO_PORT (public-like) + $PRIV_ECHO_IP:$ECHO_PORT (private)"
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

  # The two echo siblings, from an unconfined sibling on THEIR network. `run -d`
  # returns before python listens, hence the retries.
  local net ip i reply
  for net in "$PUB_NET:$PUB_ECHO_IP" "$NET_NAME:$PRIV_ECHO_IP"; do
    ip="${net#*:}"; net="${net%%:*}"; i=0
    until reply=$(docker run --rm --network "$net" --entrypoint python3 "$IMG" \
                    -c "$INBOUND_CLIENT_PY" udp "$ip" "$ECHO_PORT" w 2>/dev/null); [ "$reply" = "echo:w" ]; do
      i=$((i + 1)); [ "$i" -ge 20 ] && setup_fatal "echo sibling $ip:$ECHO_PORT does NOT answer — every 'rejected' outbound result would be meaningless"
      sleep 0.5
    done
    echo "  ✔ $ip:$ECHO_PORT echoes (unconfined sibling on $net)"
  done
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
  # Written AFTER the image's bake, like any change between two boots: the
  # rules must come from what init-firewall.sh reads now, not from a frozen set.
  # Three entries : the `out` flag on one UDP port, a plain UDP port beside it
  # (listed is not opted in), and the TCP form.
  dex sh -c "printf 'udp:$INBOUND_UDP out\nudp:$INBOUND_UDP_PLAIN\ntcp:$INBOUND_TCP\n' >> /etc/devcontainer-firewall/inbound.txt"
  dex mkdir -p "$WS_FW_DIR"
  echo "  ✔ $PG_MODE mode, portal-test:4242 + host:$HOST_PORT_ALLOWED seeded, udp:$INBOUND_UDP out"

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

# inbound.txt — a listed port takes a new flow from outside AND answers it; an
# unlisted one stays shut; IPv6 opens nothing. Same rules in both modes (§ 5a is
# before the mode branch), measured in both for the reason given above.
pg_assert_inbound() {
  local tag="inbound-$$" reply

  echo
  echo "═══ Inbound — listeners as node (udp:$INBOUND_UDP listed, udp:$INBOUND_UDP_UNLISTED not, tcp:$INBOUND_TCP listed) ═══"
  docker exec -d -u node "$CONTAINER" python3 -c "$INBOUND_SERVER_PY" \
    "udp:$INBOUND_UDP" "udp:$INBOUND_UDP_UNLISTED" "tcp:$INBOUND_TCP" \
    || setup_fatal "could not start the inbound listeners"
  echo "$INIT_OUT" | grep -E '📥 Inbound allow' | sed 's/^[[:space:]]*/  ℹ  /'

  # Witness: every listener answers over loopback first. Otherwise "no echo from
  # the sibling" below would be a dead listener, not a closed port.
  local p proto port i
  for p in "udp:$INBOUND_UDP" "udp:$INBOUND_UDP_UNLISTED" "tcp:$INBOUND_TCP"; do
    proto="${p%%:*}"; port="${p##*:}"; i=0
    until [ "$(inbound_probe_local "$proto" "$port" w)" = "echo:w" ]; do
      i=$((i + 1)); [ "$i" -ge 20 ] && setup_fatal "listener $p does not answer over loopback"
      sleep 0.5
    done
    echo "  ✔ (witness) $p answers over loopback"
  done

  echo
  echo "═══ Inbound — udp:$INBOUND_UDP LISTED, a datagram from a sibling round-trips ═══"
  reply=$(inbound_probe_sibling udp "$INBOUND_UDP" "$tag-udp")
  local udp_ok=false
  if [ "$reply" = "echo:$tag-udp" ]; then
    udp_ok=true
    echo "  ✔ udp:$INBOUND_UDP echoed '$reply' (INPUT ACCEPT in, ESTABLISHED reply out)"
  else
    fail "udp:$INBOUND_UDP got '${reply:-nothing}' (expected 'echo:$tag-udp') — inbound or reply rule missing"
  fi

  echo
  echo "═══ Inbound — udp:$INBOUND_UDP_UNLISTED NOT listed, stays shut ═══"
  reply=$(inbound_probe_sibling udp "$INBOUND_UDP_UNLISTED" "$tag-closed")
  if [ -n "$reply" ]; then
    fail "udp:$INBOUND_UDP_UNLISTED answered '$reply' — an UNLISTED port is open from outside"
  elif $udp_ok; then
    echo "  ✔ udp:$INBOUND_UDP_UNLISTED no answer (INPUT DROP; the listed port proved the client works)"
  else
    fail "udp:$INBOUND_UDP_UNLISTED no answer, but inconclusive — the listed port failed too"
  fi

  echo
  echo "═══ Inbound — tcp:$INBOUND_TCP LISTED, a connection from a sibling round-trips ═══"
  reply=$(inbound_probe_sibling tcp "$INBOUND_TCP" "$tag-tcp")
  [ "$reply" = "echo:$tag-tcp" ] \
    && echo "  ✔ tcp:$INBOUND_TCP echoed '$reply'" \
    || fail "tcp:$INBOUND_TCP got '${reply:-nothing}' (expected 'echo:$tag-tcp')"

  echo
  echo "═══ Inbound — IPv6 stays fully dropped ═══"
  local v6
  v6=$(dex ip6tables -S INPUT 2>&1)
  if echo "$v6" | grep -q -- '-P INPUT DROP' && ! echo "$v6" | grep -q -- '--dport'; then
    echo "  ✔ ip6tables INPUT: policy DROP, no --dport exception"
  else
    fail "ip6tables INPUT is not 'DROP with no port exception':
$(echo "$v6" | sed 's/^/       /')"
  fi
}

# inbound.txt `out` — the opted-in port may OPEN a UDP flow to a public-like
# address and gets the answer back ; a listed port without the flag cannot, an
# unlisted one cannot, and the opted-in port still cannot reach a private
# address (the rule sits after the RFC1918 REJECTs). In strict the flag is
# ignored : nothing opens, and the boot log says so. Run BEFORE
# pg_assert_inbound — its listeners would hold the source ports this binds.
pg_assert_outbound_udp() {
  local tag="out-$$" reply

  echo
  echo "═══ Outbound UDP opt-in — the boot log ═══"
  if [ "$PG_MODE" = "basic" ]; then
    echo "$INIT_OUT" | grep -qF "⚠ Outbound UDP opt-in: udp/$INBOUND_UDP" \
      && echo "  ✔ boot log warns: udp/$INBOUND_UDP may open NEW flows to any public address" \
      || fail "boot log has no '⚠ Outbound UDP opt-in: udp/$INBOUND_UDP' line — the cost is not named"
  else
    echo "$INIT_OUT" | grep -qF "'udp:$INBOUND_UDP out' ignored in strict mode" \
      && echo "  ✔ boot log says the flag is ignored in strict" \
      || fail "boot log does not say 'udp:$INBOUND_UDP out' is ignored in strict"
  fi
  echo "$INIT_OUT" | grep -qF "⚠ Outbound UDP opt-in: udp/$INBOUND_UDP_PLAIN" \
    && fail "boot log warns about udp/$INBOUND_UDP_PLAIN, which has NO flag — the flag is not what opens the port"

  echo
  echo "═══ Outbound UDP opt-in — udp:$INBOUND_UDP out → $PUB_ECHO_IP:$ECHO_PORT (public-like) ═══"
  reply=$(outbound_probe "$PUB_ECHO_IP" "$ECHO_PORT" "$INBOUND_UDP" "$tag-pub")
  if [ "$PG_MODE" = "basic" ]; then
    [ "$reply" = "echo:$tag-pub" ] \
      && echo "  ✔ sport $INBOUND_UDP reached a public-like address and got the echo (NEW accepted, reply ESTABLISHED)" \
      || fail "sport $INBOUND_UDP got '${reply:-nothing}' (expected 'echo:$tag-pub') — the 'out' rule is missing or misplaced"
  else
    [ "$reply" = "EPERM" ] \
      && echo "  ✔ sport $INBOUND_UDP rejected (EPERM) — the flag opens nothing in strict" \
      || fail "sport $INBOUND_UDP got '${reply:-nothing}' in strict (expected EPERM) — the flag was honoured despite the L7 audit"
  fi

  echo
  echo "═══ Outbound UDP opt-in — udp:$INBOUND_UDP_PLAIN listed WITHOUT the flag → public-like ═══"
  reply=$(outbound_probe "$PUB_ECHO_IP" "$ECHO_PORT" "$INBOUND_UDP_PLAIN" "$tag-plain")
  case "$reply" in
    EPERM) echo "  ✔ sport $INBOUND_UDP_PLAIN rejected (EPERM) — listed is not opted in" ;;
    echo:*) fail "sport $INBOUND_UDP_PLAIN got '$reply' — a listed port WITHOUT the flag opens outbound: the flag is decorative" ;;
    *) fail "sport $INBOUND_UDP_PLAIN got '${reply:-nothing}' (expected EPERM) — inconclusive, not a REJECT" ;;
  esac

  echo
  echo "═══ Outbound UDP opt-in — udp:$INBOUND_UDP_UNLISTED not listed → public-like ═══"
  reply=$(outbound_probe "$PUB_ECHO_IP" "$ECHO_PORT" "$INBOUND_UDP_UNLISTED" "$tag-unlisted")
  case "$reply" in
    EPERM) echo "  ✔ sport $INBOUND_UDP_UNLISTED rejected (EPERM) — an unlisted port opens nothing" ;;
    echo:*) fail "sport $INBOUND_UDP_UNLISTED got '$reply' — an UNLISTED port opens outbound" ;;
    *) fail "sport $INBOUND_UDP_UNLISTED got '${reply:-nothing}' (expected EPERM) — inconclusive, not a REJECT" ;;
  esac

  echo
  echo "═══ Outbound UDP opt-in — the non-public REJECTs all precede the NEW rule ═══"
  # The echo probe above measures one private range ; the ruleset itself must
  # show every non-public range — RFC1918 and link-local — before any `out`
  # ACCEPT, or the « public addresses only » promise has a hole the bench does
  # not reach (169.254/16 has no echo sibling here).
  local rules first_out
  rules=$(dex iptables -S OUTPUT 2>/dev/null)
  first_out=$(echo "$rules" | grep -n -- '--sport [0-9]* -m state --state NEW -j ACCEPT' | head -1 | cut -d: -f1)
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    local at
    at=$(echo "$rules" | grep -n -- "-d $net -j REJECT" | head -1 | cut -d: -f1)
    if [ -z "$at" ]; then
      fail "no OUTPUT REJECT for $net — a non-public range the out rule would reach"
    elif [ -n "$first_out" ] && [ "$at" -gt "$first_out" ]; then
      fail "OUTPUT REJECT for $net comes AFTER the first out ACCEPT (rule $at > $first_out)"
    fi
  done
  if [ "$PG_MODE" = "basic" ] && [ -z "$first_out" ]; then
    fail "no '--sport … --state NEW -j ACCEPT' rule in OUTPUT at all (basic)"
  elif [ "$PG_MODE" != "basic" ] && [ -n "$first_out" ]; then
    fail "an out ACCEPT rule exists in OUTPUT in $PG_MODE mode (rule $first_out)"
  fi
  if [ "$FAIL" -eq 0 ]; then
    if [ -n "$first_out" ]; then
      echo "  ✔ REJECTs for 10/8, 172.16/12, 192.168/16, 169.254/16 all precede the out ACCEPT (rule $first_out)"
    else
      echo "  ✔ REJECTs for 10/8, 172.16/12, 192.168/16, 169.254/16 present — and no out ACCEPT exists in $PG_MODE"
    fi
  fi

  echo
  echo "═══ Outbound UDP opt-in — udp:$INBOUND_UDP out → $PRIV_ECHO_IP:$ECHO_PORT (private) stays shut ═══"
  reply=$(outbound_probe "$PRIV_ECHO_IP" "$ECHO_PORT" "$INBOUND_UDP" "$tag-priv")
  case "$reply" in
    EPERM) echo "  ✔ sport $INBOUND_UDP to a private address rejected (EPERM) — the rule sits after the RFC1918 REJECTs" ;;
    echo:*) fail "sport $INBOUND_UDP reached a PRIVATE address '$reply' — the 'out' rule is before the RFC1918 REJECTs: siblings and the host are exposed" ;;
    *) fail "sport $INBOUND_UDP to a private address got '${reply:-nothing}' (expected EPERM) — inconclusive" ;;
  esac
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
