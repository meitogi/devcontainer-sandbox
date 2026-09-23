# -----------------------------------------------
# @meitogi/devcontainer-sandbox — published base image
#   ghcr.io/meitogi/devcontainer-sandbox:<base-version>-cc<cc-version>
#
# One image, Node 24, self-sufficient. Non-Node stacks (PHP, Android,
# Capacitor) derive from it in a project Dockerfile — see stacks/*.md.
# Built and published by .github/workflows/publish.yml, one image per
# Claude Code version listed in cc-versions.json.
#
# Layout contract (consumed by project containers) :
#   /usr/local/bin/            — bin/ (dispatcher, firewall toolchain)
#   /opt/devcontainer/base/    — assets/opt/ (hooks, skills, knowledge, zshrc)
#   /etc/devcontainer-firewall — assets/etc-firewall/ (bake inputs, root-only)
# -----------------------------------------------
FROM node:24-bookworm-slim

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=2.1.280
ARG GIT_DELTA_VERSION=0.18.2
# Which VS Code extension patches to bake: `all`, `none`, a comma-separated
# list of categories (ux, fix, notify) and/or patch names. Applied at build —
# the ENV of the same name set after RUN 2 is for introspection only; changing
# it at runtime patches nothing, `restore-ext-patches` is what acts.
#
# The default is `none`, and this image ships NO patcher: it installs the
# Claude Code extension exactly as published and leaves it that way. The
# vocabulary stays because an extending image can add its own patchers (see
# EXTENDING.md), and because `restore-ext-patches` speaks it at runtime — with
# an empty patch directory, `all` and `none` mean the same thing here.
ARG CLAUDE_CODE_EXT_PATCHS=none
# -----------------------------------------------
# System tools + targeted build deps (sharp / bcrypt / node-gyp) + locale purge
# -----------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
  # runtime essentials
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  dnsmasq \
  aggregate \
  jq \
  nano \
  vim \
  python3 \
  python3-yaml \
  rsync \
  ca-certificates \
  netcat-openbsd \
  curl \
  wget \
  # getcap — escalation.sh takes the file-capability inventory with it. It
  # arrived transitively before; pinned explicitly so the assertion cannot
  # silently lose its tool and report an empty surface it never measured.
  libcap2-bin \
  # build tools for npm postinstalls (sharp, bcrypt, node-gyp)
  build-essential \
  libssl-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  # Purge locales (keep en/en_US/C), man and doc — saves ~175 MB
  && find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
       ! -name 'en' ! -name 'en_US' ! -name 'C' -exec rm -rf {} + \
  && rm -rf /usr/share/man/* /usr/share/doc/* \
  && systemctl disable dnsmasq 2>/dev/null || true

# -----------------------------------------------
# mitmproxy — standalone binary baked at build time. Avoids the runtime
# venv + pip install path (saves ~220 MB on the per-container volume
# and makes first-boot instant). Versioned via MITM_VERSION below.
#
# `node` joins the `adm` group here so it can read mitmproxy's logs
# under /var/log/mitmproxy{,-writes,-blocks}.log (mode 640, owner
# mitmproxy:adm). Set before the firewall RUN block so the GID is in
# place when init-firewall.sh runs.
# -----------------------------------------------
ARG MITM_VERSION=12.2.3
RUN useradd --system --no-create-home --shell /usr/sbin/nologin mitmproxy && \
    usermod -aG adm node && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) PKG="mitmproxy-${MITM_VERSION}-linux-x86_64.tar.gz" ;; \
      arm64) PKG="mitmproxy-${MITM_VERSION}-linux-aarch64.tar.gz" ;; \
      *) echo "Unsupported arch: $ARCH"; exit 1 ;; \
    esac && \
    mkdir -p /opt/mitmproxy && \
    # Download to a file, then extract — not curl|tar. Under QEMU (the
    # cross-arch leg of the buildx matrix) the piped form can hand tar a
    # truncated stream with no usable error; a file download retries on
    # transient failures and leaves curl's own error visible when it dies.
    curl -fSL --retry 3 --retry-all-errors -o /tmp/mitmproxy.tgz \
      "https://downloads.mitmproxy.org/${MITM_VERSION}/${PKG}" && \
    tar -xzf /tmp/mitmproxy.tgz -C /opt/mitmproxy && \
    rm /tmp/mitmproxy.tgz && \
    chmod +x /opt/mitmproxy/mitmdump /opt/mitmproxy/mitmproxy /opt/mitmproxy/mitmweb && \
    ln -s /opt/mitmproxy/mitmdump /usr/local/bin/mitmdump

# GitHub CLI — install from official repo for latest version (CVE-2024-53858 fix requires >= 2.63.0)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------
# wtf (blunt1337/wtfcmd) — single-binary task runner driven by a
# `.wtfcmd.yaml` checked into the project. Replaces shell aliases /
# Makefile shortcuts with a discoverable `wtf <task>` UX.
#
# No SHA pin (upstream does not publish a SHA256SUMS file) — same
# pattern as mitmproxy / git-delta above : HTTPS + repo integrity.
#
# WTF_VERSION accepts :
#   "latest"  — default ; resolves via GitHub /releases/latest/download/
#   "1.2.1"   — or any exact version, for reproducible builds
# Override at build time : docker build --build-arg WTF_VERSION=1.2.1 ...
# -----------------------------------------------
ARG WTF_VERSION=latest

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) asset=wtf-amd.linux ;; \
      arm64) asset=wtf-arm.linux ;; \
      *) echo "wtfcmd: unsupported arch ${arch}" >&2; exit 1 ;; \
    esac; \
    case "${WTF_VERSION}" in \
      latest) url="https://github.com/blunt1337/wtfcmd/releases/latest/download/${asset}" ;; \
      *)      url="https://github.com/blunt1337/wtfcmd/releases/download/v${WTF_VERSION}/${asset}" ;; \
    esac; \
    curl -fsSL --retry 3 -o /usr/local/bin/wtf "${url}"; \
    chmod 0755 /usr/local/bin/wtf; \
    wtf --help >/dev/null

# -----------------------------------------------
# User setup (node already exists in node:24-bookworm-slim)
# -----------------------------------------------
ENV USERNAME=node
ENV HOME=/home/$USERNAME

RUN mkdir -p $HOME/.zsh $HOME/.cache/zsh /workspace \
    $HOME/.claude $HOME/.claude-creds && \
    touch $HOME/.zsh_history && \
    chown -R $USERNAME:$USERNAME $HOME /workspace

WORKDIR /workspace

# -----------------------------------------------
# git-delta — syntax-highlighted pager for `git diff`, `git log -p`,
# `git show`. Devcontainer git workflows (reviewing changes, hunting
# regressions, navigating PR context) lean heavily on these commands,
# and the default less-based pager is unreadable for non-trivial diffs.
# Installed via upstream .deb (apt has 0.13.x — too old for syntax
# config we use). Multi-arch via dpkg --print-architecture.
# -----------------------------------------------
RUN ARCH=$(dpkg --print-architecture) && \
    wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# -----------------------------------------------
# Claude — VSIX baked at build time + native-binary symlink for the CLI.
# Single ARG (CLAUDE_CODE_VERSION) drives both the baked VS Code extension
# AND the npm-fallback CLI install. Marketplace download runs during
# `docker build` on the host — out of the runtime firewall scope.
#
# Layout — 6 RUN blocks sorted by weight, for granular cache invalidation :
#   RUN 0 (light)  : compute ARCH/VP/EXT_DIR/BIN/REL → /etc/claude-build-env.
#                    Single source of truth ; each subsequent RUN sources it
#                    instead of re-running `dpkg --print-architecture` + case.
#   RUN 1 (HEAVY)  : DL + unzip + `cp -a` VSIX (~243 MB) + `chown -R`.
#                    The `chown -R` MUST stay paired with `cp -a` here —
#                    splitting it would duplicate the 243 MB tree in a
#                    second layer (Docker records inode metadata changes
#                    as a full file copy in the layer diff).
#   COPY           : assets/vscode-ext-patchs/ — placed AFTER RUN 1 so a
#                    change to a patcher script doesn't re-invalidate the
#                    243 MB DL above.
#   RUN 2 (light)  : `bash vscode-ext-patchs/run-all.sh` (idempotent) +
#                    targeted `chown` on the files patchers rewrite
#                    (package.json, extension.js). A full `chown -R` on
#                    $EXT_DIR would copy-up the 243 MB tree into this layer
#                    via overlayfs SETATTR semantics, defeating the split.
#   RUN 3 (light)  : decide CLI source — symlink the extension's native
#                    binary if it works, otherwise mark `/etc/claude-source`
#                    as `npm-fallback (...)` for RUN 4 to act on.
#   RUN 4 (HEAVY?) : conditional `npm install` (no-op when the symlink
#                    works — 0 byte added to the layer).
#   RUN 5 (light)  : write `extensions.json` so VS Code sees the baked ext.
#
# Failsafe chain — `docker build` NEVER fails on a Claude-side problem :
#   1. VSIX DL OK + binary symlink OK  → /usr/local/bin/claude is a symlink
#      into the extension's embedded native binary. No npm install
#      (~224 MB volume win).
#   2. VSIX DL OK + binary symlink KO  → extension is still baked (VS Code
#      sees it via extensions.json), CLI falls back to npm install +
#      sentinel banner.
#   3. VSIX DL KO                      → no extension baked, no
#      extensions.json written. npm install handles the CLI ; VS Code
#      installs the extension at runtime via the pin in devcontainer.json
#      (Marketplace is in the firewall allowlist).
#
# `/etc/claude-source` records which branch fired (consumed by post-start
# hooks + shell-init.sh banners).
#
# Local patches (RUN 2): assets/vscode-ext-patchs/ ships one .py per feature
# (icon-fix-open-in-current-panel, user-action-observer, …). Each is a
# generic regex-based patcher; on a Claude Code version bump that breaks
# its anchor, it prints a red banner and exits 1, but the orchestrator
# (run-all.sh) absorbs the failure and exits 0 — the container build stays
# green. The non-zero exit per .py is visible in build logs, so it's
# immediately obvious WHICH feature's regex broke.
# -----------------------------------------------

# RUN 0 — compute shared build env (light, ~150 bytes)
RUN set -eu ; \
    ARCH=$(dpkg --print-architecture) ; \
    case "$ARCH" in \
      amd64) VP=linux-x64   ;; \
      arm64) VP=linux-arm64 ;; \
      *) echo "Unsupported arch: $ARCH" >&2 ; exit 1 ;; \
    esac ; \
    EXT_DIR="${HOME}/.vscode-server/extensions/anthropic.claude-code-${CLAUDE_CODE_VERSION}-${VP}" ; \
    BIN="${EXT_DIR}/resources/native-binary/claude" ; \
    REL="anthropic.claude-code-${CLAUDE_CODE_VERSION}-${VP}" ; \
    printf 'VP=%s\nEXT_DIR=%s\nBIN=%s\nREL=%s\n' \
      "$VP" "$EXT_DIR" "$BIN" "$REL" \
      > /etc/claude-build-env ; \
    chmod 644 /etc/claude-build-env

# RUN 1 — DL + extract VSIX + chown -R (HEAVY, ~243 MB layer)
# `--compressed` advertises Accept-Encoding: gzip ; Marketplace responds
# with Content-Encoding: gzip on the VSIX (zip) stream — curl decompresses
# transparently, leaving the raw ZIP (PK\x03\x04 magic) on disk.
# This fetch retries, because the else branch below turns a network blip into
# a silently degraded image — one that builds green while carrying no
# extension, no pristine copies and no live patches.
# Measured 2026-08-17, 10 single attempts: 4 × 200, 3 × 503, 3 × connection
# failure. `--retry-all-errors` is required for that last third — plain
# `--retry` only covers 408/429/5xx and timeouts, so it would sit out exactly
# the connection-level failures observed here. Nine attempts at that rate
# leave a ~1 % chance of coming away empty-handed.
# Accepted cost: a wrong CLAUDE_CODE_VERSION pin answers 404 and is now
# retried too, so it takes ~24 s to fail instead of failing at once. That is
# noise against a 20-40 min release gate, and the failure stays just as loud.
# `cp -a`'s own exit status gates the success message: a disk/permission
# failure partway through the 243 MB copy (ENOSPC, a stale mount) used to
# leave $EXT_DIR present-but-incomplete while still printing the success
# line — the else branch below never fired, so nothing downstream (RUN 2's
# pristine-copy bake, RUN 3's binary check) could tell the difference from a
# clean bake. A failed copy now takes the same else branch as a failed
# download, just under its own marker.
RUN set -u ; \
    . /etc/claude-build-env ; \
    URL="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/${CLAUDE_CODE_VERSION}/vspackage?targetPlatform=${VP}" ; \
    mkdir -p "$EXT_DIR" ; \
    if curl -fsSL --compressed -A 'VSCode/devcontainer' \
            --retry 8 --retry-delay 3 --retry-all-errors --retry-max-time 180 \
            -o /tmp/claude.vsix "$URL" \
       && unzip -q /tmp/claude.vsix -d /tmp/claude-vsix \
       && [ -d /tmp/claude-vsix/extension ] ; then \
      if cp -a /tmp/claude-vsix/extension/. "$EXT_DIR/" ; then \
        echo "VSIX downloaded + extracted (${VP})" ; \
      else \
        echo "VSIX copy incomplete — partial ${EXT_DIR} discarded, runtime fallback via devcontainer.json pin" >&2 ; \
        rm -rf "$EXT_DIR" ; \
      fi ; \
    else \
      echo "VSIX download/extract failed — runtime fallback via devcontainer.json pin" >&2 ; \
      rm -rf "$EXT_DIR" ; \
    fi ; \
    rm -rf /tmp/claude.vsix /tmp/claude-vsix ; \
    chown -R node:node "${HOME}/.vscode-server"

# The toolkit, and only the toolkit: run-all.sh, _common.py, AUTHORING.md.
# No patcher ships in this image. Placed here (not earlier) so a change to it
# invalidates only RUN 2+ — RUN 1's 243 MB DL stays cached.
COPY assets/vscode-ext-patchs/ /usr/local/bin/vscode-ext-patchs/

# RUN 2 — apply patches (light, idempotent)
# run-all.sh runs the selected .py in vscode-ext-patchs/ ; each patcher absorbs
# its own failures (red banner + exit 1) without breaking the build. The one
# thing that DOES break the build is a selection naming something that does not
# exist (run-all.sh exits 2) — hence `|| exit $?` rather than `|| true`, which
# would turn a typo into a silently missing feature.
# PRISTINE_FILES is fixed, not derived. It used to be the union of the
# `# @patch-files:` headers of the patchers baked alongside — but this image
# ships none, so that union is empty and the bake would save nothing, leaving
# restore-ext-patches with nothing to replay from. These three are every file
# the extension has that anyone patches; a derived image adding a patcher for
# one of them is covered, and one reaching further declares its own backup.
# Targeted chown because `chown -R "$EXT_DIR"` would copy-up the 243 MB tree
# into this layer (overlayfs SETATTR semantics).
# The pristine copies are taken BEFORE any patch and regardless of the
# selection — they are what restore-ext-patches replays from, so a `none` build
# can still be brought back to life without a rebuild.
# PYTHONDONTWRITEBYTECODE : the patchers import _common (and each other), so
# CPython would drop a __pycache__/ next to the sources and ship compiled
# bytecode in the image. Removing it afterwards would not help — the files
# would still sit in this layer.
RUN set -u ; \
    export PYTHONDONTWRITEBYTECODE=1 ; \
    . /etc/claude-build-env ; \
    if [ -d "$EXT_DIR" ] ; then \
      FILES="package.json extension.js webview/index.js" ; \
      for f in $FILES ; do \
        [ -f "$EXT_DIR/$f" ] || continue ; \
        mkdir -p "/usr/local/share/claude-ext-orig/$(dirname "$f")" ; \
        cp "$EXT_DIR/$f" "/usr/local/share/claude-ext-orig/$f" ; \
        chmod 0444 "/usr/local/share/claude-ext-orig/$f" ; \
      done ; \
      bash /usr/local/bin/vscode-ext-patchs/run-all.sh "$EXT_DIR" || exit $? ; \
      for f in $FILES ; do \
        chown node:node "$EXT_DIR/$f" 2>/dev/null || true ; \
      done ; \
    else \
      echo "patch skipped: no $EXT_DIR (VSIX DL failed in RUN 1)" >&2 ; \
    fi

# Introspection only — what the image was built with. Runtime changes to it do
# nothing on their own; `restore-ext-patches` reads it as its default argument.
ENV CLAUDE_CODE_EXT_PATCHS="${CLAUDE_CODE_EXT_PATCHS}"

# The runtime counterpart of the ARG above: restores the pristine copies baked
# in RUN 2 and replays a selection, so consuming the published image is enough
# to change one's mind about the patches.
COPY bin/restore-ext-patches /usr/local/bin/restore-ext-patches
COPY bin/ext-patches-sync    /usr/local/bin/ext-patches-sync
COPY bin/ext-patches-update  /usr/local/bin/ext-patches-update

# RUN 3 — decide CLI source + write /etc/claude-source (light)
RUN set -u ; \
    . /etc/claude-build-env ; \
    EXT_BAKED=0 ; [ -d "$EXT_DIR" ] && EXT_BAKED=1 ; \
    SOURCE=npm-fallback ; \
    if [ "$EXT_BAKED" = "1" ] && [ -x "$BIN" ] ; then \
      ln -sf "$BIN" /usr/local/bin/claude ; \
      INSTALLED=$(/usr/local/bin/claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true) ; \
      if [ "$INSTALLED" = "$CLAUDE_CODE_VERSION" ] ; then \
        SOURCE="extension:${BIN}" ; \
      else \
        rm -f /usr/local/bin/claude ; \
        echo "claude-binary: version mismatch (got '$INSTALLED', want '$CLAUDE_CODE_VERSION')" >&2 ; \
        SOURCE="npm-fallback (VSIX baked, binary path issue)" ; \
      fi ; \
    elif [ "$EXT_BAKED" = "1" ] ; then \
      echo "claude-binary: extension extracted but $BIN missing/not executable" >&2 ; \
      SOURCE="npm-fallback (VSIX baked, binary path issue)" ; \
    else \
      echo "claude-binary: no extension dir (VSIX DL failed earlier)" >&2 ; \
      SOURCE="npm-fallback (no VSIX, runtime ext install via Marketplace)" ; \
    fi ; \
    printf '%s\n' "$SOURCE" > /etc/claude-source ; \
    chmod 644 /etc/claude-source

# RUN 4 — conditional npm fallback (HEAVY when triggered, no-op otherwise)
RUN set -u ; \
    if grep -q '^npm-fallback' /etc/claude-source ; then \
      NPM_ARCH=$(node -e 'console.log(process.arch)') ; \
      npm install -g --os=linux --cpu="${NPM_ARCH}" \
          @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} ; \
      npm cache clean --force ; \
      rm -rf /home/node/.npm /root/.npm /tmp/* ; \
      touch /etc/claude-fallback-warn ; \
    fi

# RUN 5 — write extensions.json so VS Code sees the baked extension (light)
# Only written when the VSIX was actually extracted. Otherwise VS Code
# installs the extension at runtime via the pin in devcontainer.json
# (firewall already allows GET marketplace + *.gallerycdn.vsassets.io).
# UUIDs are stable per-extension/per-publisher.
#
# `"source":"gallery"` and the Anthropic publisher UUID are stated here rather
# than forged: the bytes on disk ARE the Marketplace VSIX for this version,
# extracted unmodified, and nothing in this image rewrites them. This record
# says where the extension came from, and it is accurate. It would stop being
# accurate the moment a patcher ran at build time — which is why this image
# bakes none, and why the patch hook runs on the USER's own copy, after
# install, rather than here.
RUN set -u ; \
    . /etc/claude-build-env ; \
    if [ -d "$EXT_DIR" ] ; then \
      TS=$(date +%s)000 ; \
      printf '[{"identifier":{"id":"anthropic.claude-code","uuid":"3c13ae49-babe-45fe-8c48-5e45077a62bf"},"version":"%s","location":{"$mid":1,"fsPath":"%s","external":"file://%s","path":"%s","scheme":"file"},"relativeLocation":"%s","metadata":{"isApplicationScoped":true,"installedTimestamp":%s,"pinned":true,"source":"gallery","id":"3c13ae49-babe-45fe-8c48-5e45077a62bf","publisherId":"89769da0-cc4b-40b0-8216-93ffb5a96b56","publisherDisplayName":"Anthropic","targetPlatform":"%s","updated":false,"private":false,"isPreReleaseVersion":false,"hasPreReleaseVersion":false}}]\n' \
        "${CLAUDE_CODE_VERSION}" "${EXT_DIR}" "${EXT_DIR}" "${EXT_DIR}" "${REL}" "${TS}" "${VP}" \
        > "${HOME}/.vscode-server/extensions/extensions.json" ; \
      chown node:node "${HOME}/.vscode-server/extensions/extensions.json" ; \
    fi

# -----------------------------------------------
# Shared config parser — sourced by the firewall toolchain, devc-hook and
# sync-skills. Root-owned and non-writable for the same reason as
# firewall-digest.sh: init-firewall.sh sources it as root.
# -----------------------------------------------
COPY bin/devc-conf.sh /usr/local/bin/devc-conf.sh
RUN chmod 0644 /usr/local/bin/devc-conf.sh && \
    chown root:root /usr/local/bin/devc-conf.sh && \
    bash -n /usr/local/bin/devc-conf.sh

# -----------------------------------------------
# Firewall toolchain + config (baked into image, root-only)
# -----------------------------------------------
COPY bin/init-firewall.sh /usr/local/bin/
COPY bin/test-firewall.sh /usr/local/bin/
COPY bin/compile-policy.py /usr/local/bin/compile-policy.py
COPY bin/mitm-init.sh /usr/local/bin/mitm-init.sh
COPY bin/firewall-blocks /usr/local/bin/firewall-blocks
COPY bin/firewall-docker-setup.sh /usr/local/bin/firewall-docker-setup.sh
# Both must be image content, not workspace content. reload-firewall runs as
# root ; the digest library decides whether boot trusts the baked ruleset. A
# copy under /workspace is writable by everything in the container, so running
# either from there would hand root (or the allowlist) to any postinstall.
COPY bin/reload-firewall     /usr/local/bin/reload-firewall
COPY bin/firewall-digest.sh  /usr/local/bin/firewall-digest.sh
COPY assets/etc-firewall/dnsmasq.conf /etc/devcontainer-firewall/dnsmasq.conf
COPY assets/etc-firewall/tests/ /etc/devcontainer-firewall/tests/
COPY assets/etc-firewall/addons/ /etc/devcontainer-firewall/addons/
# Base allowlist (3-level model, layer 1) : the universal sandbox minimum,
# sufficient alone — a project overlay is additive and optional. Projects
# override via !disable / redeclare in their committed firewall files.
COPY assets/etc-firewall/domains.d/ /etc/devcontainer-firewall/domains.d/
COPY assets/etc-firewall/policy.d/ /etc/devcontainer-firewall/policy.d/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/test-firewall.sh /usr/local/bin/mitm-init.sh /usr/local/bin/compile-policy.py /usr/local/bin/firewall-blocks /usr/local/bin/firewall-docker-setup.sh /usr/local/bin/reload-firewall && \
    chmod 0644 /usr/local/bin/firewall-digest.sh && \
    chown root:root /usr/local/bin/reload-firewall /usr/local/bin/firewall-digest.sh && \
    chown -R root:root /etc/devcontainer-firewall && \
    chmod -R 644 /etc/devcontainer-firewall && \
    chmod 755 /etc/devcontainer-firewall \
              /etc/devcontainer-firewall/tests \
              /etc/devcontainer-firewall/addons \
              /etc/devcontainer-firewall/domains.d \
              /etc/devcontainer-firewall/policy.d && \
    python3 -c "import ast; ast.parse(open('/usr/local/bin/compile-policy.py').read())" && \
    for f in /etc/devcontainer-firewall/addons/*.py; do \
      python3 -c "import ast,sys; ast.parse(open('$f').read())" || exit 1; \
    done && \
    bash -n /usr/local/bin/reload-firewall && \
    bash -n /usr/local/bin/firewall-digest.sh && \
    echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/test-firewall.sh" > /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/node-firewall && \
    printf '%s\n' \
      '# reload-firewall - PASSWORD REQUIRED, DELIBERATELY. Never add NOPASSWD.' \
      '#' \
      '# This command merges workspace .local files into the live firewall. The' \
      '# env-var and TTY checks inside it are honesty guards, not a boundary:' \
      '# both are trivially cleared by any process that wants to. A NOPASSWD' \
      '# grant here would therefore let an npm postinstall, or an agent, widen' \
      '# the firewall allowlist unattended in two lines.' \
      '#' \
      '# The node user has no password, so this rule cannot be used as written.' \
      '# That is intended. Root comes from the host instead:' \
      '#   docker exec -it -u 0 <container> /usr/local/bin/reload-firewall' \
      '# No docker socket is mounted, so nothing inside can reach that path.' \
      '# The rule exists to record the policy on disk.' \
      "$USERNAME ALL=(root) /usr/local/bin/reload-firewall" \
      > /etc/sudoers.d/node-reload-firewall && \
    chmod 0440 /etc/sudoers.d/node-reload-firewall && \
    visudo -c -f /etc/sudoers.d/node-reload-firewall && \
    visudo -c -f /etc/sudoers.d/node-firewall

# -----------------------------------------------
# Hooks dispatcher + base overlay content
# devc-hook installed at /usr/local/bin resolves its base layer via the
# /opt/devcontainer/base/hooks fallback (its <script>/../hooks probe misses
# at /usr/local on purpose). Project overlays mount at runtime under
# /workspace/.devcontainer/hooks — nothing here depends on the workspace.
#
# /opt/devcontainer/ext/ is the seam for an image that FROMs this one : it
# ships EMPTY and is the only place an extending Dockerfile should COPY hooks
# and skills into. Writing into base/ instead would overwrite our fragments on
# disk — the original gone, the layer untraceable, and the @required guard
# bypassed by shadowing rather than by disabledHooks.
# -----------------------------------------------
COPY bin/devc-hook /usr/local/bin/devc-hook
# Workspace-free companions to the lifecycle hooks. These used to live in the
# project's .devcontainer and were reached by absolute /workspace paths, which
# left every hook that calls them inert on a project that ships only the
# compose files. They are project-agnostic — sync-creds works on ~/.claude and
# ~/.claude-creds, install-extensions reads whatever devcontainer.json it is
# pointed at, sync-skills takes its source dirs as arguments.
COPY bin/sync-creds         /usr/local/bin/sync-creds
COPY bin/sync-skills        /usr/local/bin/sync-skills
COPY bin/install-extensions /usr/local/bin/install-extensions
COPY assets/opt/ /opt/devcontainer/base/
RUN chmod +x /usr/local/bin/devc-hook \
             /usr/local/bin/sync-creds \
             /usr/local/bin/sync-skills \
             /usr/local/bin/install-extensions && \
    chown root:root /usr/local/bin/devc-hook \
                    /usr/local/bin/sync-creds \
                    /usr/local/bin/sync-skills \
                    /usr/local/bin/install-extensions && \
    bash -n /usr/local/bin/sync-creds && \
    bash -n /usr/local/bin/sync-skills && \
    bash -n /usr/local/bin/install-extensions && \
    bash -n /opt/devcontainer/base/shell-init.sh && \
    chown -R root:root /opt/devcontainer/base && \
    find /opt/devcontainer/base -type d -exec chmod 755 {} + && \
    find /opt/devcontainer/base -type f -exec chmod 644 {} + && \
    bash -n /usr/local/bin/devc-hook && \
    # The extension seam (layer 2). Ships empty on purpose : its existence is
    # the contract, its content belongs to whoever extends this image.
    mkdir -p /opt/devcontainer/ext/hooks/on-create.d \
             /opt/devcontainer/ext/hooks/post-create.d \
             /opt/devcontainer/ext/hooks/post-start.d \
             /opt/devcontainer/ext/skills && \
    chown -R root:root /opt/devcontainer/ext && \
    find /opt/devcontainer/ext -type d -exec chmod 755 {} + && \
    # Build-time self-check : the dispatcher must resolve its base layer at
    # /opt/devcontainer/base/hooks, announce the ext layer, and enumerate at
    # least one fragment per phase. A silent empty resolution here is exactly
    # the dead-on-arrival failure this image exists to prevent.
    for phase in on-create post-create post-start ; do \
      out=$(devc-hook "$phase" --dry-run) ; \
      echo "$out" | grep -q "base:  /opt/devcontainer/base/hooks" || { echo "devc-hook: wrong base dir for $phase" >&2 ; exit 1 ; } ; \
      echo "$out" | grep -q "ext:   /opt/devcontainer/ext/hooks" || { echo "devc-hook: wrong ext dir for $phase" >&2 ; exit 1 ; } ; \
      echo "$out" | grep -q "WOULD RUN ${phase}.d/" || { echo "devc-hook: no fragment resolved for $phase" >&2 ; exit 1 ; } ; \
      if echo "$out" | grep -q "WOULD RUN ${phase}.d/.* (ext," ; then echo "devc-hook: ext layer must ship empty" >&2 ; exit 1 ; fi ; \
    done

# -----------------------------------------------
# Shell init
# -----------------------------------------------
USER $USERNAME

# -----------------------------------------------
# Oh My Zsh + extra plugins (autosuggestions, syntax-highlighting)
# Installed under $HOME/.oh-my-zsh — volatile across container
# rebuilds, but baked into the image so first boot is instant.
# OMZ uses its default ZSH_CUSTOM ($ZSH/custom/) ; the two plugins
# land at $ZSH/custom/plugins/{zsh-autosuggestions,zsh-syntax-highlighting}.
#
# --unattended  : OMZ installer does not spawn an interactive shell.
# rm -f .zshrc* : the installer writes a default .zshrc — remove it
#                 so the next RUN block (shell-init injection)
#                 starts from an empty file.
# --depth=1     : shallow clone for the two plugins (~1 MB combined
#                 vs ~5-10 MB full history).
# -----------------------------------------------
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
 && rm -f $HOME/.zshrc $HOME/.zshrc.pre-oh-my-zsh \
 && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
      $HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions \
 && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
      $HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# Shell init — the workspace copy wins when it exists (v2 layout, editable
# without a rebuild), otherwise the baked one runs. Without the fallback a
# project that ships no shell-init.sh gets a bare shell: no Oh My Zsh, no
# theme, no git in the prompt, no session banner.
RUN printf '%s\n' \
      'if [ -f /workspace/.devcontainer/shell-init.sh ]; then' \
      '  source /workspace/.devcontainer/shell-init.sh' \
      'elif [ -f /opt/devcontainer/base/shell-init.sh ]; then' \
      '  source /opt/devcontainer/base/shell-init.sh' \
      'fi' | tee -a $HOME/.bashrc >> $HOME/.zshrc

# -----------------------------------------------
# Defaults
# -----------------------------------------------
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# UTF-8 by default. The locale purge above keeps en/en_US/C only, but C.UTF-8
# is built into glibc and needs no locale pack — so this costs nothing and
# makes the image correct on its own. Without it LANG is empty, LC_CTYPE falls
# back to POSIX, and zsh's ZLE renders every non-ASCII byte as `?` : the boot
# banners come out as `??? ???`. Templates may still set it in containerEnv
# (higher in the precedence chain, same value) — harmless duplication.
ENV LANG=C.UTF-8

# Claude Code config dir — baked default. Dockerfile ENV is the LOWEST
# layer in the docker-compose / devcontainer env chain :
#   Dockerfile ENV < env_file < environment < containerEnv
# So `docker-compose env_file: .env` overrides this when CLAUDE_CONFIG_DIR
# is uncommented in .env (claude-switch local mode). When .env keeps it
# commented (cloud mode), this baseline ensures the var is always defined
# — no script needs to handle "unset" as a special case.
#
# IMPORTANT : do NOT move this to devcontainer.json `containerEnv`.
# containerEnv applies AFTER env_file in the precedence chain and would
# silently override the env_file setting, breaking claude-switch local mode.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# -----------------------------------------------
# Labels — LAST on purpose
# -----------------------------------------------
# These are metadata: they change what `docker inspect` reports and nothing
# about the filesystem. Declared near the top, they used to sit above 39 RUN
# and COPY steps — including the 243 MB VSIX download — so bumping the version
# for a release rebuilt the entire image to change a string. Every release does
# that bump (RELEASING.md), and every hand-build that forgot --build-arg
# invalidated the cache against one that did not.
#
# Last, a version bump rebuilds one trivial layer. ARG has to be re-declared
# here because the earlier one is out of scope once a stage has moved on.
ARG BASE_VERSION=0.0.0-dev
ARG CLAUDE_CODE_VERSION

LABEL org.stitchu.base.version="${BASE_VERSION}" \
      org.stitchu.claude-code.version="${CLAUDE_CODE_VERSION}" \
      org.opencontainers.image.source="https://github.com/meitogi/devcontainer-sandbox" \
      org.opencontainers.image.description="Firewalled devcontainer base image, Claude Code preinstalled"

CMD ["bash", "-c", "trap 'exit' INT TERM; sleep infinity & wait"]
