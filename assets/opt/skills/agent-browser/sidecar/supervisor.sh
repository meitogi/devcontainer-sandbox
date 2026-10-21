#!/bin/sh
# agent-browser sidecar supervisor — keeps one headless Chromium on the URL
# `app` asks for. There is no docker socket in `app`, so the channel is files
# on a shared bind mount (/ctl = .devcontainer/tmp/agent-browser/), the same
# shape as the host supervisor's:
#
#   cmd        written by `agent-browser` : "<nonce> up <url>" | "<nonce> restart" | "<nonce> down" | "<nonce> stats"
#   state      written here : "<nonce> <running|stopped|idle> <pid> <url>"
#   stats      written here on `stats` : "<epoch.ns> <cpu ticks> <pss kB> <processes>"
#   heartbeat  written here every second : an epoch — `agent-browser` routes
#              to the host while ITS heartbeat is fresh, here otherwise
#   flags      optional, read per start, appended last (they override)
#
# Polled, not inotify: the bind mount crosses the Docker Desktop VM boundary,
# where inotify events from the other side never arrive.
#
# No origin check here: this browser lives in a cap-dropped container with no
# host disk to protect, and what it may reach is already filtered by app's
# firewall. A cmd file left from before this container started is ignored —
# nothing loads until `agent-browser up` runs again, by which time app's
# firewall is up. Chromium is restarted if it dies while the wanted state is up.
set -u
CTL=${AGENT_BROWSER_CTL:-/ctl}
PROFILE=$HOME/profile
CDP_PORT=${AGENT_BROWSER_CDP_PORT:-9323}
SIZE=${AGENT_BROWSER_SIZE:-1280,800}
CHROMIUM=${AGENT_BROWSER_CHROMIUM:-chromium}
pid='' url='' wanted=down nonce=- now=idle

# Trust exactly a dev cert's key when one is mounted — never the blanket
# --ignore-certificate-errors.
spki_flag() {
	[ -r /certs/dev.crt ] || return 0
	printf -- '--ignore-certificate-errors-spki-list=%s' "$(openssl x509 -in /certs/dev.crt -pubkey -noout \
		| openssl pkey -pubin -outform der \
		| openssl dgst -sha256 -binary | base64)"
}

audio_flag() {
	[ "${AGENT_BROWSER_AUDIO:-off}" = on ] || printf -- '--mute-audio'
}

start() {
	# --no-sandbox: Chromium's sandbox needs PID / network namespaces, which
	# Docker denies without CAP_SYS_ADMIN. The container is the boundary
	# instead (cap_drop ALL, no-new-privileges, uid 1000), and the page is the
	# project's own on an allowed origin.
	# --use-angle=gl-egl: Mesa's llvmpipe — half SwiftShader's CPU per frame at
	# the same picture.
	# --remote-debugging-port: on the loopback of app's namespace — the
	# container reaches it directly, no proxy needed here.
	# --disable-features=WebRtcHideLocalIpsWithMdns: WebRTC host candidates as
	# addresses, not mDNS names nothing in this container resolves.
	# $CTL/flags adds flags without rebuilding this image ; read per start.
	# They come last so they override: Chromium keeps the last value of a
	# repeated switch (--use-angle, --window-size).
	# shellcheck disable=SC2046 # word-split on purpose: one flag per word
	"$CHROMIUM" --headless=new --no-sandbox --no-first-run --no-default-browser-check \
		--remote-debugging-address=127.0.0.1 --remote-debugging-port="$CDP_PORT" \
		--user-data-dir="$PROFILE" --window-size="$SIZE" --force-device-scale-factor=1 \
		--use-angle=gl-egl --ignore-gpu-blocklist \
		--disable-background-timer-throttling --disable-renderer-backgrounding \
		--disable-backgrounding-occluded-windows \
		--disable-background-networking --disable-component-update --disable-sync \
		--no-pings --disable-features=WebRtcHideLocalIpsWithMdns $(audio_flag) $(spki_flag) \
		$(cat "$CTL/flags" 2>/dev/null) \
		-- "$url" >>"$CTL/chromium.log" 2>&1 &
	pid=$!
}

# A zombie still answers kill -0, so read the process state instead.
alive() {
	[ -n "$pid" ] && [ -r "/proc/$pid/stat" ] && ! grep -q '^[0-9]* ([^)]*) Z' "/proc/$pid/stat"
}

stop() {
	if alive; then
		kill "$pid"
		wait "$pid" 2>/dev/null
	fi
	pid=''
}

# Write a control file through a fresh temp file, never through a link.
put() {
	tmp=$(mktemp "$CTL/.put.XXXXXX") || return 1
	printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$CTL/$1"
}

state() {
	now=$1
	put state "$nonce $1 ${pid:--} ${url:--}"
}

# CPU (utime + stime, in clock ticks) and PSS summed over every process of this
# container — `app` cannot see these PIDs. Exited processes drop out of the sum.
stats() {
	ticks=0 pss=0 n=0
	for d in /proc/[0-9]*; do
		{ read -r st <"$d/stat"; } 2>/dev/null || continue
		# shellcheck disable=SC2086 # word-split on purpose: fields after "(comm) "
		set -- ${st##*) }
		ticks=$((ticks + ${12} + ${13}))
		kb=$(awk '/^Pss:/ { print $2 }' "$d/smaps_rollup" 2>/dev/null)
		pss=$((pss + ${kb:-0}))
		n=$((n + 1))
	done
	put stats "$(date +%s.%N) $ticks $pss $n"
}

trap 'stop; state stopped; rm -f "$CTL/heartbeat"; exit 0' TERM INT

seen=$(cat "$CTL/cmd" 2>/dev/null || true)
state idle
while :; do
	put heartbeat "$(date +%s)"
	cmd=$(cat "$CTL/cmd" 2>/dev/null || true)
	if [ "$cmd" != "$seen" ]; then
		seen=$cmd
		# shellcheck disable=SC2086 # word-split on purpose: nonce verb [url]
		set -- $cmd
		nonce=${1:--}
		case ${2:-} in
			up)
				stop
				url=${3:-}
				wanted=up
				start
				state running ;;
			restart)
				stop
				if [ "$wanted" = up ]; then
					start
					state running
				else
					state stopped
				fi ;;
			down)
				stop
				wanted=down
				state stopped ;;
			stats)
				stats
				state "$now" ;;
		esac
	fi
	if [ "$wanted" = up ] && ! alive; then
		echo "[supervisor] $(date -Iseconds) chromium exited — restarting" >>"$CTL/chromium.log"
		sleep 2
		start
		state running
	fi
	sleep 1
done
