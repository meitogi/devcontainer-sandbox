# chromium-flags.sh — the agent Chromium on the host: where it is, how it runs.
# Sourced by host-supervisor.sh with HOST_DIR (this folder), PROFILE and the
# AGENT_BROWSER_* configuration in the environment (the launchd plist that
# `host-agent.sh install` writes, or `host-agent.sh run`). Bash 3.2: the Mac's.
#
# What the browser may reach is the project's AGENT_BROWSER_ORIGINS (+ _REACH),
# held at three levels, all generated from that one list by cdp-proxy.mjs:
#   - the PAC: allowed origins and reach hosts DIRECT, everything else to a
#     proxy that does not exist;
#   - --host-resolver-rules: every other name fails to resolve (covers what a
#     PAC does not: WebRTC, prefetch);
#   - DevTools on the loopback only (AGENT_BROWSER_CDP_PORT), the container
#     reaching it through cdp-proxy.mjs (AGENT_BROWSER_PROXY_PORT), which
#     refuses what touches the host's disk or another origin.

AB_SIZE=${AGENT_BROWSER_SIZE:-1280,800}
AB_CDP_PORT=${AGENT_BROWSER_CDP_PORT:-9323}
AB_PROXY_PORT=${AGENT_BROWSER_PROXY_PORT:-9223}
# 127.0.0.1 is what Docker Desktop (macOS, Windows) reaches as host.docker.internal.
# A Linux Docker Engine reaches the docker0 address instead — see the TODO in
# the skill: AGENT_BROWSER_PROXY_BIND=0.0.0.0 (or that address) there.
AB_PROXY_BIND=${AGENT_BROWSER_PROXY_BIND:-127.0.0.1}
AB_CERT=${AGENT_BROWSER_CERT:-}
NODE=${NODE:-node}

# Chromium or Chrome, wherever it lives: an explicit path, the known places,
# the Linux PATH names, then Spotlight on a Mac. Sets AB_CHROMIUM, empty when none.
ab_find_chromium() {
	AB_CHROMIUM=""
	local app
	for app in "${AGENT_BROWSER_CHROMIUM:-}" \
		"/Applications/Chromium.app/Contents/MacOS/Chromium" \
		"${HOME}/Applications/Chromium.app/Contents/MacOS/Chromium" \
		"${HOME}"/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium \
		"${HOME}"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome \
		"$(command -v chromium 2>/dev/null)" \
		"$(command -v chromium-browser 2>/dev/null)" \
		"$(command -v google-chrome 2>/dev/null)" \
		"$(command -v google-chrome-stable 2>/dev/null)"; do
		if [ -z "$AB_CHROMIUM" ] && [ -n "$app" ] && [ -x "$app" ]; then AB_CHROMIUM="$app"; fi
	done
	if [ -z "$AB_CHROMIUM" ] && command -v mdfind >/dev/null 2>&1; then
		while IFS= read -r app; do
			if [ -z "$AB_CHROMIUM" ] && [ -x "$app/Contents/MacOS/Chromium" ]; then AB_CHROMIUM="$app/Contents/MacOS/Chromium"; fi
		done <<EOF_MD
$(mdfind "kMDItemCFBundleIdentifier == 'org.chromium.Chromium'" 2>/dev/null || true)
EOF_MD
	fi
}

# Trust exactly the dev cert's key — never the blanket --ignore-certificate-errors.
ab_spki() {
	openssl x509 -in "$AB_CERT" -pubkey -noout \
		| openssl pkey -pubin -outform der \
		| openssl dgst -sha256 -binary | base64
}

# Downloads stay inside the profile, never in ~/Downloads.
ab_prefs() {
	mkdir -p "$PROFILE/Default" "$PROFILE/downloads"
	if [ ! -f "$PROFILE/Default/Preferences" ]; then
		printf '{"download":{"default_directory":"%s","prompt_for_download":false},"savefile":{"default_directory":"%s"}}\n' \
			"$PROFILE/downloads" "$PROFILE/downloads" >"$PROFILE/Default/Preferences"
	fi
}

# The flags, in AB_FLAGS. The window size is in CSS pixels at scale 1: 1280x800
# is a 1280x657 canvas, not Retina's 2560x1426. Headless (the default) runs on
# the GPU too — Metal on a Mac ; AGENT_BROWSER_WINDOW=1 opens a real window.
# Returns 1 when the origin list is unusable (the proxy says why on stderr).
ab_flags() {
	local pac rules
	pac=$("$NODE" "$HOST_DIR/cdp-proxy.mjs" pac) || return 1
	rules=$("$NODE" "$HOST_DIR/cdp-proxy.mjs" resolver-rules) || return 1
	AB_FLAGS=(
		--user-data-dir="$PROFILE"
		--no-first-run
		--no-default-browser-check
		--window-size="$AB_SIZE"
		--force-device-scale-factor=1
		--disable-renderer-backgrounding
		--disable-background-timer-throttling
		--disable-backgrounding-occluded-windows
		--disable-background-networking
		--disable-component-update
		--disable-sync
		--no-pings
		# A data: URL — Chromium no longer takes a file:// PAC. <-loopback> sends
		# localhost through the list too (otherwise always direct).
		--proxy-pac-url="data:application/x-ns-proxy-autoconfig;base64,$(printf '%s' "$pac" | base64 | tr -d '\n')"
		--proxy-bypass-list="<-loopback>"
		--host-resolver-rules="$rules"
	)
	if [ "${AGENT_BROWSER_AUDIO:-off}" != on ]; then
		AB_FLAGS+=(--mute-audio)
	fi
	if [ -n "$AB_CERT" ]; then
		AB_FLAGS+=(--ignore-certificate-errors-spki-list="$(ab_spki)")
	fi
	if [ "${AGENT_BROWSER_WINDOW:-0}" != 1 ]; then
		AB_FLAGS+=(--headless=new)
		[ "$(uname -s)" = Darwin ] && AB_FLAGS+=(--use-angle=metal)
	fi
	return 0
}
