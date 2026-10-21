# The agent browser's sidecar — a headless Chromium on Mesa (software GL) that
# stands in when no host browser answers: correct pixels, not full speed, never
# used for frame-rate numbers. Driven by `agent-browser` in the devcontainer
# through the same file channel as the host's (supervisor.sh).
#
# Runs in `app`'s network namespace (agent-browser.yml: network_mode:
# service:app), so localhost is the devcontainer's localhost and app's firewall
# filters every packet it sends. Built by the HOST's compose, outside the
# container firewall — the apt fetch below happens there.
FROM debian:bookworm-slim

# chromium from the Debian archive (bookworm-security tracks upstream stable).
# No chromium-sandbox: Chromium runs --no-sandbox (supervisor.sh) and the
# compose file isolates the container instead. openssl hashes an optional dev
# cert's key for the one-cert trust flag. Mesa's llvmpipe (EGL/GL) and
# lavapipe (Vulkan) are the software GL backends.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		chromium \
		libegl1 \
		libgl1-mesa-dri \
		mesa-vulkan-drivers \
		openssl \
		ca-certificates \
		fonts-dejavu-core \
		fonts-liberation \
	&& rm -rf /var/lib/apt/lists/* \
	&& chromium --version

# uid 1000 = `node` in app: app's firewall applies the very same per-uid rules
# (DNS only through dnsmasq) to this browser.
RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin chromium

COPY supervisor.sh /usr/local/bin/agent-browser-supervisor
USER chromium
ENTRYPOINT ["/usr/local/bin/agent-browser-supervisor"]
