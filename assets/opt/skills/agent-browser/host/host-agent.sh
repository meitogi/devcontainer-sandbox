#!/usr/bin/env bash
# host-agent.sh — install and watch the host's agent browser. Run on the HOST
# (the Mac's Terminal, not VS Code's), from the project root, out of the kit
# extracted from the image (see the agent-browser skill — `agent-browser
# host-kit` in the container prints the one-line recipe):
#
#   install [i…]    write ~/Library/LaunchAgents/io.meitogi.agent-browser.<project>.plist
#                   and load it (macOS) ; with SwiftBar set up, its menu-bar plugin too
#   uninstall [i…]  unload it, remove the plist, the copy, the profile, the plugin
#   status [i…]     launchd state, heartbeat age, what the supervisor last answered,
#                   the kit hash to compare with `agent-browser status` in the container
#   logs [i]        follow the supervisor's, Chromium's and the DevTools proxy's logs
#   run [i]         the supervisor in THIS terminal, foreground, Ctrl-C stops it —
#                   the fallback on a host without launchd (Linux, WSL2), and a way to
#                   watch it live on a Mac
#   instances       which instances install would bring up, and their ports (reads only)
#
# Instances : one browser per letter, a (the default, the names above) to z.
# Instance n letters after `a` gets the label <…>.<project>.<letter>, its own
# copy, profile and logs (<project>.<letter>/), the channel
# .devcontainer/tmp/agent-browser/<letter>/host, and the ports
# AGENT_BROWSER_PROXY_PORT + n / AGENT_BROWSER_CDP_PORT + n (b → 9224 / 9324).
# Without a list, install brings up every instance whose proxy port the
# project's firewall opens (host:<port> in .devcontainer/firewall/ports.txt —
# the container reaches no other), a alone when it opens none ; status and
# uninstall act on every instance installed.
#
# Configuration is read from .devcontainer/.env (as data, never sourced) :
# AGENT_BROWSER_ORIGINS (required), _REACH, _SIZE, _AUDIO, _WINDOW, _PROXY_PORT,
# _CDP_PORT, _PROXY_BIND, _CERT, _CHROMIUM, _IDLE_S and DC_PROJECT ; a variable
# already in the environment wins over the file. launchd runs a COPY of the kit
# in ~/Library/Application Support/agent-browser/<project>/agent/ : the kit came
# out of the image, so nothing the container writes runs here. A new image →
# extract the kit again, re-run install ; `status` says when the two differ.
# Bash 3.2 (the Mac's).
set -euo pipefail

HOST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(pwd)"
ENV_FILE="$REPO/.devcontainer/.env"
OS="$(uname -s)"

die() {
	echo "✗ $*" >&2
	exit 2
}

if { [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ]; } && [ "${1:-}" != instances ]; then
	die "host-agent.sh runs on the host: open the host's Terminal, cd to the project, run it there."
fi
[ -f "$REPO/.devcontainer/docker-compose.yml" ] || die "run this from the project root (no .devcontainer/docker-compose.yml here: $REPO)."

# One value of .devcontainer/.env, quotes stripped ; the environment wins.
conf() {
	local v=""
	eval "v=\${$1:-}"
	if [ -z "$v" ] && [ -f "$ENV_FILE" ]; then
		v=$(sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
	fi
	printf '%s' "${v:-${2:-}}"
}

PROJECT=$(conf DC_PROJECT "$(basename "$REPO")" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-')
ORIGINS=$(conf AGENT_BROWSER_ORIGINS)
REACH=$(conf AGENT_BROWSER_REACH)
SIZE=$(conf AGENT_BROWSER_SIZE 1280,800)
AUDIO=$(conf AGENT_BROWSER_AUDIO off)
WINDOW=$(conf AGENT_BROWSER_WINDOW 0)
PROXY_PORT=$(conf AGENT_BROWSER_PROXY_PORT 9223)
CDP_PORT=$(conf AGENT_BROWSER_CDP_PORT 9323)
PROXY_BIND=$(conf AGENT_BROWSER_PROXY_BIND 127.0.0.1)
CERT=$(conf AGENT_BROWSER_CERT)
CHROMIUM=$(conf AGENT_BROWSER_CHROMIUM)
IDLE_S=$(conf AGENT_BROWSER_IDLE_S 360)
case "$CERT" in '' | /*) ;; *) CERT="$REPO/$CERT" ;; esac

BASE_PROXY_PORT=$PROXY_PORT
BASE_CDP_PORT=$CDP_PORT
DOMAIN="gui/$(id -u)"
PLUGIN_SRC=swiftbar-agent-browser.5s.sh
PORTS_FILE="$REPO/.devcontainer/firewall/ports.txt"

# instance <letter> : the names, paths and ports of that instance (globals).
instance() {
	case $1 in [a-z]) ;; *) die "instance '$1' : one letter, a (the default) to z" ;; esac
	local n suffix=''
	n=$(($(printf '%d' "'$1") - 97))
	[ "$1" = a ] || suffix=.$1
	INST=$1
	LABEL=io.meitogi.agent-browser.$PROJECT$suffix
	if [ "$OS" = Darwin ]; then
		APP="$HOME/Library/Application Support/agent-browser/$PROJECT$suffix"
		LOGDIR="$HOME/Library/Logs/agent-browser/$PROJECT$suffix"
	else
		APP="${XDG_DATA_HOME:-$HOME/.local/share}/agent-browser/$PROJECT$suffix"
		LOGDIR="$APP/logs"
	fi
	AGENT="$APP/agent"
	PROFILE="$APP/profile"
	PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
	CTL="$REPO/.devcontainer/tmp/agent-browser${suffix:+/$1}/host"
	PLUGIN="agent-browser-$PROJECT$suffix.5s.sh"
	PROXY_PORT=$((BASE_PROXY_PORT + n))
	CDP_PORT=$((BASE_CDP_PORT + n))
}

# Every letter whose proxy port the project's firewall opens ; a when none.
discovered() {
	local l n list=''
	for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
		n=$(($(printf '%d' "'$l") - 97))
		if [ -r "$PORTS_FILE" ] && sed 's/#.*//; s/[[:space:]]//g' "$PORTS_FILE" | grep -qx "host:$((BASE_PROXY_PORT + n))"; then
			list="$list $l"
		fi
	done
	echo "${list:- a}"
}

# Every letter with a plist (macOS) or a folder (elsewhere) ; nothing when none.
installed() {
	local l list=''
	for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
		instance "$l"
		if [ -f "$PLIST" ] || [ -d "$APP/agent" ]; then list="$list $l"; fi
	done
	echo "$list"
}

# The kit's identity: every file, in name order. `agent-browser status` in the
# container prints the same hash for /opt/…/agent-browser/host/.
kit_hash() {
	local sum
	if command -v shasum >/dev/null 2>&1; then sum="shasum -a 256"; else sum=sha256sum; fi
	(cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done) | $sum | cut -c1-12
}

xml() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# What the supervisor needs, exported ; `install` writes the same into the plist.
supervisor_env() {
	export AGENT_BROWSER_CTL="$CTL" AGENT_BROWSER_PROFILE="$PROFILE" AGENT_BROWSER_LOGDIR="$LOGDIR"
	export AGENT_BROWSER_ORIGINS="$ORIGINS" AGENT_BROWSER_REACH="$REACH" AGENT_BROWSER_SIZE="$SIZE"
	export AGENT_BROWSER_AUDIO="$AUDIO" AGENT_BROWSER_WINDOW="$WINDOW" AGENT_BROWSER_PROXY_PORT="$PROXY_PORT"
	export AGENT_BROWSER_CDP_PORT="$CDP_PORT" AGENT_BROWSER_PROXY_BIND="$PROXY_BIND" AGENT_BROWSER_CERT="$CERT"
	export AGENT_BROWSER_CHROMIUM="$CHROMIUM" AGENT_BROWSER_IDLE_S="$IDLE_S" NODE="$NODE"
}

# The prerequisites both install and run need. Sets NODE and CHROMIUM_BIN.
prereqs() {
	NODE=$(command -v node) || die "node not found — brew install node (22 or later)"
	"$NODE" -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' \
		|| die "node $("$NODE" -v) is too old: the DevTools proxy needs 22+ (its built-in WebSocket) — brew upgrade node"
	[ -n "$ORIGINS" ] || die "AGENT_BROWSER_ORIGINS is not set in $ENV_FILE — space-separated scheme://host[:port], e.g. http://localhost:5173"
	AGENT_BROWSER_ORIGINS="$ORIGINS" AGENT_BROWSER_REACH="$REACH" "$NODE" "$HOST_DIR/cdp-proxy.mjs" pac >/dev/null || die "AGENT_BROWSER_ORIGINS has an entry the proxy refuses (above)"
	CHROMIUM_BIN=$(HOST_DIR="$HOST_DIR" PROFILE=/dev/null AGENT_BROWSER_CHROMIUM="$CHROMIUM" bash -c '. "$HOST_DIR/chromium-flags.sh"; ab_find_chromium; echo "$AB_CHROMIUM"')
	[ -n "$CHROMIUM_BIN" ] || die "Chromium not found — brew install --cask chromium, or AGENT_BROWSER_CHROMIUM=/path in .devcontainer/.env"
	if [ -n "$CERT" ]; then [ -r "$CERT" ] || die "AGENT_BROWSER_CERT points at an unreadable file: $CERT"; fi
}

install() {
	[ "$OS" = Darwin ] || die "install needs launchd (macOS). Here: $OS — use \`$0 run\` in a terminal instead (see the skill's Linux / Windows note)."
	prereqs
	mkdir -p "$(dirname "$PLIST")" "$LOGDIR" "$CTL" "$AGENT" "$PROFILE"
	rm -rf "$AGENT"
	cp -R "$HOST_DIR" "$AGENT"
	[ -n "$CERT" ] && { cp -f "$CERT" "$AGENT/dev.crt"; CERT="$AGENT/dev.crt"; }
	supervisor_env
	{
		cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml "$AGENT/host-supervisor.sh")</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
EOP
		local k
		for k in AGENT_BROWSER_CTL AGENT_BROWSER_PROFILE AGENT_BROWSER_LOGDIR AGENT_BROWSER_ORIGINS AGENT_BROWSER_REACH \
			AGENT_BROWSER_SIZE AGENT_BROWSER_AUDIO AGENT_BROWSER_WINDOW AGENT_BROWSER_PROXY_PORT AGENT_BROWSER_CDP_PORT \
			AGENT_BROWSER_PROXY_BIND AGENT_BROWSER_CERT AGENT_BROWSER_CHROMIUM AGENT_BROWSER_IDLE_S NODE; do
			eval "v=\${$k:-}"
			printf '\t\t<key>%s</key><string>%s</string>\n' "$k" "$(xml "$v")"
		done
		printf '\t\t<key>PATH</key><string>%s</string>\n' "$(xml "/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$NODE")")"
		cat <<EOP
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$(xml "$LOGDIR/supervisor.log")</string>
	<key>StandardErrorPath</key><string>$(xml "$LOGDIR/supervisor.log")</string>
</dict>
</plist>
EOP
	} >"$PLIST"
	plutil -lint "$PLIST" >/dev/null || die "the plist did not validate: $PLIST"
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	# bootout returns before the job is gone; a bootstrap meanwhile fails with
	# "5: Input/output error" (every re-install).
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
		sleep 1
	done
	launchctl bootstrap "$DOMAIN" "$PLIST"
	echo "✓ $LABEL loaded — Chromium ${CHROMIUM_BIN%/Contents/*}, node $("$NODE" -v), window $SIZE, audio $AUDIO, $([ "$WINDOW" = 1 ] && echo windowed || echo headless)"
	echo "  allowed origins : $ORIGINS"
	[ -n "$REACH" ] && echo "  may also reach  : $REACH"
	echo "  proxy for the container : $PROXY_BIND:$PROXY_PORT (host:$PROXY_PORT in firewall/ports.txt)"
	echo "  runs the copy in $AGENT (kit $(kit_hash "$AGENT")) — re-extract the kit and re-run install after an image update"
	echo "  idle until the container asks : agent-browser up (in VS Code's terminal)"
	swiftbar_plugin install
	sleep 2
	status
}

# The menu-bar icon, when SwiftBar is there: a copy in its plugin folder, like
# the supervisor (never run from the kit), with this project's label in it.
swiftbar_plugin() {
	local dir
	dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null) || dir=''
	if [ -z "$dir" ] || [ ! -d "$dir" ]; then
		[ "$1" = install ] && echo "  menu bar: install SwiftBar (free), pick its plugin folder, re-run install"
		return 0
	fi
	if [ "$1" = install ]; then
		sed "s/^LABEL=.*/LABEL=$LABEL/" "$HOST_DIR/$PLUGIN_SRC" >"$dir/$PLUGIN"
		chmod 755 "$dir/$PLUGIN"
		echo "  menu bar: SwiftBar plugin $dir/$PLUGIN"
	else
		rm -f "$dir/$PLUGIN"
	fi
}

uninstall() {
	if [ "$OS" = Darwin ]; then
		swiftbar_plugin uninstall
		launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
		rm -f "$PLIST"
	fi
	rm -f "$CTL/heartbeat"
	rm -rf "$APP"
	echo "✓ $LABEL unloaded, $APP removed — the container's sidecar takes over (if the project has one)"
}

status() {
	local beat age
	if [ "$OS" = Darwin ]; then
		if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
			launchctl print "$DOMAIN/$LABEL" | awk '/^\t(state|pid|last exit code) =/ { sub(/^\t/, "  launchd "); print }'
		else
			echo "  launchd: $LABEL not loaded — $0 install $INST"
		fi
	fi
	beat=$(cat "$CTL/heartbeat" 2>/dev/null || echo 0)
	case $beat in '' | *[!0-9]*) beat=0 ;; esac
	age=$(($(date +%s) - beat))
	if [ "$age" -le 5 ]; then
		echo "  heartbeat: ${age}s — the container sends its agent-browser commands here"
	else
		echo "  heartbeat: none — the container falls back to its sidecar, if any"
	fi
	echo "  supervisor: $(cut -d' ' -f2- "$CTL/state" 2>/dev/null || echo 'no state yet')"
	echo "  kit: $(kit_hash "$HOST_DIR") here$([ -d "$AGENT" ] && echo ", $(kit_hash "$AGENT") installed")"
	if [ -d "$AGENT" ] && [ "$(kit_hash "$HOST_DIR")" != "$(kit_hash "$AGENT")" ]; then
		echo "  the installed copy differs from this kit — review, then: $0 install"
	fi
	if [ -f "$PLIST" ] && [ -n "$ORIGINS" ] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
		local baked
		baked=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:AGENT_BROWSER_ORIGINS' "$PLIST" 2>/dev/null || true)
		[ "$baked" = "$ORIGINS" ] || echo "  AGENT_BROWSER_ORIGINS changed in .env ($ORIGINS) — the agent still allows: $baked — re-run install"
	fi
}

logs() {
	mkdir -p "$LOGDIR"
	touch "$LOGDIR/supervisor.log" "$LOGDIR/chromium.log" "$LOGDIR/cdp-proxy.log"
	tail -n 20 -F "$LOGDIR/supervisor.log" "$LOGDIR/cdp-proxy.log" "$LOGDIR/chromium.log"
}

run() {
	prereqs
	mkdir -p "$LOGDIR" "$CTL" "$PROFILE"
	if [ "$OS" = Darwin ] && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
		die "$LABEL is loaded in launchd — two supervisors on one channel. \`$0 uninstall $INST\` first, or use \`logs\`."
	fi
	supervisor_env
	echo "→ supervisor in the foreground, polling $CTL — Ctrl-C stops it (and the browser)"
	echo "  origins: $ORIGINS ; proxy $PROXY_BIND:$PROXY_PORT ; logs in $LOGDIR"
	exec bash "$HOST_DIR/host-supervisor.sh"
}

# What `install` would bring up, one line per instance.
instances() {
	local l
	echo "firewall: $([ -r "$PORTS_FILE" ] && echo "$PORTS_FILE" || echo "no $PORTS_FILE — instance a only")"
	for l in $(discovered); do
		instance "$l"
		echo "  $l  $LABEL  proxy $PROXY_BIND:$PROXY_PORT  devtools 127.0.0.1:$CDP_PORT  channel ${CTL#"$REPO"/}"
	done
}

verb=${1:-status}
[ $# -gt 0 ] && shift
case $verb in
	install)
		for i in ${*:-$(discovered)}; do instance "$i"; echo "== instance $i"; install; done ;;
	uninstall)
		list=${*:-$(installed)}
		[ -n "$list" ] || { instance a; uninstall; exit 0; }
		for i in $list; do instance "$i"; uninstall; done ;;
	status)
		list=${*:-$(installed)}
		for i in ${list:-a}; do instance "$i"; echo "== instance $i ($LABEL)"; status; done ;;
	logs) instance "${1:-a}"; logs ;;
	run) instance "${1:-a}"; run ;;
	instances) instances ;;
	*) die "usage: host-agent.sh {install|uninstall|status} [instance…] | {logs|run} [instance] | instances" ;;
esac
