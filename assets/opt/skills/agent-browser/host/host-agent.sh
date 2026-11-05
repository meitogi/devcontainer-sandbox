#!/usr/bin/env bash
# host-agent.sh — install and watch the host's agent browser. Run on the HOST
# (the Mac's Terminal, not VS Code's), from the project root, out of the kit
# extracted from the image (see the agent-browser skill — `agent-browser
# host-kit` in the container prints the one-line recipe):
#
#   install [i…]    write ~/Library/LaunchAgents/io.meitogi.agent-browser.<project>.plist
#                   and load it (macOS) ; with SwiftBar set up, its menu-bar plugin too.
#                   a alone without a list ; --all = every instance the firewall opens
#   start [i…]      load an installed instance again (install it when it is not) ; a by default
#   stop [i…]       unload it, Chromium and its proxy off ; the plist and the plugin stay,
#                   and it stays off across logins until start. Every installed one by default
#   uninstall [i…]  unload it, remove the plist, the copy, the profile, the plugin
#   list [--json]   every instance of this project, one line each — loaded or not, pids,
#                   proxy port and whether it listens, heartbeat, logs — and the other
#                   projects' agent browsers with their proxy ports, to spot a clash ;
#                   --json: the same as one object (instances[], others[]), for tools
#   status [i…]     launchd state, heartbeat age, what the supervisor last answered,
#                   the Chromium the plist carries, whether the proxy listens, and the
#                   kit hash to compare with `agent-browser status` in the container
#   logs [i]        follow the supervisor's, Chromium's and the DevTools proxy's logs
#   run [i]         the supervisor in THIS terminal, foreground, Ctrl-C stops it —
#                   the fallback on a host without launchd (Linux, WSL2), and a way to
#                   watch it live on a Mac. Prints a block to paste to the agent
#   run <i> --temp  a temporary instance: the same, and Ctrl-C also removes its
#                   profile and logs. Refused on an installed instance
#   instances       which instances install --all would bring up, their ports, which are
#                   installed (reads only)
#   install <i> --port <n> [--cdp-port <n>]
#                   that instance on these ports instead of the .env's ; the container
#                   follows (the supervisor announces its port in the channel), the
#                   firewall must open host:<n>. A later install without --port goes
#                   back to the .env's ports, and says so
#   install [i…] --visible   (or run --visible) a real window on every start instead of
#                   headless, without editing AGENT_BROWSER_WINDOW in .env ; a later install
#                   without it is headless again. For one window, the container's
#                   `agent-browser handoff` needs no install at all
#   install-chromium  download the latest Chromium snapshot for this Mac into
#                   ~/Library/Application Support/agent-browser/chromium/ and print the
#                   AGENT_BROWSER_CHROMIUM line for .devcontainer/.env (edits no file)
#
# install and start print five numbered steps — kit, chromium, firewall, launchd,
# heartbeat — each ok, warn or FAILED with the cause and the command to run next.
#
# Instances : one browser per letter, a (the default, the names above) to z.
# Instance n letters after `a` gets the label <…>.<project>.<letter>, its own
# copy, profile and logs (<project>.<letter>/), the channel
# .devcontainer/tmp/agent-browser/<letter>/host, and the ports
# AGENT_BROWSER_PROXY_PORT + n / AGENT_BROWSER_CDP_PORT + n (b → 9224 / 9324).
# Without a list, install and start bring up a ; install --all every instance
# whose proxy port the project's firewall opens (host:<port> in
# .devcontainer/firewall/ports.txt — the container reaches no other) ; status,
# stop and uninstall act on every instance installed.
#
# Configuration is read from .devcontainer/.env (as data, never sourced) :
# AGENT_BROWSER_ORIGINS (required), _REACH, _SIZE, _AUDIO, _WINDOW, _PROXY_PORT,
# _CDP_PORT, _PROXY_BIND, _CERT, _CHROMIUM, _IDLE_S, _ICON_LETTERS and DC_PROJECT ;
# per instance (X = its letter, upper-case) AGENT_BROWSER_<X>_ICON_LETTERS (the
# menu-bar tag, default the project's) and AGENT_BROWSER_<X>_NOTE (the menu's
# second line, e.g. what b is for) ;
# a variable already in the environment wins over the file. launchd runs a COPY of the kit
# in ~/Library/Application Support/agent-browser/<project>/agent/ : the kit came
# out of the image, so nothing the container writes runs here. A new image →
# extract the kit again, re-run install ; `status` says when the two differ.
# Bash 3.2 (the Mac's).
set -euo pipefail

HOST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(pwd)"
ENV_FILE="$REPO/.devcontainer/.env"
OS="$(uname -s)"

# The numbered steps of install / start: `step <n> <name>` opens one, ok / warn
# close it, and a die inside it prints it FAILED.
STEP=''
step() { STEP="[$1/5 $2]"; }
ok() { echo "$STEP ok — $*"; STEP=''; }
warn() { echo "$STEP warn — $*"; STEP=''; }

die() {
	if [ -n "$STEP" ]; then echo "✗ $STEP FAILED — $*" >&2; else echo "✗ $*" >&2; fi
	exit 2
}

# AGENT_BROWSER_HOST_TEST: the sandbox's own suite drives this script in a
# container, with launchctl and friends stubbed.
if { [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ]; } && [ "${1:-}" != instances ] && [ -z "${AGENT_BROWSER_HOST_TEST:-}" ]; then
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
ICON_LETTERS=$(conf AGENT_BROWSER_ICON_LETTERS "$(printf '%s' "$PROJECT" | tr -cd 'a-z0-9' | cut -c1-2 | tr 'a-z' 'A-Z')")
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
	DERIVED_PROXY_PORT=$((BASE_PROXY_PORT + n))
	DERIVED_CDP_PORT=$((BASE_CDP_PORT + n))
	# Installed, its ports are the plist's (install --port may have set them).
	PROXY_PORT=$(plist_env AGENT_BROWSER_PROXY_PORT)
	CDP_PORT=$(plist_env AGENT_BROWSER_CDP_PORT)
	PROXY_PORT=${PROXY_PORT:-$DERIVED_PROXY_PORT}
	CDP_PORT=${CDP_PORT:-$DERIVED_CDP_PORT}
}

# The ports install and run use: --port / --cdp-port, else the .env's, derived
# per letter. Says so when an installed instance moves.
ports() {
	local was=$PROXY_PORT
	PROXY_PORT=${OPT_PROXY_PORT:-$DERIVED_PROXY_PORT}
	CDP_PORT=${OPT_CDP_PORT:-$DERIVED_CDP_PORT}
	if [ -f "$PLIST" ] && [ "$was" != "$PROXY_PORT" ]; then
		echo "  proxy port $PROXY_PORT, was $was$([ -z "$OPT_PROXY_PORT" ] && echo " — install $INST --port $was keeps the old one")"
	fi
}

# Does the project's firewall open host:<port> ?
opens() {
	[ -r "$PORTS_FILE" ] && sed 's/#.*//; s/[[:space:]]//g' "$PORTS_FILE" | grep -qx "host:$1"
}

# Every letter whose proxy port the project's firewall opens ; a when none.
discovered() {
	local l n list=''
	for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
		n=$(($(printf '%d' "'$l") - 97))
		if opens $((BASE_PROXY_PORT + n)); then
			list="$list $l"
		fi
	done
	echo "${list:- a}"
}

# The instance's menu-bar letters, its mark in the dot (none for a) and its note,
# from AGENT_BROWSER_<X>_ICON_LETTERS / _NOTE. The note reaches the SwiftBar
# plugin, a shell script: no « | » (SwiftBar would read parameters after it,
# bash= included), no line break.
labels() {
	local x
	x=$(printf '%s' "$INST" | tr 'a-z' 'A-Z')
	INST_LETTERS=$(conf "AGENT_BROWSER_${x}_ICON_LETTERS" "$ICON_LETTERS")
	INST_NOTE=$(conf "AGENT_BROWSER_${x}_NOTE" | tr -d '|\r\n')
	MARK=''
	[ "$INST" = a ] || MARK=$INST
}

# One EnvironmentVariables value of a plist this script wrote (one key per line).
plist_env() {
	[ -f "${2:-$PLIST}" ] || return 0
	sed -n "s|.*<key>$1</key><string>\(.*\)</string>.*|\1|p" "${2:-$PLIST}" | head -n 1 \
		| sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'
}

loaded() {
	launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

# The epoch in the heartbeat file, 0 when there is none.
beat() {
	local b
	b=$(cat "$CTL/heartbeat" 2>/dev/null || echo 0)
	case $b in '' | *[!0-9]*) b=0 ;; esac
	echo "$b"
}

# Does something listen on the proxy's port ? Bash's own /dev/tcp, no nc.
listening() {
	local addr=$PROXY_BIND
	[ "$addr" = 0.0.0.0 ] && addr=127.0.0.1
	(exec 3<>"/dev/tcp/$addr/$PROXY_PORT") 2>/dev/null
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
	export AGENT_BROWSER_CHROMIUM="${CHROMIUM:-${CHROMIUM_BIN:-}}" AGENT_BROWSER_IDLE_S="$IDLE_S" NODE="$NODE"
	# The project's tree : the only place a download may land (cdp-proxy.mjs downloadCheck).
	export AGENT_BROWSER_ROOT="$REPO"
}

# The prerequisites both install and run need, but Chromium. Sets NODE.
prereqs_kit() {
	NODE=$(command -v node) || die "node not found — brew install node (22 or later)"
	"$NODE" -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' \
		|| die "node $("$NODE" -v) is too old: the DevTools proxy needs 22+ (its built-in WebSocket) — brew upgrade node"
	[ -n "$ORIGINS" ] || die "AGENT_BROWSER_ORIGINS is not set in $ENV_FILE — space-separated scheme://host[:port], e.g. http://localhost:5173"
	AGENT_BROWSER_ORIGINS="$ORIGINS" AGENT_BROWSER_REACH="$REACH" "$NODE" "$HOST_DIR/cdp-proxy.mjs" pac >/dev/null || die "AGENT_BROWSER_ORIGINS has an entry the proxy refuses (above)"
	if [ -n "$CERT" ]; then [ -r "$CERT" ] || die "AGENT_BROWSER_CERT points at an unreadable file: $CERT"; fi
}

# Chromium, the supervisor's own search (host-supervisor.mjs find-chromium). Sets
# CHROMIUM_BIN ; not found, says every place it looked.
prereqs_chromium() {
	local found tried
	found=$(AGENT_BROWSER_CHROMIUM="$CHROMIUM" "$NODE" "$HOST_DIR/host-supervisor.mjs" find-chromium)
	CHROMIUM_BIN=$(printf '%s\n' "$found" | head -n 1)
	tried=$(printf '%s\n' "$found" | tail -n +2 | sed 's/^/    /')
	[ -n "$CHROMIUM_BIN" ] || die "Chromium not found. Looked in:
$tried
  → $0 install-chromium (a Chromium snapshot, no admin rights), or brew install --cask chromium ; then $0 install $INST"
}

install() {
	[ "$OS" = Darwin ] || die "install needs launchd (macOS). Here: $OS — use \`$0 run\` in a terminal instead (see the skill's Linux / Windows note)."
	local hash t0
	ports
	step 1 kit
	prereqs_kit
	mkdir -p "$(dirname "$PLIST")" "$LOGDIR" "$CTL" "$AGENT" "$PROFILE"
	rm -rf "$AGENT"
	cp -R "$HOST_DIR" "$AGENT"
	[ -n "$CERT" ] && { cp -f "$CERT" "$AGENT/dev.crt"; CERT="$AGENT/dev.crt"; }
	hash=$(kit_hash "$AGENT")
	ok "node $("$NODE" -v), kit $hash copied to $AGENT — allowed origins: $ORIGINS${REACH:+ ; may also reach: $REACH}"
	step 2 chromium
	prereqs_chromium
	ok "$CHROMIUM_BIN$([ -n "$CHROMIUM" ] && echo ' (AGENT_BROWSER_CHROMIUM)')"
	step_firewall
	step 4 launchd
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
		<string>$(xml "$NODE")</string>
		<string>$(xml "$AGENT/host-supervisor.mjs")</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
EOP
		local k
		for k in AGENT_BROWSER_CTL AGENT_BROWSER_PROFILE AGENT_BROWSER_LOGDIR AGENT_BROWSER_ORIGINS AGENT_BROWSER_REACH \
			AGENT_BROWSER_SIZE AGENT_BROWSER_AUDIO AGENT_BROWSER_WINDOW AGENT_BROWSER_PROXY_PORT AGENT_BROWSER_CDP_PORT \
			AGENT_BROWSER_PROXY_BIND AGENT_BROWSER_CERT AGENT_BROWSER_CHROMIUM AGENT_BROWSER_IDLE_S AGENT_BROWSER_ROOT NODE; do
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
	plutil -lint "$PLIST" >/dev/null || die "the plist did not validate: $PLIST — keep that file and report it"
	t0=$(date +%s)
	unload
	bootstrap
	ok "$LABEL loaded — proxy $PROXY_BIND:$PROXY_PORT, $([ "$WINDOW" = 1 ] && echo windowed || echo headless) $SIZE, audio $AUDIO"
	swiftbar_plugin install
	step_heartbeat "$t0"
	echo "  idle until the container asks: agent-browser$([ "$INST" = a ] || echo " -i $INST") up — a new image: extract the kit again, re-run install"
}

# [3/5] Can the container reach the proxy ? A warning only: the host side works.
step_firewall() {
	step 3 firewall
	if opens "$PROXY_PORT"; then
		ok "host:$PROXY_PORT in .devcontainer/firewall/ports.txt"
	else
		warn "host:$PROXY_PORT is not in .devcontainer/firewall/ports.txt — add it, then Rebuild Container (the host side works, the container cannot reach it yet)"
	fi
}

# Unload the job and wait until it is gone: bootout returns before that, and a
# bootstrap meanwhile fails with "5: Input/output error" (every re-install).
unload() {
	local i
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	for i in 1 2 3 4 5 6 7 8 9 10; do
		loaded || break
		sleep 1
	done
}

# Load the plist. enable first: stop disables the job, so that it stays off
# across logins (RunAtLoad), and a disabled job refuses bootstrap.
bootstrap() {
	launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
	launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap refused $PLIST (above) — $0 logs $INST"
}

# [5/5] A heartbeat written since <t0>: what the container routes by.
step_heartbeat() {
	local i b
	step 5 heartbeat
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		b=$(beat)
		if [ "$b" -ge "$1" ]; then
			ok "$(($(date +%s) - b))s old — the container routes agent-browser$([ "$INST" = a ] || echo " -i $INST") here"
			return 0
		fi
		sleep 0.5
	done
	die "no heartbeat in $CTL within 10 s — the supervisor did not start: $0 logs $INST"
}

# An installed instance back on: the same five steps, nothing rewritten.
start() {
	[ "$OS" = Darwin ] || die "start needs launchd (macOS). Here: $OS — use \`$0 run\` in a terminal instead."
	if [ ! -f "$PLIST" ]; then
		echo "  $LABEL is not installed — installing it"
		install
		return
	fi
	local here there chromium t0
	step 1 kit
	[ -d "$AGENT" ] || die "the installed copy $AGENT is missing — $0 install $INST"
	here=$(kit_hash "$HOST_DIR")
	there=$(kit_hash "$AGENT")
	if [ "$here" = "$there" ]; then
		ok "installed copy $AGENT, kit $there"
	else
		warn "the installed copy (kit $there) differs from this kit ($here) — review, then $0 install $INST"
	fi
	step 2 chromium
	chromium=$(plist_env AGENT_BROWSER_CHROMIUM)
	if [ -z "$chromium" ]; then
		warn "the plist names no Chromium (an older install) — the supervisor searches for one ; $0 install $INST writes the one found"
	elif [ -x "$chromium" ]; then
		ok "$chromium"
	else
		die "the plist's Chromium is not there any more: $chromium — $0 install-chromium, or $0 install $INST"
	fi
	step_firewall
	step 4 launchd
	t0=$(date +%s)
	if loaded; then
		ok "$LABEL already loaded"
		t0=$((t0 - 5))
	else
		bootstrap
		ok "$LABEL loaded"
	fi
	step_heartbeat "$t0"
}

# Off without uninstalling: the supervisor's TERM stops Chromium and the proxy ;
# disabled, launchd does not load it again at the next login.
stop() {
	[ -f "$PLIST" ] || die "instance $INST is not installed ($PLIST) — nothing to stop"
	unload
	launchctl disable "$DOMAIN/$LABEL" 2>/dev/null || true
	echo "✓ $LABEL stopped — Chromium and its proxy off ; the plist and the menu-bar plugin stay. $0 start $INST brings it back"
}

# The menu-bar icon, when SwiftBar is there: a copy in its plugin folder, like
# the supervisor (never run from the kit), with this project's label in it and
# its icons, drawn from the SVG by the host's Chromium (the project's own SVG
# when it has one) with this instance's letters and mark, and its note — or
# the project's ready-made PNGs, .devcontainer/agent-browser/menubar-icon/,
# when it ships the whole set for this instance. Not drawn, the plugin keeps
# its SF Symbols.
swiftbar_plugin() {
	local dir svg pngs icons line
	labels
	local args=(-e "s/^LABEL=.*/LABEL=$LABEL/" -e "s|^NOTE_B64=.*|NOTE_B64=$(printf '%s' "$INST_NOTE" | base64 | tr -d '\n')|")
	dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null) || dir=''
	if [ -z "$dir" ] || [ ! -d "$dir" ]; then
		[ "$1" = install ] && echo "  menu bar: install SwiftBar (free), pick its plugin folder, re-run install"
		return 0
	fi
	if [ "$1" = install ]; then
		svg="$REPO/.devcontainer/agent-browser/menubar-icon.svg"
		[ -f "$svg" ] || svg="$HOST_DIR/menubar-icon.svg"
		pngs="$REPO/.devcontainer/agent-browser/menubar-icon"
		if icons=$("$NODE" "$HOST_DIR/menubar-icon.mjs" "$svg" "$INST_LETTERS" "$CHROMIUM_BIN" $MARK --png "$pngs"); then
			while IFS= read -r line; do args+=(-e "s|^${line%%=*}=.*|$line|"); done <<<"$icons"
			if [ -f "$pngs/running${MARK:+.$MARK}.png" ]; then
				echo "  menu bar: icon from ${pngs#"$REPO"/}/, ready-made${INST_NOTE:+ — note: $INST_NOTE}"
			else
				echo "  menu bar: icon $INST_LETTERS${MARK:+, $MARK in the dot}, from ${svg#"$REPO"/}${INST_NOTE:+ — note: $INST_NOTE}"
			fi
		else
			echo "  menu bar: icon not drawn (above) — SF Symbols instead"
		fi
		sed "${args[@]}" "$HOST_DIR/$PLUGIN_SRC" >"$dir/$PLUGIN"
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
	rm -f "$CTL/heartbeat" "$CTL/port"
	rm -rf "$APP"
	echo "✓ $LABEL unloaded, $APP removed — the container's sidecar takes over (if the project has one)"
}

status() {
	local beat age
	if [ "$OS" = Darwin ]; then
		[ -f "$PLIST" ] && echo "  chromium: $(plist_env AGENT_BROWSER_CHROMIUM | sed 's/^$/none named in the plist — the supervisor searches/')"
		if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
			launchctl print "$DOMAIN/$LABEL" | awk '/^\t(state|pid|last exit code) =/ { sub(/^\t/, "  launchd "); print }'
		else
			echo "  launchd: $LABEL not loaded — $0 install $INST"
		fi
	fi
	echo "  proxy listening: $(listening && echo yes || echo no) ($PROXY_BIND:$PROXY_PORT)"
	beat=$(beat)
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
	ports
	prereqs_kit
	prereqs_chromium
	[ -z "$OPT_TEMP" ] || [ ! -f "$PLIST" ] || die "instance $INST is installed — --temp would delete its profile. Pick a letter that is not: $0 list"
	if [ "$OS" = Darwin ] && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
		die "$LABEL is loaded in launchd — two supervisors on one channel. \`$0 uninstall $INST\` first, or use \`logs\`."
	fi
	# Another run of this instance — another Terminal, another machine on the
	# same workspace — beats on the channel : two supervisors would start and
	# stop each other's Chromium.
	local age=$(($(date +%s) - $(beat)))
	[ "$age" -gt 5 ] || die "instance $INST already has a supervisor (heartbeat ${age}s old in $CTL) — stop that one first (Ctrl-C in its Terminal)"
	mkdir -p "$LOGDIR" "$CTL" "$PROFILE"
	supervisor_env
	echo "→ supervisor in the foreground, polling $CTL — Ctrl-C stops it (and the browser)$([ -n "$OPT_TEMP" ] && echo ', and removes its profile and logs')"
	echo "  origins: $ORIGINS ; proxy $PROXY_BIND:$PROXY_PORT ; logs in $LOGDIR"
	opens "$PROXY_PORT" || echo "  ⚠ host:$PROXY_PORT is not in .devcontainer/firewall/ports.txt — the container cannot reach it until it is (then Rebuild Container) ; or --port <a port it opens, not in use>"
	brief
	if [ -z "$OPT_TEMP" ]; then exec "$NODE" "$HOST_DIR/host-supervisor.mjs"; fi
	# A child, not exec: something has to clean up after it. Ctrl-C reaches it
	# as TERM (an async child of a script ignores SIGINT), and it stops Chromium.
	local child
	"$NODE" "$HOST_DIR/host-supervisor.mjs" &
	child=$!
	trap 'kill -TERM "$child" 2>/dev/null' INT TERM
	# The first wait returns on the signal (set -e must not end the script there),
	# the second once the supervisor has stopped Chromium.
	wait "$child" 2>/dev/null || true
	wait "$child" 2>/dev/null || true
	rm -rf "$APP" "$LOGDIR"
	echo "✓ temporary instance $INST gone — profile and logs removed"
}

# What to paste to the agent in the container: which instance, how to drive it,
# and that it goes away with Ctrl-C.
brief() {
	local i=''
	[ "$INST" = a ] || i=" -i $INST"
	cat <<EOB

──── paste this to the agent (Claude, or any LLM in the container) ────
An agent browser is running on the host for you: instance $INST$([ -n "$OPT_TEMP" ] && echo ', temporary') (project $PROJECT).
It allows these origins only: $ORIGINS
From the container:
  agent-browser$i status                       # host side should answer
  agent-browser$i up <url>                     # open a page (an allowed origin)
  CDP_INSTANCE=$INST node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot --url <url> --out .tmp/shots/$INST.png
  eval "\$(agent-browser$i env)"                 # CDP_HOST / CDP_PORT for any other CDP client
The human stops it with Ctrl-C$([ -n "$OPT_TEMP" ] && echo ' (its profile is then deleted)'): from then on these exit 3 — say so and stop, do not retry.
────────────────────────────────────────────────────────────────────────

EOB
}

# What `install --all` would bring up, one line per instance.
instances() {
	local l
	echo "firewall: $([ -r "$PORTS_FILE" ] && echo "$PORTS_FILE" || echo "no $PORTS_FILE — instance a only")"
	for l in $(discovered); do
		instance "$l"
		echo "  $l  $LABEL  proxy $PROXY_BIND:$PROXY_PORT  devtools 127.0.0.1:$CDP_PORT  channel ${CTL#"$REPO"/}$([ -f "$PLIST" ] && echo '  installed')"
	done
}

# A JSON string: quotes and backslashes escaped, control characters dropped.
js() {
	printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# A JSON number, or null for "-" / empty.
jn() {
	case $1 in '' | *[!0-9]*) printf null ;; *) printf '%s' "$1" ;; esac
}

# Every instance of this project, installed or opened by the firewall, then the
# other projects' agent browsers. list --json prints the same as one object.
list() {
	[ "$OS" = Darwin ] || die "list reads launchd (macOS). Here: $OS — $0 status instead."
	local json=${1:-} l mine='' ports='' setup load spid word cpid b age job port clash n sep='' listen
	for l in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
		instance "$l"
		if [ -f "$PLIST" ] || opens "$PROXY_PORT" || [ "$l" = a ]; then mine="$mine $l"; fi
	done
	if [ -n "$json" ]; then
		printf '{"project":%s,"firewall":%s,"instances":[' "$(js "$PROJECT")" "$([ -r "$PORTS_FILE" ] && js "${PORTS_FILE#"$REPO"/}" || echo null)"
	else
		echo "$PROJECT — firewall: $([ -r "$PORTS_FILE" ] && echo "${PORTS_FILE#"$REPO"/}" || echo "no ${PORTS_FILE#"$REPO"/}")"
	fi
	for l in $mine; do
		instance "$l"
		labels
		ports="$ports $PROXY_PORT:$l"
		spid=-
		if [ ! -f "$PLIST" ]; then
			setup='not installed' load=-
		elif loaded; then
			setup=installed load=loaded
			spid=$(launchctl print "$DOMAIN/$LABEL" | awk '/^\tpid =/ { print $3 }')
		else
			setup=installed load=stopped
		fi
		read -r _ word cpid _ 2>/dev/null <"$CTL/state" || word=- cpid=-
		[ "$load" = loaded ] || word=stopped
		b=$(beat)
		if [ "$b" -eq 0 ]; then age=none; else age="$(($(date +%s) - b))s"; fi
		if listening; then listen=listening; else listen=closed; fi
		if [ -n "$json" ]; then
			printf '%s{"instance":"%s","label":%s,"installed":%s,"loaded":%s,"supervisor":%s,"chromium":{"state":%s,"pid":%s},"proxy":{"port":%s,"bind":%s,"listening":%s},"heartbeat":%s,"logs":%s,"note":%s}' \
				"$sep" "$l" "$(js "$LABEL")" "$([ "$setup" = installed ] && echo true || echo false)" "$([ "$load" = loaded ] && echo true || echo false)" \
				"$(jn "$spid")" "$(js "${word:--}")" "$(jn "$cpid")" "$(jn "$PROXY_PORT")" "$(js "$PROXY_BIND")" \
				"$([ "$listen" = listening ] && echo true || echo false)" "$(jn "${age%s}")" "$(js "$LOGDIR")" "$(js "$INST_NOTE")"
			sep=,
			continue
		fi
		printf '  %s  %s  %s, %s  supervisor %s  chromium %s %s  proxy %s %s  heartbeat %s  logs %s\n' \
			"$l" "$LABEL" "$setup" "$load" "${spid:--}" "${word:--}" "${cpid:--}" "$PROXY_PORT" \
			"$listen" "$age" "$LOGDIR"
		[ -n "$INST_NOTE" ] && echo "     $INST_NOTE"
	done
	if [ -n "$json" ]; then printf '],"others":['; else echo "other projects:"; fi
	n=0 sep=''
	while IFS= read -r job; do
		case $job in '' | "io.meitogi.agent-browser.$PROJECT" | "io.meitogi.agent-browser.$PROJECT".[a-z]) continue ;; esac
		port=$(plist_env AGENT_BROWSER_PROXY_PORT "$HOME/Library/LaunchAgents/$job.plist")
		clash=''
		case " $ports " in *" ${port:-x}:"*) clash=$(echo "$ports" | tr ' ' '\n' | sed -n "s/^$port://p") ;; esac
		if [ -n "$json" ]; then
			printf '%s{"job":%s,"port":%s,"clash":%s}' "$sep" "$(js "$job")" "$(jn "$port")" "$([ -n "$clash" ] && js "$clash" || echo null)"
			sep=,
		else
			echo "  $job  proxy ${port:-?}${clash:+  ← the same port as instance $clash here}"
		fi
		n=$((n + 1))
	done <<EOF_JOBS
$(launchctl list 2>/dev/null | awk '$3 ~ /^io\.meitogi\.agent-browser\./ { print $3 }' | sort -u)
EOF_JOBS
	if [ -n "$json" ]; then echo ']}'; elif [ "$n" -eq 0 ]; then echo "  none loaded"; fi
}

# A Chromium snapshot for this Mac, out of the project: the AGENT_BROWSER_CHROMIUM
# line to add is printed, never written.
install_chromium() {
	[ "$OS" = Darwin ] || die "install-chromium fetches a macOS build. Here: $OS — install Chromium with the system's package manager."
	local arch base root rev tmp app
	case $(uname -m) in arm64) arch=Mac_Arm ;; *) arch=Mac ;; esac
	base=https://commondatastorage.googleapis.com/chromium-browser-snapshots/$arch
	root="$HOME/Library/Application Support/agent-browser/chromium"
	rev=$(curl -fsSL "$base/LAST_CHANGE") || die "cannot read $base/LAST_CHANGE (network?) — retry, or brew install --cask chromium"
	case $rev in '' | *[!0-9]*) die "$base/LAST_CHANGE answered '$rev', not a revision — retry later" ;; esac
	mkdir -p "$root"
	tmp=$(mktemp -d "$root/.download.XXXXXX")
	echo "→ Chromium snapshot $rev ($arch) into $root"
	if ! curl -fL --progress-bar -o "$tmp/chrome-mac.zip" "$base/$rev/chrome-mac.zip" || ! unzip -q "$tmp/chrome-mac.zip" -d "$tmp"; then
		rm -rf "$tmp"
		die "download or unzip of $base/$rev/chrome-mac.zip failed (above) — retry, or brew install --cask chromium"
	fi
	app="$tmp/chrome-mac/Chromium.app"
	[ -x "$app/Contents/MacOS/Chromium" ] || { rm -rf "$tmp"; die "the zip holds no chrome-mac/Chromium.app — brew install --cask chromium instead"; }
	rm -rf "$root/Chromium.app"
	mv "$app" "$root/Chromium.app"
	rm -rf "$tmp"
	xattr -dr com.apple.quarantine "$root/Chromium.app" 2>/dev/null || true
	printf '%s\n' "$rev" >"$root/REVISION"
	echo "✓ Chromium $rev — $root/Chromium.app"
	echo "  add this line to .devcontainer/.env, then: $0 install"
	echo "  AGENT_BROWSER_CHROMIUM=\"$root/Chromium.app/Contents/MacOS/Chromium\""
}

verb=${1:-status}
[ $# -gt 0 ] && shift
# --port / --cdp-port <n> : install or run ONE instance on these ports instead of
# the .env's. The supervisor announces the proxy port in the channel (host/port),
# so the container follows without an .env edit ; the firewall still has to open it.
# --visible : install or run with a real window on every start (AGENT_BROWSER_WINDOW=1
# for this install, no .env edit) ; a later install without it is headless again.
OPT_PROXY_PORT='' OPT_CDP_PORT='' OPT_TEMP='' args=''
while [ $# -gt 0 ]; do
	case $1 in
		--temp)
			[ "$verb" = run ] || die "--temp goes with run: $0 run c --temp"
			OPT_TEMP=1
			shift ;;
		--visible)
			case $verb in install | run) ;; *) die "--visible goes with install or run (start keeps what install wrote)" ;; esac
			WINDOW=1
			shift ;;
		--port | --cdp-port)
			case ${2:-} in [1-9][0-9][0-9][0-9] | [1-9][0-9][0-9][0-9][0-9]) ;; *) die "$1 ${2:-}: a port, 1000 to 65535" ;; esac
			[ "$2" -le 65535 ] || die "$1 $2: a port, 1000 to 65535"
			case $verb in install | run) ;; *) die "$1 goes with install or run (another verb reads the port install wrote)" ;; esac
			if [ "$1" = --port ]; then OPT_PROXY_PORT=$2; else OPT_CDP_PORT=$2; fi
			shift 2 ;;
		*) args="$args $1"; shift ;;
	esac
done
# shellcheck disable=SC2086 # letters and --all, word-split on purpose
set -- $args
if [ -n "$OPT_PROXY_PORT$OPT_CDP_PORT" ] && { [ $# -gt 1 ] || [ "${1:-}" = --all ]; }; then
	die "--port / --cdp-port set the ports of ONE instance — e.g. $0 install b --port 55440"
fi
case $verb in
	install)
		if [ "${1:-}" = --all ]; then list=$(discovered); else list=${*:-a}; fi
		for i in $list; do instance "$i"; echo "== instance $i ($LABEL)"; install; done ;;
	start)
		for i in ${*:-a}; do instance "$i"; echo "== instance $i ($LABEL)"; start; done ;;
	stop)
		list=${*:-$(installed)}
		[ -n "$list" ] || die "nothing of $PROJECT is installed — $0 install"
		for i in $list; do instance "$i"; stop; done ;;
	list)
		case ${1:-} in '' | --json) list "${1:-}" ;; *) die "list takes --json or nothing (it lists every instance)" ;; esac ;;
	install-chromium) install_chromium ;;
	uninstall)
		list=${*:-$(installed)}
		[ -n "$list" ] || { instance a; uninstall; exit 0; }
		for i in $list; do instance "$i"; uninstall; done ;;
	status)
		list=${*:-$(installed)}
		for i in ${list:-a}; do instance "$i"; echo "== instance $i ($LABEL)"; status; done ;;
	logs) instance "${1:-a}"; logs ;;
	run)
		[ -z "$OPT_TEMP" ] || [ $# -eq 1 ] || die "--temp names its instance: $0 run c --temp"
		instance "${1:-a}"; run ;;
	instances) instances ;;
	*) die "usage: host-agent.sh {install|start|stop|uninstall|status} [instance…] | install --all | install <i> --port <n> [--cdp-port <n>] | install [--visible] | {logs|run} [instance] | list [--json] | instances | install-chromium" ;;
esac
