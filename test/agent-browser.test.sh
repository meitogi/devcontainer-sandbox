#!/usr/bin/env bash
# The agent browser's control channel, end to end but without a browser: the
# container command (bin/agent-browser), the host supervisor and the sidecar
# supervisor, each driven against a scratch control directory with a fake
# Chromium that records its arguments. Then the proxy's own node tests.
#
#   bash test/agent-browser.test.sh        # in the container (bash 4, GNU coreutils, node)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/assets/opt/skills/agent-browser"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko() { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }
wait_for() {   # wait_for <seconds> <command…> → 0 when the command passes in time
	local n=$(( $1 * 4 )); shift
	while [ $n -gt 0 ]; do "$@" 2>/dev/null && return 0; sleep 0.25; n=$((n-1)); done
	return 1
}

TMP=$(mktemp -d)
CTL=$TMP/ctl; mkdir -p "$CTL/host" "$TMP/home" "$TMP/bin"
ARGS=$TMP/chromium.args
# A Chromium that records its arguments and stays up until killed.
cat >"$TMP/bin/chromium" <<EOS
#!/bin/sh
printf '%s\n' "\$@" >"$ARGS"
exec sleep 300
EOS
# One that dies at once, for the give-up path.
cat >"$TMP/bin/dying" <<EOS
#!/bin/sh
printf '%s\n' "\$@" >"$ARGS"
exit 1
EOS
chmod +x "$TMP/bin/chromium" "$TMP/bin/dying"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; sleep 0.3; pkill -f "$TMP/bin/" 2>/dev/null; pkill -f "cdp-proxy.mjs serve --listen 127.0.0.1:1922" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Every call of the command under test sees the scratch channel, the tree's kit
# and a small origin list ; the ports are high so a real agent never collides.
export AGENT_BROWSER_CTL="$CTL" DEVC_AGENT_BROWSER_KIT="$SKILL"
export AGENT_BROWSER_ORIGINS="http://localhost:5173 https://*.game.localhost:8443"
export AGENT_BROWSER_PROXY_PORT=19223 AGENT_BROWSER_CDP_PORT=19323 AGENT_BROWSER_WAIT_S=8
export AGENT_BROWSER_PORTS_BAKED="$TMP/ports-baked.txt" AGENT_BROWSER_PORTS_SOURCE="$TMP/ports-source.txt"
AB="$REPO/bin/agent-browser"
arg_has() { grep -qxF -- "$1" "$ARGS"; }
state_of() { cut -d' ' -f2- "$1/state" 2>/dev/null; }

start_host() {   # start_host [VAR=value…] → the host supervisor in the background with that env
	env AGENT_BROWSER_PROFILE="$TMP/home/profile" AGENT_BROWSER_LOGDIR="$TMP/home/logs" AGENT_BROWSER_CTL="$CTL/host" \
		AGENT_BROWSER_CHROMIUM="$TMP/bin/chromium" NODE="$(command -v node)" "$@" \
		bash "$SKILL/host/host-supervisor.sh" >"$TMP/host-supervisor.out" 2>&1 &
	HOST_PID=$!; PIDS+=("$HOST_PID")
}
stop_host() { kill "$HOST_PID" 2>/dev/null; wait "$HOST_PID" 2>/dev/null; }

echo "== no browser answers =="
out=$("$AB" env 2>&1); rc=$?
check "env exits 3 with the two human instructions when nothing answers" "[ $rc -eq 3 ] && grep -q 'HUMAN ACTION' <<<'$out' && grep -q 'host-kit' <<<'$out' && grep -q 'profile agent-browser up' <<<'$out'"
"$AB" status >"$TMP/status.out" 2>&1; rc=$?
check "status says route none and exits 3" "[ $rc -eq 3 ] && grep -q '^route     : none' '$TMP/status.out'"
printf 'host:19223\n' >"$TMP/ports-source.txt"
"$AB" status >"$TMP/status.out" 2>&1
check "status distinguishes 'in ports.txt but not baked'" "grep -q 'NOT baked yet' '$TMP/status.out'"
printf '# allow\nhost:19223   # the proxy\n' >"$TMP/ports-baked.txt"
"$AB" status >"$TMP/status.out" 2>&1
check "status reads the baked ports.txt (comments, inline comments)" "grep -q 'allowed (baked)' '$TMP/status.out'"
check "up refuses a URL outside the origins before writing anything" "! '$AB' up https://evil.test/ >/dev/null 2>&1 && [ ! -e '$CTL/host/cmd' ]"
check "up without AGENT_BROWSER_ORIGINS stops with the variable's name" "out=\$(env -u AGENT_BROWSER_ORIGINS '$AB' up http://localhost:5173/ 2>&1); [ \$? -eq 2 ] && grep -q AGENT_BROWSER_ORIGINS <<<\"\$out\""
check "hold writes a future epoch" "'$AB' hold 2 >/dev/null && [ \"\$(cat '$CTL/hold')\" -gt \$(date +%s) ]"
"$AB" host-kit | tar -tf - >"$TMP/host-kit.lst"; "$AB" sidecar-kit | tar -tf - >"$TMP/sidecar-kit.lst"
check "host-kit streams a tar with the proxy and the installer" "grep -q cdp-proxy.mjs '$TMP/host-kit.lst' && grep -q host-agent.sh '$TMP/host-kit.lst'"
check "sidecar-kit streams a tar with the Dockerfile and the supervisor" "grep -q Dockerfile '$TMP/sidecar-kit.lst' && grep -q supervisor.sh '$TMP/sidecar-kit.lst'"
check "host-agent.sh refuses to run inside a container" "out=\$(bash '$SKILL/host/host-agent.sh' status 2>&1); [ \$? -eq 2 ] && grep -q 'runs on the host' <<<\"\$out\""

echo "== host supervisor (fake Chromium, real proxy) =="
start_host
check "heartbeat appears, state idle" "wait_for 4 test -f '$CTL/host/heartbeat' && [ \"\$(state_of '$CTL/host')\" = 'idle - -' ]"
check "env routes to the host through the proxy" "[ \"\$('$AB' env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19223' ]"
out=$("$AB" up http://localhost:5173/ 2>&1); rc=$?
check "up → running, URL echoed, endpoint printed" "[ $rc -eq 0 ] && grep -q '^host: running [0-9]* http://localhost:5173/$' <<<'$out' && grep -q 'host.docker.internal:19223' <<<'$out'"
check "Chromium got the URL after --, headless, muted, on its DevTools port" "arg_has -- && arg_has http://localhost:5173/ && arg_has --headless=new && arg_has --mute-audio && arg_has --remote-debugging-port=19323 && arg_has --window-size=1280,800"
check "no Metal flag on a Linux host" "! arg_has --use-angle=metal"
check "WebRTC host candidates as addresses (no mDNS names the resolver rules would cut)" "arg_has --disable-features=WebRtcHideLocalIpsWithMdns"
check "the PAC and the resolver rules are generated from the origins" "grep -q '^--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,' '$ARGS' && grep -q '^--host-resolver-rules=MAP \* ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1, EXCLUDE \*.game.localhost$' '$ARGS'"
grep '^--proxy-pac-url=' "$ARGS" | sed 's/.*base64,//' | base64 -d >"$TMP/pac.js"
check "the PAC sends the origins DIRECT and nothing else" "grep -qF \"scheme === 'http' && host === 'localhost' && port === '5173'\" '$TMP/pac.js' && grep -qF \"dnsDomainIs(host, '.game.localhost') && port === '8443'\" '$TMP/pac.js' && grep -qF 'PROXY 127.0.0.1:9' '$TMP/pac.js'"
check "the proxy listens on the configured port" "wait_for 4 bash -c 'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:19223/json/protocol | grep -q 403'"
check "activity is touched by the command" "[ -f '$CTL/activity' ]"
check "stats answers four fields" "'$AB' stats >/dev/null && [ \"\$(wc -w <'$CTL/host/stats')\" -eq 4 ]"
printf '%s up https://evil.test/\n' "$(date +%s%N)" >"$CTL/host/cmd"
check "a raw cmd on a foreign URL is refused and the URL is not echoed back" "wait_for 4 bash -c '[ \"\$(cut -d\" \" -f2- $CTL/host/state)\" = \"stopped - -\" ]' && grep -q 'refused up: https://evil.test/' '$TMP/host-supervisor.out'"
before=$(cat "$CTL/host/state")
printf 'abc up http://localhost:5173/\n' >"$CTL/host/cmd"; sleep 2
check "a cmd without a numeric nonce is ignored" "[ \"\$(cat '$CTL/host/state')\" = '$before' ] && grep -q 'numeric nonce' '$TMP/host-supervisor.out'"
rm -f "$CTL/host/cmd"; ln -s /etc/hostname "$CTL/host/cmd"; sleep 2
check "a symlinked cmd is never read" "[ \"\$(cat '$CTL/host/state')\" = '$before' ]"
rm -f "$CTL/host/cmd"
check "the command refuses to write through a symlinked cmd" "ln -s /etc/hostname '$CTL/host/cmd' && ! '$AB' down >/dev/null 2>&1; rm -f '$CTL/host/cmd'"
printf -- '--disable-gpu-vsync --evil --window-size=800,600 --user-data-dir=/tmp\n' >"$CTL/host/flags"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
check "flags: only the bench switches pass, the rest is dropped and logged" "arg_has --disable-gpu-vsync && arg_has --window-size=800,600 && ! arg_has --evil && ! arg_has --user-data-dir=/tmp && grep -q 'dropped --evil' '$TMP/host-supervisor.out'"
rm -f "$CTL/host/flags"
printf '1 running 1 x\n' >"$CTL/state"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
check "up sends down to the other side when its state says running" "grep -q ' down$' '$CTL/cmd'"
rm -f "$CTL/cmd" "$CTL/state"
pid=$(cut -d' ' -f3 "$CTL/host/state")
"$AB" down >"$TMP/down.out" 2>&1
check "down → stopped and the fake Chromium is gone" "grep -q '^host: stopped' '$TMP/down.out' && wait_for 3 bash -c '! kill -0 $pid'"
cp "$TMP/bin/dying" "$TMP/bin/chromium"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
check "three deaths at start → the supervisor gives up, state stopped" "wait_for 20 grep -q 'giving up' '$TMP/host-supervisor.out' && wait_for 4 bash -c '[ \"\$(cut -d\" \" -f2 $CTL/host/state)\" = stopped ]'"
stop_host
check "TERM → state stopped, heartbeat removed" "wait_for 4 bash -c '[ ! -e $CTL/host/heartbeat ]' && [ \"\$(cut -d' ' -f2 '$CTL/host/state')\" = stopped ]"
cat >"$TMP/bin/chromium" <<EOS
#!/bin/sh
printf '%s\n' "\$@" >"$ARGS"
exec sleep 300
EOS
start_host AGENT_BROWSER_AUDIO=on AGENT_BROWSER_WINDOW=1 AGENT_BROWSER_SIZE=1920,1080
wait_for 4 test -f "$CTL/host/heartbeat"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
check "AUDIO=on, WINDOW=1, SIZE: no mute, no headless, the size" "! arg_has --mute-audio && ! arg_has --headless=new && arg_has --window-size=1920,1080"
"$AB" down >/dev/null 2>&1
stop_host

echo "== instances (a second browser, b) =="
out=$("$AB" -i 1 env 2>&1); rc=$?
check "an instance is one letter : -i 1 exits 2" "[ $rc -eq 2 ] && grep -q 'one letter' <<<'$out'"
out=$("$AB" -i b env 2>&1); rc=$?
check "instance b with nothing answering exits 3, naming b" "[ $rc -eq 3 ] && grep -q 'agent browser b answers' <<<'$out'"
mkdir -p "$CTL/b/host"
start_host AGENT_BROWSER_CTL="$CTL/b/host" AGENT_BROWSER_PROFILE="$TMP/home/profile-b" AGENT_BROWSER_PROXY_PORT=19224 AGENT_BROWSER_CDP_PORT=19324
wait_for 4 test -f "$CTL/b/host/heartbeat"
check "-i b env : the next proxy port (base + 1)" "[ \"\$('$AB' -i b env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19224' ]"
check "AGENT_BROWSER_INSTANCE=b is the same as -i b" "[ \"\$(AGENT_BROWSER_INSTANCE=b '$AB' env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19224' ]"
check "instance a is not routed to b's browser (exit 3)" "! '$AB' env >/dev/null 2>&1"
out=$("$AB" -i b up http://localhost:5173/ 2>&1); rc=$?
check "-i b up → b's Chromium on its own DevTools port and profile, endpoint :19224" "[ $rc -eq 0 ] && grep -q '^host: running' <<<'$out' && grep -q 'host.docker.internal:19224' <<<'$out' && arg_has --remote-debugging-port=19324 && arg_has --user-data-dir=$TMP/home/profile-b"
check "b's activity is touched in b's channel" "[ -f '$CTL/b/activity' ]"
check "b's proxy listens on 19224" "wait_for 4 bash -c 'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:19224/json/protocol | grep -q 403'"
"$AB" -i b status >"$TMP/status-b.out" 2>&1
check "-i b status : instance b, its port in the firewall line, a among the others" "grep -q '^instance  : b' '$TMP/status-b.out' && grep -q 'host:19224' '$TMP/status-b.out' && grep -q '^others    : a' '$TMP/status-b.out'"
"$AB" -i b down >/dev/null 2>&1
stop_host
REPO_B=$TMP/repo; mkdir -p "$REPO_B/.devcontainer/firewall"; : >"$REPO_B/.devcontainer/docker-compose.yml"
printf 'host:9222\nhost:9223\nhost:9224  # second agent browser\n' >"$REPO_B/.devcontainer/firewall/ports.txt"
(cd "$REPO_B" && env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT DC_PROJECT=demo bash "$SKILL/host/host-agent.sh" instances) >"$TMP/instances.out" 2>&1
check "host-agent.sh instances : a and b from the firewall's ports, labels, ports, channels" "grep -q '^  a  io.meitogi.agent-browser.demo  proxy 127.0.0.1:9223  devtools 127.0.0.1:9323  channel .devcontainer/tmp/agent-browser/host$' '$TMP/instances.out' && grep -q '^  b  io.meitogi.agent-browser.demo.b  proxy 127.0.0.1:9224  devtools 127.0.0.1:9324  channel .devcontainer/tmp/agent-browser/b/host$' '$TMP/instances.out' && [ \$(grep -c '^  [a-z] ' '$TMP/instances.out') -eq 2 ]"
rm "$REPO_B/.devcontainer/firewall/ports.txt"
(cd "$REPO_B" && env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT DC_PROJECT=demo bash "$SKILL/host/host-agent.sh" instances) >"$TMP/instances.out" 2>&1
check "no ports.txt → instance a alone" "[ \$(grep -c '^  [a-z] ' '$TMP/instances.out') -eq 1 ] && grep -q '^  a ' '$TMP/instances.out'"
check "host-agent.sh still refuses its other verbs in a container" "out=\$(cd '$REPO_B' && bash '$SKILL/host/host-agent.sh' status b 2>&1); [ \$? -eq 2 ] && grep -q 'runs on the host' <<<\"\$out\""

echo "== sidecar supervisor (fake Chromium) =="
env AGENT_BROWSER_CTL="$CTL" HOME="$TMP/home" AGENT_BROWSER_CHROMIUM="$TMP/bin/chromium" AGENT_BROWSER_CDP_PORT=19323 \
	sh "$SKILL/sidecar/supervisor.sh" >"$TMP/sidecar.out" 2>&1 &
SIDE_PID=$!; PIDS+=("$SIDE_PID")
check "heartbeat appears at the channel root, state idle" "wait_for 4 test -f '$CTL/heartbeat' && [ \"\$(state_of '$CTL')\" = 'idle - -' ]"
check "env routes to the sidecar on the loopback" "[ \"\$('$AB' env)\" = 'export CDP_HOST=127.0.0.1 CDP_PORT=19323' ]"
"$AB" up http://localhost:5173/ >"$TMP/up.out" 2>&1
check "up → sidecar running" "grep -q '^sidecar: running [0-9]* http://localhost:5173/$' '$TMP/up.out'"
check "sidecar Chromium: no sandbox, Mesa, DevTools port, URL after --, WebRTC without mDNS" "arg_has --no-sandbox && arg_has --use-angle=gl-egl && arg_has --remote-debugging-port=19323 && arg_has -- && arg_has http://localhost:5173/ && arg_has --mute-audio && arg_has --disable-features=WebRtcHideLocalIpsWithMdns"
check "stats answers four fields" "'$AB' stats >/dev/null && [ \"\$(wc -w <'$CTL/stats')\" -eq 4 ]"
"$AB" down >"$TMP/down.out" 2>&1
check "down → stopped" "grep -q '^sidecar: stopped' '$TMP/down.out'"
kill "$SIDE_PID"; wait "$SIDE_PID" 2>/dev/null
check "TERM → heartbeat removed, state stopped" "wait_for 4 bash -c '[ ! -e $CTL/heartbeat ]' && [ \"\$(cut -d' ' -f2 '$CTL/state')\" = stopped ]"

echo "== cdp-proxy.mjs (node --test) =="
node --test "$SKILL/host/cdp-proxy.test.mjs" >"$TMP/node.out" 2>&1
check "the proxy's unit tests pass" "grep -q '^ℹ fail 0' '$TMP/node.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/node.out') -ge 9 ]"
check "the live part skips without a browser, naming the variable" "grep -q 'AGENT_BROWSER_TEST_CDP' '$TMP/node.out'"
check "check-url exits 0 / 1 / 2" "node '$SKILL/host/cdp-proxy.mjs' check-url http://localhost:5173/x && ! node '$SKILL/host/cdp-proxy.mjs' check-url http://localhost:5174/ 2>/dev/null; env -u AGENT_BROWSER_ORIGINS node '$SKILL/host/cdp-proxy.mjs' check-url http://x/ 2>/dev/null; [ \$? -eq 2 ]"

echo "== visual-loop player harness (node --test) =="
node --test "$REPO/assets/opt/skills/visual-loop/lib/player.test.mjs" >"$TMP/player.out" 2>&1
check "the player harness's unit tests pass (keys, pad buttons, index.md, in-page pads and fps)" "grep -q '^ℹ fail 0' '$TMP/player.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/player.out') -ge 6 ]" \
	|| tail -30 "$TMP/player.out" >&2

echo
echo "agent-browser: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
