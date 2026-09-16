# PHP stack — project Dockerfile blocks

PHP 8.2 + Composer on top of `ghcr.io/meitogi/devcontainer-sandbox`. There is
no published PHP image : per the v1 architecture decision, non-Node stacks are
**project Dockerfiles** that derive from the single Node 24 base and add their
toolchain. Copy the blocks below into `.devcontainer/Dockerfile` and point
`docker-compose.yml` at it.

## 1. Image + firewall bake — mandatory preamble

The bake stage is not optional. The base image ships firewall
*infrastructure* only (binaries, dnsmasq.conf, addons, tests) ; the project
allowlist — `firewall/domains.txt`, `domains.d/`, `policy.d/` — lives in
`.devcontainer/firewall/` and must be baked by every project layer. Skipping
it means `init-firewall.sh` crashes at onCreate and every container start
explodes while the image itself looks healthy.

```dockerfile
# Pin both versions in .devcontainer/.env ; docker-compose passes them through
# as build args. See cc-versions.json in the base repo for the CC versions
# published alongside each base release.
# the two published lines
#   1.2.0-cc2.1.272   (default)
#   1.2.0-cc2.1.220
ARG BASE_VERSION=1.2.0
ARG CLAUDE_CODE_VERSION=2.1.272

# --- Stage 1 : firewall bake (throwaway) --------------------------------------
# Why a separate stage rather than one COPY + RUN in the final image :
# firewall/ carries domains.local.txt and policy.local.d/, which are gitignored
# and writable by anything running in the container, an npm postinstall
# included. A `RUN rm` after the COPY would not help — the file still sits in
# the COPY layer, so `docker save` and any registry push still ship it. Layers
# built in a stage that nothing copies from never enter the final manifest, so
# the .local files are discarded rather than merely hidden.
#
# The bake also freezes the compiled ruleset into effective/, which boot
# installs verbatim instead of recompiling.
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake

# 0 = hardened (default) : domains.local.txt and policy.local.d/ are NOT baked.
# 1 = convenience : they are. Set per developer through .env, never as a team
# default. Either way the bake logs which it did and how many hosts it costs.
ARG FIREWALL_ALLOW_LOCAL_AT_REBUILD=0

USER root
COPY firewall/ /tmp/fw-src/
RUN FIREWALL_ALLOW_LOCAL_AT_REBUILD="${FIREWALL_ALLOW_LOCAL_AT_REBUILD}" \
    /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out

# --- Final image ---------------------------------------------------------------
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION}

USER root

# /out already merges the base image's firewall content with the project
# overlay, so this single COPY is the whole configuration. Ownership and modes
# were set root:root / u=rwX,go=rX in the bake stage and COPY --from preserves
# them. The assertion catches a bake that silently produced nothing.
COPY --from=fw-bake /out/ /etc/devcontainer-firewall/
RUN test -s /etc/devcontainer-firewall/baked-at \
 && test -s /etc/devcontainer-firewall/effective/sources.sha256
```

## 2. PHP toolchain

Continues as `USER root` from the preamble ; ends by dropping back to `node`.

```dockerfile
# Sury APT repo — Ondřej Surý (official Debian PHP maintainer). Future-proofing
# for when node:24-slim eventually rebases on Debian trixie (where main ships
# PHP 8.4 by default, no php8.2-* package). On the current bookworm-based
# node:24-slim, bookworm main also ships php8.2-* — Sury wins on resolution
# because it carries the newer patch (e.g. 8.2.31 vs bookworm's 8.2.x at
# release time), which is what we want for security fixes. Codename is
# resolved at build via `lsb_release -sc`, so the same RUN block works on
# both bookworm and a future trixie base without edit.
RUN apt-get update && apt-get install -y --no-install-recommends \
      apt-transport-https lsb-release ca-certificates curl \
    && curl -fsSL https://packages.sury.org/php/apt.gpg \
        -o /usr/share/keyrings/sury-php-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/sury-php-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# PHP 8.2 + 13 extensions covering the common Laravel / Symfony /
# CodeIgniter footprint (cli, fpm, curl, gd, mbstring, xml, zip, soap,
# intl, mysql, readline, bcmath, sockets, phar). Package names match
# Debian's across bookworm + trixie, so the install block below is
# distro-agnostic — Sury (wired above) provides the resolution path
# on either base. Drop unused extensions inline per-project rather
# than trimming the shared layer here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      php8.2-cli \
      php8.2-fpm \
      php8.2-curl \
      php8.2-gd \
      php8.2-mbstring \
      php8.2-xml \
      php8.2-zip \
      php8.2-soap \
      php8.2-intl \
      php8.2-mysql \
      php8.2-readline \
      php8.2-bcmath \
      php8.2-sockets \
      php8.2-phar \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc/* /usr/share/man/*

# Composer 2.x latest (official image, multi-arch amd64 + arm64).
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

USER node
```
