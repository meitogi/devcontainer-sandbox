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

# The container's own configuration must not leak into the fixtures.
unset AGENT_BROWSER_REACH AGENT_BROWSER_ICON_LETTERS AGENT_BROWSER_CHROMIUM AGENT_BROWSER_INSTANCE DC_PROJECT

TMP=$(mktemp -d)
CTL=$TMP/ctl; mkdir -p "$CTL/host" "$TMP/home" "$TMP/bin"
ARGS=$TMP/chromium.args
# A Chromium that records its arguments and stays up until killed.
cat >"$TMP/bin/chromium" <<EOS
#!/bin/sh
[ "\$1" = --version ] && { echo 'Chromium 150.0.7000.1'; exit 0; }
printf '%s\n' "\$@" >"$ARGS"
exec sleep 300
EOS
# One that dies at once, for the give-up path.
cat >"$TMP/bin/dying" <<EOS
#!/bin/sh
[ "\$1" = --version ] && { echo 'Chromium 150.0.7000.1'; exit 0; }
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
		node "$SKILL/host/host-supervisor.mjs" >"$TMP/host-supervisor.out" 2>&1 &
	HOST_PID=$!; PIDS+=("$HOST_PID")
}
stop_host() { kill "$HOST_PID" 2>/dev/null; wait "$HOST_PID" 2>/dev/null; }

echo "== no browser answers =="
out=$("$AB" env 2>&1); rc=$?
check "env exits 3 with the two human instructions when nothing answers" "[ $rc -eq 3 ] && grep -q 'HUMAN ACTION' <<<'$out' && grep -q 'host-kit' <<<'$out' && grep -q 'profile agent-browser up' <<<'$out'"
printf 'wsl\n' >"$TMP/host-os"
out=$(AGENT_BROWSER_HOST_OS_FILE="$TMP/host-os" "$AB" env 2>&1); rc=$?
check "a Windows host : exit 3 names the PowerShell recipe (cmd /c for the tar, host-agent.ps1)" "[ $rc -eq 3 ] && grep -qF 'cmd /c' <<<\"\$out\" && grep -qF 'host-agent.ps1\" install' <<<\"\$out\" && grep -qF 'host-agent.ps1\" start' <<<\"\$out\""
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
check "the supervisor announces its proxy port in the channel" "[ \"\$(cat '$CTL/host/port')\" = 19223 ]"
check "route : side, state, endpoint on one line" "[ \"\$('$AB' route)\" = 'host idle host.docker.internal 19223' ]"
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
[ "\$1" = --version ] && { echo 'Chromium 150.0.7000.1'; exit 0; }
printf '%s\n' "\$@" >"$ARGS"
exec sleep 300
EOS
start_host AGENT_BROWSER_AUDIO=on AGENT_BROWSER_WINDOW=1 AGENT_BROWSER_SIZE=1920,1080
wait_for 4 test -f "$CTL/host/heartbeat"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
check "AUDIO=on, WINDOW=1, SIZE: no mute, no headless, the size" "! arg_has --mute-audio && ! arg_has --headless=new && arg_has --window-size=1920,1080"
"$AB" down >/dev/null 2>&1
stop_host

echo "== handoff (a Chromium that answers DevTools) =="
FAKE=$TMP/fake; mkdir -p "$FAKE" "$TMP/locks"
printf '#!/bin/sh\nexec node %s "$@"\n' "$REPO/test/lib/fake-cdp-chromium.mjs" >"$TMP/bin/cdp-chromium"; chmod +x "$TMP/bin/cdp-chromium"
export FAKE_ARGS="$ARGS" FAKE_LOG="$TMP/cdp.log" FAKE_CTL="$FAKE" CDP_LOCK_DIR="$TMP/locks"
: >"$FAKE_LOG"
start_host AGENT_BROWSER_CHROMIUM="$TMP/bin/cdp-chromium" AGENT_BROWSER_IDLE_S=4
wait_for 4 test -f "$CTL/host/heartbeat"
"$AB" up http://localhost:5173/ >/dev/null 2>&1
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/159.0.0.0 Safari/537.36'
check "headless announces the window's user-agent, built from the binary's version, never HeadlessChrome" "arg_has --headless=new && arg_has '--user-agent=$UA' && ! grep -q Headless '$ARGS'"
check "the window's brands on every target : the override set over DevTools, the page loaded before it reloaded" "wait_for 4 grep -q '^Emulation.setUserAgentOverride A[0-9]* .*\"brand\":\"Chromium\",\"version\":\"159\"' '$FAKE_LOG' && ! grep '^Emulation.setUserAgentOverride' '$FAKE_LOG' | grep -q Headless && grep -q '^Target.setAutoAttach - {\"autoAttach\":true,\"waitForDebuggerOnStart\":true,\"flatten\":true}' '$FAKE_LOG' && wait_for 2 grep -q '^Page.reload A' '$FAKE_LOG'"
export AGENT_BROWSER_HOST=127.0.0.1
printf 'http://localhost:5173/editor\n' >"$FAKE/url"
"$AB" handoff --say 'Sign in to Canva' >"$TMP/handoff.out" 2>&1 &
HANDOFF=$!; PIDS+=("$HANDOFF")
check "handoff : a real window, on the page shown (not the one of up), the request printed" "wait_for 8 test -f '$CTL/host/window' && ! arg_has --headless=new && arg_has http://localhost:5173/editor && wait_for 4 grep -q \"the window is the user's — Sign in to Canva\" '$TMP/handoff.out'"
check "handoff : the request in a banner injected over the proxy, kept across navigation, a Done binding" "wait_for 6 grep -q '^Page.addScriptToEvaluateOnNewDocument S[0-9]* .*Sign in to Canva' '$FAKE_LOG' && grep -q '^Runtime.addBinding S[0-9]* {\"name\":\"__agentBrowserDone\"}' '$FAKE_LOG'"
check "handoff : the state word stays running (icons, visual-loop), status names the handoff" "[ \"\$(cut -d' ' -f2 '$CTL/host/state')\" = running ] && '$AB' status 2>/dev/null | grep -q '^window    : the user has the browser'"
check "handoff : the visual-loop lock is the user's — a script gets exit 10, naming the handoff" "out=\$(PATH='$REPO/bin':\$PATH node '$REPO/assets/opt/skills/visual-loop/scripts/cdp.mjs' reset 2>&1); [ \$? -eq 10 ] && grep -q 'agent-browser handoff' <<<\"\$out\""
sleep 5
check "handoff : the idle watchdog leaves a window alone (IDLE_S=4, 5 s without activity)" "[ -f '$CTL/host/window' ] && kill -0 \$(cut -d' ' -f3 '$CTL/host/state')"
touch "$FAKE/click-done"
check "« Done » in the banner : handed back, headless again on the same page, the lock released" "wait_for 8 bash -c '! kill -0 $HANDOFF' && wait $HANDOFF && grep -q '^handed back: host running' '$TMP/handoff.out' && [ ! -e '$CTL/host/window' ] && arg_has --headless=new && arg_has http://localhost:5173/editor && [ -z \"\$(ls -A '$TMP/locks')\" ]"
check "every stop asks Chromium to close (cookies flushed), Browser.close sent before any kill" "grep -q '^Browser.close - {}' '$FAKE_LOG'"
"$AB" handoff >"$TMP/handoff.out" 2>&1 &
HANDOFF=$!; PIDS+=("$HANDOFF")
wait_for 8 test -f "$CTL/host/window"; sleep 1
touch "$FAKE/no-pages"
check "the user closes the window (no page left) : the supervisor ends the handoff by itself, headless again" "wait_for 8 bash -c '! kill -0 $HANDOFF' && wait $HANDOFF && [ ! -e '$CTL/host/window' ] && arg_has --headless=new && grep -q 'window: no page left' '$TMP/host-supervisor.out'"
rm -f "$FAKE/no-pages"
"$AB" handoff >"$TMP/handoff.out" 2>&1 &
HANDOFF=$!; PIDS+=("$HANDOFF")
wait_for 8 test -f "$CTL/host/window"; sleep 1
kill -TERM "$HANDOFF"
check "SIGTERM on handoff hands the browser back" "wait_for 8 bash -c '! kill -0 $HANDOFF' && wait_for 6 bash -c '[ ! -e $CTL/host/window ]' && arg_has --headless=new"
check "handback with no handoff in progress says so and answers" "out=\$('$AB' handback 2>&1); [ \$? -eq 0 ] && grep -q 'no handoff in progress' <<<\"\$out\" && grep -q '^host: running' <<<\"\$out\""
printf '{"pid":1,"host":"other","owner":"e2e suite","at":"%s","expires":%s}\n' "$(date -u +%FT%TZ)" "$(( ($(date +%s) + 600) * 1000 ))" >"$TMP/locks/.cdp-lock-127.0.0.1-19223.json"
check "handoff while a script holds the browser : exit 10, no window opened" "out=\$('$AB' handoff 2>&1); [ \$? -eq 10 ] && grep -q 'e2e suite' <<<\"\$out\" && [ ! -e '$CTL/host/window' ] && arg_has --headless=new"
rm -f "$TMP/locks/.cdp-lock-127.0.0.1-19223.json"
check "handoff refuses a URL outside the origins before anything" "! '$AB' handoff https://evil.test/ >/dev/null 2>&1 && [ ! -e '$CTL/host/window' ]"
"$AB" down >/dev/null 2>&1
stop_host
date +%s >"$CTL/heartbeat"
check "handoff on the sidecar : refused, no window there" "out=\$('$AB' handoff 2>&1); [ \$? -eq 2 ] && grep -q 'no window there' <<<\"\$out\""
rm -f "$CTL/heartbeat"
unset AGENT_BROWSER_HOST FAKE_ARGS FAKE_LOG FAKE_CTL CDP_LOCK_DIR

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
check "TERM : the announced port goes with the heartbeat" "wait_for 4 bash -c '[ ! -e $CTL/b/host/port ]'"
mkdir -p "$CTL/c/host"; date +%s >"$CTL/c/host/heartbeat"; echo 19777 >"$CTL/c/host/port"
check "a port announced in the channel (install --port) wins over the derived one" "[ \"\$('$AB' -i c env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19777' ]"
echo '19777; rm -rf /' >"$CTL/c/host/port"
check "an announced port that is not digits is ignored (derived port)" "[ \"\$('$AB' -i c env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19225' ]"
rm -f "$CTL/c/host/port"; ln -s /etc/hostname "$CTL/c/host/port"
check "a symlinked port file is never read" "[ \"\$('$AB' -i c env)\" = 'export CDP_HOST=host.docker.internal CDP_PORT=19225' ]"
rm -rf "$CTL/c"
REPO_B=$TMP/repo; mkdir -p "$REPO_B/.devcontainer/firewall"; : >"$REPO_B/.devcontainer/docker-compose.yml"
printf 'host:9222\nhost:9223\nhost:9224  # second agent browser\n' >"$REPO_B/.devcontainer/firewall/ports.txt"
(cd "$REPO_B" && env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT DC_PROJECT=demo bash "$SKILL/host/host-agent.sh" instances) >"$TMP/instances.out" 2>&1
check "host-agent.sh instances : a and b from the firewall's ports, labels, ports, channels" "grep -q '^  a  io.meitogi.agent-browser.demo  proxy 127.0.0.1:9223  devtools 127.0.0.1:9323  channel .devcontainer/tmp/agent-browser/host$' '$TMP/instances.out' && grep -q '^  b  io.meitogi.agent-browser.demo.b  proxy 127.0.0.1:9224  devtools 127.0.0.1:9324  channel .devcontainer/tmp/agent-browser/b/host$' '$TMP/instances.out' && [ \$(grep -c '^  [a-z] ' '$TMP/instances.out') -eq 2 ]"
rm "$REPO_B/.devcontainer/firewall/ports.txt"
(cd "$REPO_B" && env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT DC_PROJECT=demo bash "$SKILL/host/host-agent.sh" instances) >"$TMP/instances.out" 2>&1
check "no ports.txt → instance a alone" "[ \$(grep -c '^  [a-z] ' '$TMP/instances.out') -eq 1 ] && grep -q '^  a ' '$TMP/instances.out'"
check "host-agent.sh still refuses its other verbs in a container" "out=\$(cd '$REPO_B' && bash '$SKILL/host/host-agent.sh' status b 2>&1); [ \$? -eq 2 ] && grep -q 'runs on the host' <<<\"\$out\""

echo "== host-agent.sh lifecycle (macOS stubbed: launchctl, plutil, defaults, uname) =="
MAC=$TMP/mac; MACBIN=$TMP/macbin; CHROMEBIN=$TMP/chromebin; LD=$TMP/launchd
mkdir -p "$MAC/Library/LaunchAgents" "$MACBIN" "$CHROMEBIN" "$LD" "$TMP/swiftbar"
cat >"$MACBIN/uname" <<'EOS'
#!/bin/sh
case $1 in -s) echo Darwin ;; -m) echo "${FAKE_ARCH:-arm64}" ;; *) exec /bin/uname "$@" ;; esac
EOS
# launchctl : a loaded / disabled marker per label ; bootstrap writes the
# heartbeat the supervisor would, into the CTL the plist names.
cat >"$MACBIN/launchctl" <<EOS
#!/bin/bash
echo "\$*" >>"$TMP/launchctl.log"
case \$1 in
	bootstrap)
		label=\$(basename "\$3" .plist)
		[ -e "$LD/\$label.disabled" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
		touch "$LD/\$label.loaded"
		ctl=\$(sed -n 's|.*<key>AGENT_BROWSER_CTL</key><string>\(.*\)</string>.*|\1|p' "\$3")
		mkdir -p "\$ctl"; date +%s >"\$ctl/heartbeat" ;;
	bootout) rm -f "$LD/\${2##*/}.loaded" ;;
	enable) rm -f "$LD/\${2##*/}.disabled" ;;
	disable) touch "$LD/\${2##*/}.disabled" ;;
	print) [ -e "$LD/\${2##*/}.loaded" ] || exit 113; printf '\tstate = running\n\tpid = 4242\n' ;;
	list)
		printf 'PID\tStatus\tLabel\n777\t0\tio.meitogi.agent-browser.other\n'
		for f in "$LD"/*.loaded; do [ -e "\$f" ] && printf '4242\t0\t%s\n' "\$(basename "\$f" .loaded)"; done ;;
esac
exit 0
EOS
printf '#!/bin/sh\nexit 0\n' >"$MACBIN/plutil"
printf '#!/bin/sh\n[ -n "${FAKE_SWIFTBAR:-}" ] && echo "$FAKE_SWIFTBAR" && exit 0\nexit 1\n' >"$MACBIN/defaults"
# A Chromium that answers CDP on --remote-debugging-pipe (fd 3 in, fd 4 out),
# its capture a 44×36 RGBA PNG carrying the hash of the page it was sent to :
# two icons differ exactly when their SVGs do.
cat >"$CHROMEBIN/chromium" <<'EOS'
#!/usr/bin/env node
const fs = require('fs'), zlib = require('zlib'), crypto = require('crypto');
const chunk = (type, data) => { const b = Buffer.alloc(12 + data.length); b.writeUInt32BE(data.length, 0); b.write(type, 4, 'latin1'); data.copy(b, 8); b.writeUInt32BE(zlib.crc32(b.subarray(4, 8 + data.length)), 8 + data.length); return b; };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(44, 0); ihdr.writeUInt32BE(36, 4); ihdr[8] = 8; ihdr[9] = 6;
const png = (hash) => Buffer.concat([Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), chunk('IHDR', ihdr), chunk('tEXt', Buffer.from('svg\0' + hash)), chunk('IDAT', zlib.deflateSync(Buffer.alloc(36 * 177))), chunk('IEND', Buffer.alloc(0))]);
const out = fs.createWriteStream(null, { fd: 4 }), say = (m) => out.write(JSON.stringify(m) + '\0');
let page = '', buf = '';
fs.createReadStream(null, { fd: 3, encoding: 'utf8' }).on('data', (d) => {
	buf += d;
	for (let at; (at = buf.indexOf('\0')) >= 0; buf = buf.slice(at + 1)) {
		const { id, method, params, sessionId } = JSON.parse(buf.slice(0, at));
		const result = { 'Browser.getVersion': { product: 'HeadlessChrome/150.0.0.0' }, 'Target.createTarget': { targetId: 't' }, 'Target.attachToTarget': { sessionId: 's' } }[method] ?? {};
		if (method === 'Page.navigate') page = params.url;
		if (method === 'Page.captureScreenshot') result.data = png(crypto.createHash('sha1').update(fs.readFileSync(new URL(page))).digest('hex')).toString('base64');
		say({ id, result });
		if (method === 'Page.navigate') say({ method: 'Page.loadEventFired', params: {}, sessionId });
		if (method === 'Browser.close') out.end(() => process.exit(0));
	}
});
EOS
chmod +x "$MACBIN"/* "$CHROMEBIN/chromium"
PROJ=$TMP/proj; mkdir -p "$PROJ/.devcontainer/firewall"; : >"$PROJ/.devcontainer/docker-compose.yml"
printf 'host:19500\nhost:19501  # b\n' >"$PROJ/.devcontainer/firewall/ports.txt"
printf 'DC_PROJECT=demo\nAGENT_BROWSER_PROXY_PORT=19500\nAGENT_BROWSER_CDP_PORT=19600\nAGENT_BROWSER_B_NOTE="sync suite only | stop b after"\n' >"$PROJ/.devcontainer/.env"
printf '<dict>\n\t\t<key>AGENT_BROWSER_PROXY_PORT</key><string>19501</string>\n</dict>\n' >"$MAC/Library/LaunchAgents/io.meitogi.agent-browser.other.plist"
ha() {   # ha <verb…> → host-agent.sh on the fake Mac, from the fixture project
	(cd "$PROJ" && env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT HOME="$MAC" PATH="$MACBIN:${HA_PATH:-$CHROMEBIN}:$PATH" \
		AGENT_BROWSER_HOST_TEST=1 FAKE_SWIFTBAR="$TMP/swiftbar" bash "$SKILL/host/host-agent.sh" "$@")
}
PL=$MAC/Library/LaunchAgents/io.meitogi.agent-browser.demo
PLUG=$TMP/swiftbar/agent-browser-demo
plist_val() { sed -n "s|.*<key>$2</key><string>\(.*\)</string>.*|\1|p" "$1.plist"; }

ha install >"$TMP/ha.out" 2>&1; rc=$?
check "install without a list : a only, though the firewall opens b too" "[ $rc -eq 0 ] && [ -f '$PL.plist' ] && [ ! -e '$PL.b.plist' ] && [ -f '$PLUG.5s.sh' ] && [ ! -e '$PLUG.b.5s.sh' ]"
check "install : five numbered steps, all ok" "[ \$(grep -cE '^\[[1-5]/5 (kit|chromium|firewall|launchd|heartbeat)\] ok — ' '$TMP/ha.out') -eq 5 ]" || cat "$TMP/ha.out" >&2
check "the plist runs the node supervisor of the installed copy" "grep -A3 '<key>ProgramArguments</key>' '$PL.plist' | grep -q '<string>$(command -v node)</string>' && grep -A3 '<key>ProgramArguments</key>' '$PL.plist' | grep -q 'agent-browser/demo/agent/host-supervisor.mjs</string>'"
check "the plist carries the Chromium install found on PATH (.env empty)" "[ \"\$(plist_val '$PL' AGENT_BROWSER_CHROMIUM)\" = '$CHROMEBIN/chromium' ]"
check "a's plugin : the icon drawn, an empty note" "grep -q '^ICON_RUNNING=iVBOR' '$PLUG.5s.sh' && grep -qx 'NOTE_B64=' '$PLUG.5s.sh'"
ha install --all >"$TMP/ha.out" 2>&1
check "install --all : every instance the firewall opens (a and b)" "[ -f '$PL.b.plist' ] && [ -f '$PLUG.b.5s.sh' ] && [ \$(grep -c '^== instance' '$TMP/ha.out') -eq 2 ]"
check "b's icon differs from a's (its letter in the dot), same tag letters" "[ \"\$(grep ^ICON_IDLE= '$PLUG.5s.sh')\" != \"\$(grep ^ICON_IDLE= '$PLUG.b.5s.sh')\" ] && grep -q 'icon DE, b in the dot' '$TMP/ha.out'"
check "b's note from .env, its « | » dropped, base64 in the plugin" "[ \"\$(sed -n 's/^NOTE_B64=//p' '$PLUG.b.5s.sh' | base64 -d)\" = 'sync suite only  stop b after' ]"
out=$(AGENT_BROWSER_B_ICON_LETTERS=ABCD ha install b 2>&1)
check "AGENT_BROWSER_B_ICON_LETTERS validated like _ICON_LETTERS : refused, SF Symbols instead" "grep -q \"icon letters 'ABCD': 1 to 3 letters\" <<<\"\$out\" && grep -q 'icon not drawn' <<<\"\$out\""
ha install b >/dev/null 2>&1
OWN=$PROJ/.devcontainer/agent-browser/menubar-icon; mkdir -p "$OWN"
node --input-type=module -e "import { encodePng } from '$SKILL/host/menubar-icon.mjs'; import fs from 'node:fs';
for (const s of ['running', 'idle', 'unloaded', 'stray']) fs.writeFileSync('$OWN/' + s + '.png', encodePng(44, 36, Buffer.alloc(44 * 36 * 4, 7)));"
drawn() { sed -n 's/^ICON_IDLE=//p' "$1" | base64 -d | grep -qa 'tEXtsvg'; }   # the fake Chromium's PNG, not the project's
ha install >"$TMP/ha.out" 2>&1
check "the project's ready-made PNGs : used as they are, said so, b still drawn" "grep -q '^  menu bar: icon from .devcontainer/agent-browser/menubar-icon/, ready-made$' '$TMP/ha.out' && ! drawn '$PLUG.5s.sh' && drawn '$PLUG.b.5s.sh'" || cat "$TMP/ha.out" >&2
rm -rf "$OWN"
ha install c >"$TMP/ha.out" 2>&1
check "a port the firewall does not open : firewall warns, the rest ok" "grep -q '^\[3/5 firewall\] warn — host:19502 is not in .devcontainer/firewall/ports.txt — add it, then Rebuild Container' '$TMP/ha.out' && [ \$(grep -c '^\[[1-5]/5 [a-z]*\] ok' '$TMP/ha.out') -eq 4 ]"
ha uninstall c >/dev/null 2>&1
ha install c --port 19555 --cdp-port 19655 >"$TMP/ha.out" 2>&1; rc=$?
check "install c --port : its plist on those ports, the firewall step checks that port" "[ $rc -eq 0 ] && [ \"\$(plist_val '$PL.c' AGENT_BROWSER_PROXY_PORT)\" = 19555 ] && [ \"\$(plist_val '$PL.c' AGENT_BROWSER_CDP_PORT)\" = 19655 ] && grep -q 'host:19555 is not in' '$TMP/ha.out'"
ha list >"$TMP/list.out" 2>&1
ha status c >"$TMP/ha.out" 2>&1
check "list and status read the installed port, not the derived one" "grep -q '^  c  .* proxy 19555 ' '$TMP/list.out' && grep -q '(127.0.0.1:19555)' '$TMP/ha.out'"
ha install c >"$TMP/ha.out" 2>&1
check "install again without --port : back to the .env's port, and it says how to keep the old one" "[ \"\$(plist_val '$PL.c' AGENT_BROWSER_PROXY_PORT)\" = 19502 ] && grep -q 'proxy port 19502, was 19555 — install c --port 19555 keeps the old one' '$TMP/ha.out'"
out=$(ha install a b --port 19555 2>&1); rc=$?
check "--port with two instances, --all, a bad port, or start is refused" "[ $rc -eq 2 ] && grep -q 'ONE instance' <<<\"\$out\" && ! ha install --all --port 19555 >/dev/null 2>&1 && ! ha install c --port 80 >/dev/null 2>&1 && ! ha install c --port 99999 >/dev/null 2>&1 && ! ha start c --port 19555 >/dev/null 2>&1"
ha install c --visible >"$TMP/ha.out" 2>&1; v1=$(plist_val "$PL.c" AGENT_BROWSER_WINDOW)
ha install c >/dev/null 2>&1; v0=$(plist_val "$PL.c" AGENT_BROWSER_WINDOW)
check "install --visible : a window on every start without an .env edit, said so ; install again → headless ; start refuses it" "[ '$v1' = 1 ] && grep -q ', windowed ' '$TMP/ha.out' && [ '$v0' = 0 ] && ! ha start c --visible >/dev/null 2>&1"
ha uninstall c >/dev/null 2>&1
out=$(HA_PATH=/nonexistent ha install 2>&1); rc=$?
check "no Chromium : [2/5 chromium] FAILED, every place looked in, install-chromium last" "[ $rc -eq 2 ] && grep -q '\[2/5 chromium\] FAILED — Chromium not found' <<<\"\$out\" && grep -q 'AGENT_BROWSER_CHROMIUM (.devcontainer/.env): unset' <<<\"\$out\" && grep -q '/Applications/Chromium.app/Contents/MacOS/Chromium' <<<\"\$out\" && grep -q 'Google Chrome.app' <<<\"\$out\" && grep -q 'ms-playwright' <<<\"\$out\" && grep -q 'PATH: chromium chromium-browser google-chrome google-chrome-stable' <<<\"\$out\" && grep -q 'install-chromium' <<<\"\$(tail -n 1 <<<\"\$out\")\""
mkdir -p "$TMP/own"; cp "$CHROMEBIN/chromium" "$TMP/own/MyChromium"
AGENT_BROWSER_CHROMIUM=$TMP/own/MyChromium ha install >/dev/null 2>&1
check "an explicit AGENT_BROWSER_CHROMIUM still wins" "[ \"\$(plist_val '$PL' AGENT_BROWSER_CHROMIUM)\" = '$TMP/own/MyChromium' ]"
ha install >/dev/null 2>&1
: >"$TMP/launchctl.log"
ha stop b >"$TMP/ha.out" 2>&1
check "stop b : unloaded and disabled, the plist and the plugin kept" "grep -q 'bootout gui/[0-9]*/io.meitogi.agent-browser.demo.b$' '$TMP/launchctl.log' && grep -q 'disable gui/[0-9]*/io.meitogi.agent-browser.demo.b$' '$TMP/launchctl.log' && [ -f '$PL.b.plist' ] && [ -f '$PLUG.b.5s.sh' ] && [ ! -e '$LD/io.meitogi.agent-browser.demo.b.loaded' ] && [ -e '$LD/io.meitogi.agent-browser.demo.loaded' ]"
touch -d '2000-01-01' "$PL.b.plist"; : >"$TMP/launchctl.log"
ha start b >"$TMP/ha.out" 2>&1; rc=$?
check "start b after stop : enabled and bootstrapped, the plist not rewritten, five steps" "[ $rc -eq 0 ] && grep -q 'enable gui/[0-9]*/io.meitogi.agent-browser.demo.b$' '$TMP/launchctl.log' && grep -q 'bootstrap gui/[0-9]* .*demo.b.plist$' '$TMP/launchctl.log' && [ \"\$(date -r '$PL.b.plist' +%Y)\" = 2000 ] && [ \$(grep -c '^\[[1-5]/5 [a-z]*\] ok' '$TMP/ha.out') -eq 5 ]" || cat "$TMP/ha.out" >&2
out=$(ha stop z 2>&1); rc=$?
check "stop refuses an instance that is not installed" "[ $rc -eq 2 ] && grep -q 'instance z is not installed' <<<\"\$out\""
out=$(ha start 1 2>&1); rc=$?
check "start refuses what is not a letter" "[ $rc -eq 2 ] && grep -q 'one letter' <<<\"\$out\""
ha stop b >/dev/null 2>&1
ha list >"$TMP/list.out" 2>&1
check "list : a line per instance — loaded, pids, proxy port, heartbeat, logs ; b stopped, its note" "grep -q '^  a  io.meitogi.agent-browser.demo  installed, loaded  supervisor 4242  chromium .* proxy 19500 closed  heartbeat [0-9]*s  logs $MAC/Library/Logs/agent-browser/demo$' '$TMP/list.out' && grep -q '^  b  io.meitogi.agent-browser.demo.b  installed, stopped  supervisor -  chromium stopped' '$TMP/list.out' && grep -q '^     sync suite only  stop b after$' '$TMP/list.out'" || cat "$TMP/list.out" >&2
check "list : another project's job, its proxy port, the clash with b" "grep -q '^  io.meitogi.agent-browser.other  proxy 19501  ← the same port as instance b here$' '$TMP/list.out' && ! grep -q '^  io.meitogi.agent-browser.demo' '$TMP/list.out'"
ha list --json >"$TMP/list.json" 2>&1
check "list --json : the same fields as list, one object per instance, the other projects with their clash" "node -e '
const j = JSON.parse(require(\"fs\").readFileSync(process.argv[1], \"utf8\"));
const [a, b] = j.instances, o = j.others[0];
const ok = j.project === \"demo\" && a.instance === \"a\" && a.label === \"io.meitogi.agent-browser.demo\" && a.installed && a.loaded && a.supervisor === 4242
	&& a.proxy.port === 19500 && a.proxy.listening === false && typeof a.heartbeat === \"number\" && a.logs.endsWith(\"/Library/Logs/agent-browser/demo\")
	&& b.instance === \"b\" && b.installed && !b.loaded && b.supervisor === null && b.chromium.state === \"stopped\" && b.note === \"sync suite only  stop b after\"
	&& o.job === \"io.meitogi.agent-browser.other\" && o.port === 19501 && o.clash === \"b\";
process.exit(ok ? 0 : 1)' '$TMP/list.json'" || cat "$TMP/list.json" >&2
ha status a >"$TMP/ha.out" 2>&1
check "status : the plist's Chromium and whether the proxy listens" "grep -q '^  chromium: $CHROMEBIN/chromium$' '$TMP/ha.out' && grep -q '^  proxy listening: no (127.0.0.1:19500)$' '$TMP/ha.out'"
(cd "$PROJ" && env -u AGENT_BROWSER_PROXY_PORT HOME="$MAC" bash "$SKILL/host/host-agent.sh" instances) >"$TMP/ha.out" 2>&1
check "instances marks what is installed" "[ \$(grep -c '  installed$' '$TMP/ha.out') -eq 2 ]"
ha uninstall b >/dev/null 2>&1
check "uninstall b : plist and plugin gone, a untouched" "[ ! -e '$PL.b.plist' ] && [ ! -e '$PLUG.b.5s.sh' ] && [ -f '$PL.plist' ]"
(cd "$PROJ" && exec env -u AGENT_BROWSER_PROXY_PORT -u AGENT_BROWSER_CDP_PORT HOME="$MAC" PATH="$MACBIN:$CHROMEBIN:$PATH" \
	AGENT_BROWSER_HOST_TEST=1 bash "$SKILL/host/host-agent.sh" run d --temp --port 19501) >"$TMP/run.out" 2>&1 &
RUN_PID=$!; PIDS+=("$RUN_PID")
DCTL=$PROJ/.devcontainer/tmp/agent-browser/d/host
check "run d --temp : the supervisor beats, announces the --port, no LaunchAgent" "wait_for 6 test -f '$DCTL/heartbeat' && [ \"\$(cat '$DCTL/port')\" = 19501 ] && [ ! -e '$PL.d.plist' ]"
check "run prints a block to paste to the agent : instance, origins, the commands, exit 3 after Ctrl-C" "grep -q '^──── paste this to the agent' '$TMP/run.out' && grep -q 'instance d, temporary' '$TMP/run.out' && grep -q 'agent-browser -i d up <url>' '$TMP/run.out' && grep -q 'CDP_INSTANCE=d node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot' '$TMP/run.out' && grep -q 'exit 3' '$TMP/run.out'"
kill -TERM "$RUN_PID"; wait "$RUN_PID" 2>/dev/null
check "Ctrl-C (TERM) on run --temp : supervisor stopped, heartbeat gone, profile and logs removed" "[ ! -e '$DCTL/heartbeat' ] && [ ! -e '$MAC/Library/Application Support/agent-browser/demo.d' ] && [ ! -e '$MAC/Library/Logs/agent-browser/demo.d' ] && grep -q 'temporary instance d gone' '$TMP/run.out'" || cat "$TMP/run.out" >&2
out=$(ha run a --temp 2>&1); rc=$?
check "run --temp refuses an installed instance (it would delete its profile), and needs a letter" "[ $rc -eq 2 ] && grep -q 'instance a is installed' <<<\"\$out\" && ! ha run --temp >/dev/null 2>&1 && ! ha install c --temp >/dev/null 2>&1"
# install-chromium : curl answers LAST_CHANGE and "downloads" ; unzip lays out chrome-mac/.
cat >"$MACBIN/curl" <<EOS
#!/bin/sh
for a; do url=\$a; done
echo "\$url" >>"$TMP/curl.log"
case \$url in *LAST_CHANGE) echo 1234567 ;; *) while [ \$# -gt 0 ]; do [ "\$1" = -o ] && echo zip >"\$2"; shift; done ;; esac
EOS
cat >"$MACBIN/unzip" <<'EOS'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -d ] && d=$2; shift; done
mkdir -p "$d/chrome-mac/Chromium.app/Contents/MacOS" && printf '#!/bin/sh\n' >"$d/chrome-mac/Chromium.app/Contents/MacOS/Chromium" && chmod +x "$d/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
EOS
printf '#!/bin/sh\necho "$*" >>"%s/xattr.log"\n' "$TMP" >"$MACBIN/xattr"
chmod +x "$MACBIN/curl" "$MACBIN/unzip" "$MACBIN/xattr"
ha install-chromium >"$TMP/ha.out" 2>&1; rc=$?
APPDIR="$MAC/Library/Application Support/agent-browser/chromium"
check "install-chromium : the Mac_Arm snapshot, quarantine cleared, the .env line printed, no project file touched" "[ $rc -eq 0 ] && grep -qx 'https://commondatastorage.googleapis.com/chromium-browser-snapshots/Mac_Arm/LAST_CHANGE' '$TMP/curl.log' && grep -qx 'https://commondatastorage.googleapis.com/chromium-browser-snapshots/Mac_Arm/1234567/chrome-mac.zip' '$TMP/curl.log' && [ -x '$APPDIR/Chromium.app/Contents/MacOS/Chromium' ] && grep -q 'com.apple.quarantine' '$TMP/xattr.log' && grep -q '1234567' '$TMP/ha.out' && grep -qxF '  AGENT_BROWSER_CHROMIUM=\"$APPDIR/Chromium.app/Contents/MacOS/Chromium\"' '$TMP/ha.out' && ! grep -q CHROMIUM '$PROJ/.devcontainer/.env'" || cat "$TMP/ha.out" >&2
: >"$TMP/curl.log"; FAKE_ARCH=x86_64 ha install-chromium >/dev/null 2>&1
check "install-chromium on an Intel Mac : the Mac snapshot" "grep -q '/chromium-browser-snapshots/Mac/1234567/chrome-mac.zip$' '$TMP/curl.log'"

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

echo "== host-supervisor.mjs (node --test) =="
node --test "$SKILL/host/host-supervisor.test.mjs" >"$TMP/supervisor.out" 2>&1
check "the supervisor's unit tests pass (cmd, flags, Chromium search per OS, stats, orphans, env.json, idle)" "grep -q '^ℹ fail 0' '$TMP/supervisor.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/supervisor.out') -ge 10 ]" \
	|| tail -30 "$TMP/supervisor.out" >&2
check "one supervisor : the kit carries no shell copy of it" "grep -q host-supervisor.mjs '$TMP/host-kit.lst' && ! grep -qE 'host-supervisor\.sh|chromium-flags\.sh' '$TMP/host-kit.lst'"

echo "== menubar-icon.mjs (node --test) =="
node --test "$SKILL/host/menubar-icon.test.mjs" >"$TMP/icon.out" 2>&1
check "the menu-bar icon's unit tests pass (letters, state crop, 144 dpi pHYs, the Windows tray set)" "grep -q '^ℹ fail 0' '$TMP/icon.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/icon.out') -ge 10 ]" \
	|| tail -30 "$TMP/icon.out" >&2

echo "== visual-loop player harness (node --test) =="
node --test "$REPO/assets/opt/skills/visual-loop/lib/player.test.mjs" >"$TMP/player.out" 2>&1
check "the player harness's unit tests pass (keys, pad buttons, index.md, in-page pads and fps)" "grep -q '^ℹ fail 0' '$TMP/player.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/player.out') -ge 6 ]" \
	|| tail -30 "$TMP/player.out" >&2

echo "== visual-loop cdp.mjs on the agent browser (node --test) =="
node --test "$REPO/assets/opt/skills/visual-loop/lib/cdp.test.mjs" >"$TMP/cdp.out" 2>&1
check "cdp.mjs : agent browser by default, CDP_* win, lock per endpoint, exit 3 and its hint, up when off" "grep -q '^ℹ fail 0' '$TMP/cdp.out' && [ \$(sed -n 's/^ℹ pass //p' '$TMP/cdp.out') -ge 7 ]"

echo
echo "agent-browser: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
