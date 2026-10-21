#!/usr/bin/env bash
# host-supervisor.sh — the host's agent browser, kept by launchd on a Mac
# (host-agent.sh install) or run in a terminal elsewhere (host-agent.sh run).
# It runs from the copy that install makes outside the repository — nothing
# the container writes may run on the host. The channel is files in
# $AGENT_BROWSER_CTL (.devcontainer/tmp/agent-browser/host/ on the bind mount):
#
#   cmd        written by `agent-browser` in the container : "<nonce> up <url>" | "<nonce> restart" | "<nonce> down" | "<nonce> stats"
#   state      written here : "<nonce> <running|stopped|idle> <pid> <url>"
#   stats      written here on `stats` : "<epoch> <cpu ticks> <rss kB> <processes>" (RSS: macOS has no PSS)
#   heartbeat  written here every second : an epoch. `agent-browser` sends to the
#              host while it is under 5 s old, to the sidecar otherwise.
#   flags      optional, read per start — only --disable-frame-rate-limit,
#              --disable-gpu-vsync and --window-size=W,H ; any other word is
#              dropped and logged.
#
# That directory is the container's too, so it holds data only, read as such:
#   - a symlink in it is never read nor written through (it could point at any
#     file of the host) — writes go to a fresh temp file renamed into place;
#   - the nonce must be digits, the URL on an allowed origin (cdp-proxy.mjs
#     check-url) and passed after `--`, never as a Chromium switch; a refused
#     URL is not echoed back into `state`;
#   - logs go to $AGENT_BROWSER_LOGDIR, out of the container's reach.
#
# Idle, it only polls: Chromium and its DevTools proxy start on `up` and stop
# on `down` — and this loop stops them too when the container has gone quiet
# (idle_too_long). Chromium is restarted if it dies while the wanted state is
# up, three times at most when it dies right at start.
# Bash 3.2 (the Mac's): no associative arrays, no ${x,,}, no mapfile.
set -uf
HOST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE=${AGENT_BROWSER_PROFILE:?set by host-agent.sh (install or run)}
LOGDIR=${AGENT_BROWSER_LOGDIR:?set by host-agent.sh (install or run)}
CTL=${AGENT_BROWSER_CTL:?set by host-agent.sh (install or run)}
: "${AGENT_BROWSER_ORIGINS:?set by host-agent.sh from .devcontainer/.env}"
export AGENT_BROWSER_ORIGINS AGENT_BROWSER_REACH
# shellcheck source=chromium-flags.sh
. "$HOST_DIR/chromium-flags.sh"
pid='' proxy_pid='' url='' wanted=down nonce=- now=idle started=0 quick_exits=0

log() {
	echo "$(date '+%Y-%m-%dT%H:%M:%S') [host-supervisor] $*"
}

# A control file's content, or nothing when it is missing or not a plain file.
get() {
	[ -f "$CTL/$1" ] && [ ! -L "$CTL/$1" ] && cat "$CTL/$1" 2>/dev/null
}

# Write a control file without ever following a link the container left there.
put() {
	local tmp
	[ -L "$CTL" ] && return 1
	tmp=$(mktemp "$CTL/.put.XXXXXX") || return 1
	printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$CTL/$1"
}

# The one origin grammar: cdp-proxy.mjs decides, never a regex of our own.
allowed_url() {
	[ -n "$1" ] && "$NODE" "$HOST_DIR/cdp-proxy.mjs" check-url "$1" 2>/dev/null
}

start() {
	if ! allowed_url "$url"; then
		log "refused up: $url is not on an allowed origin ($AGENT_BROWSER_ORIGINS)"
		return 1
	fi
	ab_find_chromium
	if [ -z "$AB_CHROMIUM" ]; then
		log "Chromium not found — brew install --cask chromium (or AGENT_BROWSER_CHROMIUM=/path in .devcontainer/.env)"
		return 1
	fi
	# Another Chromium on this profile holds its SingletonLock, "<host>-<pid>":
	# ours would abort at once, every time. A stale lock (dead pid) Chromium
	# takes over by itself.
	local holder
	holder=$(readlink "$PROFILE/SingletonLock" 2>/dev/null)
	holder=${holder##*-}
	if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
		log "refused up: Chromium $holder already runs on $PROFILE — stop it first"
		return 1
	fi
	ab_prefs
	ab_flags || { log "refused up: the origin list is unusable"; return 1; }
	extra_flags
	# DevTools on the loopback only: the container gets the proxy.
	"$AB_CHROMIUM" "${AB_FLAGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} \
		--remote-debugging-address=127.0.0.1 --remote-debugging-port="$AB_CDP_PORT" \
		-- "$url" >>"$LOGDIR/chromium.log" 2>&1 &
	pid=$!
	started=$(date +%s)
	"$NODE" "$HOST_DIR/cdp-proxy.mjs" serve --listen "$AB_PROXY_BIND:$AB_PROXY_PORT" --upstream "127.0.0.1:$AB_CDP_PORT" >>"$LOGDIR/cdp-proxy.log" 2>&1 &
	proxy_pid=$!
	log "up: Chromium $pid on $url ($AB_SIZE), proxy $proxy_pid on $AB_PROXY_BIND:$AB_PROXY_PORT"
}

# The bench's switches from $CTL/flags, and nothing else.
extra_flags() {
	local w
	EXTRA=()
	# shellcheck disable=SC2013 # word by word on purpose
	for w in $(get flags); do
		case "$w" in
			--disable-frame-rate-limit | --disable-gpu-vsync) EXTRA+=("$w") ;;
			*)
				if echo "$w" | grep -Eq '^--window-size=[0-9]{2,4},[0-9]{2,4}$'; then
					EXTRA+=("$w")
				else
					log "flags: dropped $w"
				fi ;;
		esac
	done
}

alive() {
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# The container's command touches `activity` on every call ; `hold` carries an
# epoch until which the browser must stay up whatever happens. No activity for
# IDLE_S and no hold → Chromium off, even if the container was stopped or
# rebuilt meanwhile.
IDLE_S=${AGENT_BROWSER_IDLE_S:-360}
idle_too_long() {
	local f=$CTL/../activity t hold
	t=$started
	if [ -f "$f" ] && [ ! -L "$f" ]; then
		if [ "$(uname -s)" = Darwin ]; then t=$(stat -f %m "$f"); else t=$(stat -c %Y "$f"); fi
		[ "$t" -lt "$started" ] && t=$started
	fi
	f=$CTL/../hold
	if [ -f "$f" ] && [ ! -L "$f" ]; then
		hold=$(head -c 12 "$f" 2>/dev/null)
		case $hold in '' | *[!0-9]*) hold=0 ;; esac
		[ "$hold" -gt "$(date +%s)" ] && return 1
	fi
	[ $(($(date +%s) - t)) -ge "$IDLE_S" ]
}

stop() {
	local p
	for p in $pid $proxy_pid; do
		kill "$p" 2>/dev/null
	done
	for p in $pid $proxy_pid; do
		wait "$p" 2>/dev/null
	done
	[ -n "$pid" ] && log "down"
	pid='' proxy_pid=''
}

state() {
	local shown=-
	now=$1
	allowed_url "$url" && shown=$url
	put state "$nonce $1 ${pid:--} $shown"
}

# CPU time (as 1/100 s ticks, like the sidecar's) and RSS of Chromium and its
# helpers — the processes whose command line carries this profile.
stats() {
	local ticks=0 rss=0 n=0 t r cmd s
	while read -r t r cmd; do
		case "$cmd" in
			*"$PROFILE"*) ;;
			*) continue ;;
		esac
		# cputime: [[dd-]hh:]mm:ss.cc (macOS) or [[dd-]hh:]mm:ss (Linux)
		s=$(echo "$t" | awk -F'[-:.]' '{ n = NF; c = ($0 ~ /\./) ? $n : 0; if ($0 ~ /\./) n--; sec = $n; m = $(n-1); h = (n > 2) ? $(n-2) : 0; d = (n > 3) ? $(n-3) : 0; print (((d * 24 + h) * 60 + m) * 60 + sec) * 100 + c }')
		ticks=$((ticks + s))
		rss=$((rss + r))
		n=$((n + 1))
	done <<EOF_PS
$(ps -A -o time=,rss=,command=)
EOF_PS
	put stats "$(date +%s) $ticks $rss $n"
}

mkdir -p "$LOGDIR"
[ -d "$CTL" ] && [ ! -L "$CTL" ] || { log "$CTL is not a plain directory — refusing"; sleep 30; exit 1; }
trap 'stop; state stopped; [ -L "$CTL/heartbeat" ] || rm -f "$CTL/heartbeat"; exit 0' TERM INT
seen=$(get cmd || true)
state idle
log "polling $CTL (origins: $AGENT_BROWSER_ORIGINS)"
while :; do
	put heartbeat "$(date +%s)"
	cmd=$(get cmd || true)
	if [ "$cmd" != "$seen" ]; then
		seen=$cmd
		# shellcheck disable=SC2086 # word-split on purpose: nonce verb [url] (set -f: no globbing)
		set -- $cmd
		case ${1:-} in
			'' | *[!0-9]*) log "ignored a cmd without a numeric nonce"; set -- - ignored ;;
		esac
		nonce=${1:--}
		case ${2:-} in
			up)
				stop
				url=${3:-}
				wanted=up
				if start; then state running; else wanted=down; state stopped; fi ;;
			restart)
				stop
				if [ "$wanted" = up ] && start; then state running; else state stopped; fi ;;
			down)
				stop
				wanted=down
				state stopped ;;
			stats)
				stats
				state "$now" ;;
		esac
	fi
	if [ "$wanted" = up ] && alive && idle_too_long; then
		log "no activity from the container for ${IDLE_S}s — Chromium off"
		stop
		wanted=down
		state stopped
	fi
	if [ "$wanted" = up ] && ! alive; then
		# Three deaths within 10 s of their start: it will not come up by itself.
		if [ $(($(date +%s) - started)) -lt 10 ]; then quick_exits=$((quick_exits + 1)); else quick_exits=0; fi
		stop
		if [ "$quick_exits" -ge 3 ]; then
			log "Chromium dies at start — giving up, see chromium.log"
			quick_exits=0 wanted=down
			state stopped
		else
			log "Chromium exited — restarting"
			sleep 2
			if start; then state running; else wanted=down; state stopped; fi
		fi
	fi
	sleep 1
done
