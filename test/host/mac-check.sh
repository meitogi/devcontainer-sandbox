#!/usr/bin/env bash
# mac-check.sh — the agent browser's macOS path, end to end on the real Mac:
# launchd, the node supervisor, a real Chromium behind the proxy, and
# run --temp. The container is played by play-container.mjs, so Docker is not
# needed and nothing of the project's own agent browser is touched.
#
# HOW TO RUN IT — in the Mac's Terminal (not VS Code's), from the folder that
# holds .devcontainer/docker-compose.yml (the workspace root):
#
#   bash packages/devcontainer-sandbox/test/host/mac-check.sh
#
# What it does, in order (about one minute):
#   0. checks: macOS, node 22+, a Chromium, instances y and x not installed
#   1. serves a test page on http://localhost:19580/ (the only allowed origin)
#   2. install y --port 19590 --cdp-port 19690 — its five steps (the firewall
#      step warns: expected, the container is not involved)
#   3. drives y like the container would: up → running, the proxy answers,
#      the page is listed, down → stopped
#   4. list and list --json show y loaded
#   5. stop y: unloaded, no Chromium left on its profile ; start y: back, five steps
#   6. uninstall y: plist, copy and profile gone
#   7. run x --temp --port 19591 in the background, driven the same way, then
#      Ctrl-C (SIGINT to its process group): supervisor gone, profile removed
#
# It ends with a summary line, PASS or FAIL. The whole output also goes to
# .devcontainer/tmp/agent-browser-checks/mac-check.log, with your user name,
# machine name and home folder replaced — that file is what to hand back.
# Headless and muted throughout: no window, no sound.
#
#   --self-test   run the same script against a fake Mac (launchd, Chromium)
#                 in a scratch folder — how it is checked before it is handed over.
#
# Bash 3.2 (the Mac's).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../../assets/opt/skills/agent-browser/host" && pwd)"
PLAY="$HERE/play-container.mjs"
PAGE_PORT=19580
Y_PORT=19590 Y_CDP=19690 X_PORT=19591 X_CDP=19691
PASS=0 FAIL=0
STEP_T0=$(date +%s)

if [ "${1:-}" = --self-test ]; then
	SELF=$(mktemp -d)
	trap 'rm -rf "$SELF"' EXIT
	mkdir -p "$SELF/bin" "$SELF/home/Library/LaunchAgents" "$SELF/ld" "$SELF/proj/.devcontainer"
	: >"$SELF/proj/.devcontainer/docker-compose.yml"
	printf 'DC_PROJECT=selftest\nAGENT_BROWSER_ORIGINS=http://localhost:5173\n' >"$SELF/proj/.devcontainer/.env"
	cat >"$SELF/bin/uname" <<'EOS'
#!/bin/sh
case $1 in -s) echo Darwin ;; -m) echo arm64 ;; *) exec /bin/uname "$@" ;; esac
EOS
	printf '#!/bin/sh\nexit 0\n' >"$SELF/bin/plutil"
	printf '#!/bin/sh\nexit 1\n' >"$SELF/bin/defaults"
	# A launchd that really starts the plist's program with its environment.
	cat >"$SELF/bin/launchctl" <<EOS
#!/bin/bash
LD=$SELF/ld
val() { sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\\&/g'; }
case \$1 in
	bootstrap)
		label=\$(basename "\$3" .plist)
		[ -e "\$LD/\$label.disabled" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
		envs=()
		while IFS= read -r kv; do envs+=("\$kv"); done < <(sed -n 's|^[[:space:]]*<key>\(AGENT_BROWSER_[A-Z_]*\)</key><string>\(.*\)</string>|\1=\2|p' "\$3" | val)
		prog=(); while IFS= read -r a; do prog+=("\$a"); done < <(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s|.*<string>\(.*\)</string>.*|\1|p' "\$3" | val)
		log=\$(sed -n 's|.*<key>StandardOutPath</key><string>\(.*\)</string>.*|\1|p' "\$3" | val)
		mkdir -p "\$(dirname "\$log")"
		env "\${envs[@]}" "\${prog[@]}" >>"\$log" 2>&1 &
		echo \$! >"\$LD/\$label.pid" ;;
	bootout)
		label=\${2##*/}; p=\$(cat "\$LD/\$label.pid" 2>/dev/null) || exit 3
		kill -TERM "\$p" 2>/dev/null; while kill -0 "\$p" 2>/dev/null; do sleep 0.2; done
		rm -f "\$LD/\$label.pid" ;;
	enable) rm -f "\$LD/\${2##*/}.disabled" ;;
	disable) touch "\$LD/\${2##*/}.disabled" ;;
	print) p=\$(cat "\$LD/\${2##*/}.pid" 2>/dev/null) && kill -0 "\$p" 2>/dev/null || exit 113; printf '\tstate = running\n\tpid = %s\n' "\$p" ;;
	list) printf 'PID\tStatus\tLabel\n'; for f in "\$LD"/*.pid; do [ -e "\$f" ] && printf '%s\t0\t%s\n' "\$(cat "\$f")" "\$(basename "\$f" .pid)"; done ;;
esac
exit 0
EOS
	# A Chromium that serves the two DevTools paths the proxy reads, on its port.
	cat >"$SELF/bin/chromium" <<'EOS'
#!/usr/bin/env node
const a = process.argv.slice(2);
const port = Number(a.find(x => x.startsWith('--remote-debugging-port=')).split('=')[1]);
const url = a[a.length - 1];
require('http').createServer((q, r) => {
	if (q.url === '/json/version') return r.end(JSON.stringify({ Browser: 'FakeChromium/1', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/fake` }));
	if (q.url === '/json/list') return r.end(JSON.stringify([{ id: 'P1', type: 'page', title: 't', url }]));
	r.writeHead(404).end();
}).listen(port, '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
EOS
	chmod +x "$SELF/bin"/*
	export PATH="$SELF/bin:$PATH" HOME="$SELF/home" AGENT_BROWSER_HOST_TEST=1
	unset DC_PROJECT AGENT_BROWSER_CHROMIUM AGENT_BROWSER_CERT AGENT_BROWSER_ICON_LETTERS
	cd "$SELF/proj" || exit 2
	echo "self-test: a fake Mac in $SELF"
fi

PROJ="$(pwd)"
LOGDIR_CHECK="$PROJ/.devcontainer/tmp/agent-browser-checks"
LOG="$LOGDIR_CHECK/mac-check.log"
HA="$KIT/host-agent.sh"

[ -f "$PROJ/.devcontainer/docker-compose.yml" ] || { echo "✗ run this from the workspace root (the folder with .devcontainer/docker-compose.yml) — here: $PROJ"; exit 2; }
mkdir -p "$LOGDIR_CHECK"
# Everything printed goes to the log too, anonymized: home, user, machine.
ME=$(id -un) HOSTN=$(hostname -s 2>/dev/null || hostname)
export ME HOSTN
exec > >(perl -pe 's/\Q$ENV{HOME}\E/~/g; s/\b\Q$ENV{ME}\E\b/<user>/g; s/\b\Q$ENV{HOSTN}\E\b/<host>/g; $|=1' | tee "$LOG") 2>&1

ok() { PASS=$((PASS + 1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL + 1)); echo "  ✘ $1"; }
section() { STEP_T0=$(date +%s); echo; echo "== $1"; }
# wait_until <seconds> <what> <command…> : 0 when the command passes in time,
# a line every 2 s saying what it waits for.
wait_until() {
	local limit=$1 what=$2 t0 el last=0
	shift 2
	t0=$(date +%s)
	while :; do
		"$@" >/dev/null 2>&1 && return 0
		el=$(($(date +%s) - t0))
		[ "$el" -ge "$limit" ] && { echo "  … gave up waiting for $what after ${limit}s"; return 1; }
		if [ $((el - last)) -ge 2 ]; then last=$el; echo "  … waiting for $what (${el}s / ${limit}s)"; fi
		sleep 0.5
	done
}
finish() {
	echo
	echo "mac-check: $PASS pass / $FAIL fail — $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
	echo "log: ${LOG#"$PROJ"/}"
	exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
}
# The check's own agent browser setup: one origin, headless, muted.
export AGENT_BROWSER_ORIGINS="http://localhost:$PAGE_PORT" AGENT_BROWSER_REACH='' AGENT_BROWSER_WINDOW=0 AGENT_BROWSER_AUDIO=off
CTL_Y="$PROJ/.devcontainer/tmp/agent-browser/y/host"
CTL_X="$PROJ/.devcontainer/tmp/agent-browser/x/host"
APPS="$HOME/Library/Application Support/agent-browser"
# pgrep from this shell: a `bash -c "pgrep …"` would match its own command line.
on_profile() { pgrep -f -- "--user-data-dir=$1" >/dev/null; }
off_profile() { ! on_profile "$1"; }
beats() { [ -f "$1/heartbeat" ] && [ $(($(date +%s) - $(cat "$1/heartbeat"))) -le 3 ]; }

section "0. preflight"
echo "  kit: ${KIT#"$PROJ"/} ; started $(date '+%Y-%m-%d %H:%M')"
[ "$(uname -s)" = Darwin ] && ok "macOS" || { ko "not macOS ($(uname -s)) — this check is for the Mac"; finish; }
NODE=$(command -v node) && "$NODE" -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' \
	&& ok "node $("$NODE" -v)" || { ko "node 22+ not found — brew install node"; finish; }
found=$("$NODE" "$KIT/host-supervisor.mjs" find-chromium | head -n 1)
[ -n "$found" ] && ok "Chromium: $found" || { ko "no Chromium — bash $HA install-chromium, then re-run"; finish; }
# host-agent.sh's own rule: the environment, then .devcontainer/.env, then the folder's name.
PROJECT=${DC_PROJECT:-$(sed -n 's/^DC_PROJECT=//p' "$PROJ/.devcontainer/.env" 2>/dev/null | tail -n 1 | tr -d '"'"'")}
PROJECT=$(printf '%s' "${PROJECT:-$(basename "$PROJ")}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-')
for l in y x; do
	if [ -f "$HOME/Library/LaunchAgents/io.meitogi.agent-browser.$PROJECT.$l.plist" ]; then
		ko "instance $l of $PROJECT is installed — this check uses y and x ; uninstall it first: bash $HA uninstall $l"
		finish
	fi
done
ok "instances y and x of $PROJECT are free"

section "1. a test page on http://localhost:$PAGE_PORT/"
"$NODE" "$PLAY" serve "$PAGE_PORT" &
PAGE_PID=$!
trap 'kill $PAGE_PID 2>/dev/null; bash "$HA" uninstall y >/dev/null 2>&1; rm -rf "${SELF:-/nonexistent}"' EXIT
wait_until 5 "the test page" curl -fs "http://localhost:$PAGE_PORT/" && ok "test page served" || { ko "the test page did not come up (port $PAGE_PORT taken?)"; finish; }

section "2. install y --port $Y_PORT --cdp-port $Y_CDP"
out=$(bash "$HA" install y --port "$Y_PORT" --cdp-port "$Y_CDP" 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
[ $rc -eq 0 ] && [ "$(echo "$out" | grep -cE '^\[[1-5]/5 [a-z]+\] (ok|warn) — ')" -eq 5 ] && ok "install: exit 0, five steps" || ko "install: exit $rc (above)"
PLIST="$HOME/Library/LaunchAgents/io.meitogi.agent-browser.$PROJECT.y.plist"
grep -q 'host-supervisor.mjs</string>' "$PLIST" 2>/dev/null && ok "the plist runs host-supervisor.mjs with node" || ko "the plist does not name host-supervisor.mjs"
wait_until 10 "y's heartbeat" beats "$CTL_Y" && ok "y beats" || ko "no heartbeat from y — bash $HA logs y"

section "3. y driven like the container"
"$NODE" "$PLAY" drive "$CTL_Y" "http://localhost:$PAGE_PORT/" --timeout 20 && ok "y: up, proxy, page, down" || ko "y: the drive failed (above)"

section "4. list, list --json"
bash "$HA" list 2>&1 | sed 's/^/    /'
bash "$HA" list --json >"$LOGDIR_CHECK/list.json" 2>&1
"$NODE" -e 'const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const y = j.instances.find(i => i.instance === "y"); process.exit(y && y.loaded && y.proxy.port === 19590 ? 0 : 1)' "$LOGDIR_CHECK/list.json" \
	&& ok "list --json: y loaded on 19590" || { ko "list --json does not show y loaded"; sed 's/^/    /' "$LOGDIR_CHECK/list.json"; }

section "5. stop y, start y"
# Chromium up when the job is stopped: launchd's TERM must take it down too.
printf '%s up http://localhost:%s/\n' "$(date +%s)000" "$PAGE_PORT" >"$CTL_Y/cmd"
wait_until 15 "Chromium up on y's profile" on_profile "$APPS/$PROJECT.y/profile"
bash "$HA" stop y 2>&1 | sed 's/^/    /'
launchctl print "gui/$(id -u)/io.meitogi.agent-browser.$PROJECT.y" >/dev/null 2>&1 && ko "y still loaded after stop" || ok "stop: y unloaded"
wait_until 10 "Chromium gone from y's profile" off_profile "$APPS/$PROJECT.y/profile" && ok "stop: no Chromium left on y's profile" || ko "a Chromium is still on y's profile after stop"
out=$(bash "$HA" start y 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
[ $rc -eq 0 ] && [ "$(echo "$out" | grep -cE '^\[[1-5]/5 [a-z]+\] (ok|warn) — ')" -eq 5 ] && ok "start: back, five steps" || ko "start: exit $rc (above)"

section "6. uninstall y"
bash "$HA" uninstall y 2>&1 | sed 's/^/    /'
[ ! -e "$PLIST" ] && [ ! -e "$APPS/$PROJECT.y" ] && ok "uninstall: plist, copy and profile gone" || ko "uninstall left $PLIST or $APPS/$PROJECT.y"

section "7. run x --temp --port $X_PORT, then Ctrl-C"
set -m
bash "$HA" run x --temp --port "$X_PORT" --cdp-port "$X_CDP" >"$LOGDIR_CHECK/run-x.out" 2>&1 &
RUN_PID=$!
set +m
wait_until 15 "x's heartbeat" beats "$CTL_X" && ok "run x --temp beats" || { ko "no heartbeat from run x"; sed 's/^/    /' "$LOGDIR_CHECK/run-x.out"; }
grep -q '^──── paste this to the agent' "$LOGDIR_CHECK/run-x.out" && ok "run prints the block to paste to the agent" || ko "no paste block in run's output"
"$NODE" "$PLAY" drive "$CTL_X" "http://localhost:$PAGE_PORT/" --timeout 20 && ok "x: up, proxy, page, down" || ko "x: the drive failed (above)"
# Ctrl-C reaches the whole foreground process group: the same here.
kill -INT -- -"$RUN_PID" 2>/dev/null || kill -INT "$RUN_PID"
wait_until 15 "run x to exit" bash -c "! kill -0 $RUN_PID" && ok "Ctrl-C: run x exited" || ko "run x still runs 15 s after Ctrl-C"
sed 's/^/    /' "$LOGDIR_CHECK/run-x.out" | tail -n 3
[ ! -e "$APPS/$PROJECT.x" ] && [ ! -e "$HOME/Library/Logs/agent-browser/$PROJECT.x" ] && [ ! -e "$CTL_X/heartbeat" ] \
	&& ok "Ctrl-C: x's profile, logs and heartbeat gone" || ko "x left its profile, logs or heartbeat behind"
on_profile "$APPS/$PROJECT.x/profile" && ko "a Chromium still runs on x's profile" || ok "Ctrl-C: no Chromium left on x's profile"
finish
