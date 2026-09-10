#!/usr/bin/env bash
# Phase 2 firewall — start mitmproxy as a forward HTTP/HTTPS proxy.
# Called by init-firewall.sh BEFORE the default DROP policy is applied
# (legacy ordering — A3 made the binary build-time, so the window is no
# longer strictly required, but keeping it preserves later flexibility).
#
# Architecture: force-proxy mode. Apps reach mitmproxy via HTTPS_PROXY env
# var (set system-wide by init-firewall.sh). Apps that bypass the proxy are
# blocked by the iptables filter (only mitmproxy's UID can reach external IPs
# in strict mode). mitmproxy itself resolves via 127.0.0.53 (dnsmasq) so
# the DNS allowlist remains the single source of truth.
#
# A3: mitmproxy binary baked at /opt/mitmproxy/ in the image (no runtime pip).
# Idempotent daemon restart if already running.
# Fail-stop: any error → exit non-zero, init-firewall.sh aborts strict setup.

set -Eeuo pipefail

MITM_ROOT=/var/lib/mitmproxy
MITM_BIN=/opt/mitmproxy/mitmdump
MITM_LOG=/var/log/mitmproxy.log
MITM_CA_CERT="$MITM_ROOT/mitmproxy-ca-cert.pem"
MITM_USER=mitmproxy

# Guard: only meaningful in strict mode. Caller (init-firewall.sh) should
# already gate this, but double-check so manual invocations are safe. Legacy
# alias `paranoid` accepted for backward-compat.
case "${FIREWALL_MODE:-strict}" in
  strict|paranoid) ;;
  *)
    echo "  mitm-init: FIREWALL_MODE != strict — skipping."
    exit 0 ;;
esac

# Sanity: the system user must exist (created in Dockerfile).
if ! id -u "$MITM_USER" >/dev/null 2>&1; then
  echo "❌ mitm-init: user '$MITM_USER' missing — rebuild the image."
  exit 1
fi

mkdir -p "$MITM_ROOT"
# mitmdump runs as user mitmproxy and writes the CA into $MITM_ROOT, so the
# directory must be owned by that user BEFORE we invoke it. Done here so a
# failed first run still leaves a usable state for the next attempt.
chown "$MITM_USER:$MITM_USER" "$MITM_ROOT"

# -------------------------------
# 1. mitmproxy binary baked in image (A3) — sanity check only
# -------------------------------
if [ ! -x "$MITM_BIN" ]; then
  echo "❌ mitm-init: $MITM_BIN missing or not executable — rebuild the image."
  exit 1
fi
ln -sf "$MITM_BIN" /usr/local/bin/mitmdump

# -------------------------------
# 2. Generate CA if missing
# -------------------------------
# mitmdump generates the CA on first start when confdir lacks one. Start
# briefly on a non-standard port (18080), wait for the cert file, then kill.
# stderr is captured so we can surface the actual error if generation fails.
if [ ! -f "$MITM_CA_CERT" ]; then
  echo "🔑 Generating mitmproxy CA in $MITM_ROOT..."
  CA_GEN_LOG=$(mktemp)
  sudo -u "$MITM_USER" "$MITM_BIN" \
    --set confdir="$MITM_ROOT" \
    --listen-port 18080 \
    --quiet >"$CA_GEN_LOG" 2>&1 &
  CA_PID=$!
  for _ in $(seq 1 30); do
    [ -f "$MITM_CA_CERT" ] && break
    sleep 0.3
  done
  kill "$CA_PID" 2>/dev/null || true
  wait "$CA_PID" 2>/dev/null || true
  if [ ! -f "$MITM_CA_CERT" ]; then
    echo "❌ mitmproxy CA generation failed. mitmdump output:"
    cat "$CA_GEN_LOG" | sed 's/^/   /'
    rm -f "$CA_GEN_LOG"
    exit 1
  fi
  rm -f "$CA_GEN_LOG"
  echo "✓ CA generated."
fi

# Final perms: public cert world-readable, private key 600.
chmod 644 "$MITM_CA_CERT"
[ -f "$MITM_ROOT/mitmproxy-ca.pem" ] && chmod 600 "$MITM_ROOT/mitmproxy-ca.pem"

# -------------------------------
# 3. Propagate CA to system trust store
# -------------------------------
TRUST_DST=/usr/local/share/ca-certificates/mitmproxy-ca.crt
if [ ! -f "$TRUST_DST" ] || ! cmp -s "$MITM_CA_CERT" "$TRUST_DST"; then
  cp "$MITM_CA_CERT" "$TRUST_DST"
  update-ca-certificates >/dev/null
  echo "✓ CA installed in system trust store."
fi

# -------------------------------
# 4. Start mitmdump as daemon (regular HTTP forward proxy mode)
# -------------------------------
# Apps are forced to use the proxy via HTTPS_PROXY/HTTP_PROXY env vars
# (see post-start.sh + shell-init.sh). Apps that bypass the proxy can't
# reach the internet because the firewall only ACCEPTs outbound from the
# mitmproxy UID (see init-firewall.sh §6 strict filter rule).
pkill -u "$MITM_USER" -x mitmdump 2>/dev/null || true
sleep 0.2

# A2 — log files owned by mitmproxy:adm with mode 640. User `node` reads
# them via membership in `adm` (added at build-time in Dockerfile). All
# three logs are appended by the addons (writes / blocks) or mitmdump
# itself (mitmproxy.log) — must be writable by mitmproxy.
MITM_WRITES_LOG=/var/log/mitmproxy-writes.log
MITM_BLOCKS_LOG=/var/log/mitmproxy-blocks.log
touch "$MITM_LOG" "$MITM_WRITES_LOG" "$MITM_BLOCKS_LOG"
chown "$MITM_USER:adm" "$MITM_LOG" "$MITM_WRITES_LOG" "$MITM_BLOCKS_LOG"
chmod 640              "$MITM_LOG" "$MITM_WRITES_LOG" "$MITM_BLOCKS_LOG"

# A2 — load enforcement addons (policy_enforce, format_detect) before the
# observability addon (passive_log). mitmproxy chains --scripts in order, and
# an addon that sets flow.response short-circuits the rest — we want to
# block first, then only log requests that survived enforcement. The
# stream_sse addon hooks `responseheaders` (different lifecycle than the
# request chain) so its position doesn't matter for ordering.
ADDONS_DIR=/etc/devcontainer-firewall/addons

sudo -u "$MITM_USER" nohup "$MITM_BIN" \
  --mode regular \
  --showhost \
  --set confdir="$MITM_ROOT" \
  --set block_global=false \
  --listen-port 8080 \
  --scripts "$ADDONS_DIR/policy_enforce.py" \
  --scripts "$ADDONS_DIR/format_detect.py" \
  --scripts "$ADDONS_DIR/passive_log.py" \
  --scripts "$ADDONS_DIR/stream_sse.py" \
  --scripts "$ADDONS_DIR/capture_messages_debug.py" \
  >> "$MITM_LOG" 2>&1 &

# Wait up to ~5s for the proxy to accept connections
ready=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if nc -z 127.0.0.1 8080 2>/dev/null; then
    ready=true
    break
  fi
  sleep 0.5
done

if ! $ready; then
  echo "❌ mitmdump failed to bind 127.0.0.1:8080 — see $MITM_LOG"
  exit 1
fi

echo "✓ mitmdump listening on 127.0.0.1:8080 (UID=$(id -u "$MITM_USER"))"
