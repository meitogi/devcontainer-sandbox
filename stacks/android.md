# Android stack — project Dockerfile blocks

Android compile-check toolchain (OpenJDK 17 + Kotlin + multi-API
`android.jar` matrix + `kchk`/`jchk` helpers) on top of
`ghcr.io/meitogi/devcontainer-sandbox`. No Capacitor SDK, no AndroidX — for
generic Android library/plugin dev without framework assumptions ; for
Capacitor plugin work use [android-capacitor.md](android-capacitor.md)
instead. There is no published Android image : per the v1 architecture
decision, non-Node stacks are **project Dockerfiles** deriving from the
single Node 24 base.

The toolchain blocks use BuildKit cache mounts — keep the first line of your
Dockerfile as :

```dockerfile
# syntax=docker/dockerfile:1
```

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
ARG BASE_VERSION=0.1.0
ARG CLAUDE_CODE_VERSION=2.1.258

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

## 2. Android toolchain (Debian OpenJDK 17)

Continues as `USER root` from the preamble ; ends by dropping back to `node`.

```dockerfile
# Everything below is variant-specific (JDK, Kotlin, Android jars, helpers).
# Stays USER root from the firewall block above — no explicit switch needed.

ARG KOTLIN_VERSION=2.4.10
ARG ANDROID_APIS="23 24 26 28 31 33 34 35"
ARG ANDROID_API_DEFAULT=35

# Debian OpenJDK 17 (headless — no X11 deps, javac included).
# mkdir /usr/share/man/man1: openjdk post-install symlinks java.1.gz there,
# but node:24-bookworm-slim (base) purges /usr/share/man/ → symlink fails
# without this prep.
RUN mkdir -p /usr/share/man/man1 \
 && apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless unzip ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Kotlin distribution (shared cache mount with sibling images)
RUN --mount=type=cache,id=kotlin-dl,target=/dl \
    { [ -f "/dl/kotlin-${KOTLIN_VERSION}.zip" ] || \
      curl -fSL "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip" \
        -o "/dl/kotlin-${KOTLIN_VERSION}.zip" ; } \
 && unzip -q "/dl/kotlin-${KOTLIN_VERSION}.zip" -d /opt

# Multi-API android.jar matrix — parse repository2-3.xml for accurate zip names.
# API 34+ uses platform-<api>-ext<N>_r<M>.zip (SDK Extensions naming), older uses
# plain platform-<api>_r<M>.zip. Grep both patterns, sort -V descending, take newest.
RUN --mount=type=cache,id=android-multi-dl,target=/dl \
    mkdir -p /opt/android-jars && \
    { [ -f /dl/repo-index.xml ] || \
      curl -fSL "https://dl.google.com/android/repository/repository2-3.xml" -o /dl/repo-index.xml ; } && \
    for api in ${ANDROID_APIS}; do \
      zip=$(grep -oE "platform-${api}(-ext[0-9]+)?_r[0-9]+\.zip" /dl/repo-index.xml | sort -Vr | head -1) ; \
      if [ -z "$zip" ]; then echo "ERROR: no platform-${api} zip in repo index"; exit 1; fi ; \
      cached="/dl/$zip" ; \
      [ -f "$cached" ] || curl -fSL "https://dl.google.com/android/repository/$zip" -o "$cached" ; \
      unzip -p "$cached" 'android-*/android.jar' > "/opt/android-jars/api-${api}.jar" ; \
      printf "  ✓ API %s → api-%s.jar via %s (%s bytes)\n" "$api" "$api" "$zip" "$(stat -c%s /opt/android-jars/api-${api}.jar)" ; \
    done && \
    ln -sf "/opt/android-jars/api-${ANDROID_API_DEFAULT}.jar" /opt/android.jar

# Empty cap-deps dir so kchk helpers can loop without special-casing
RUN mkdir -p /opt/cap-deps

ENV PATH="/opt/kotlinc/bin:${PATH}" \
    ANDROID_JAR=/opt/android.jar \
    ANDROID_JARS_DIR=/opt/android-jars \
    CAP_DEPS=/opt/cap-deps \
    ANDROID_CACHE_DIR=/workspace/.devcontainer/cache/android-jars

# Helpers — same set as CapacitorAndroid variants (CAP_DEPS loop no-ops here).
COPY <<'EOF' /usr/local/bin/kchk
#!/bin/sh
CP="$ANDROID_JAR"
for j in "$CAP_DEPS"/*.jar "$ANDROID_CACHE_DIR"/maven/*.jar; do [ -e "$j" ] && CP="$CP:$j"; done
exec kotlinc -cp "$CP" -d /tmp/out.jar "$@"
EOF

COPY <<'EOF' /usr/local/bin/jchk
#!/bin/sh
mkdir -p /tmp/jout
CP="$ANDROID_JAR"
for j in "$CAP_DEPS"/*.jar "$ANDROID_CACHE_DIR"/maven/*.jar; do [ -e "$j" ] && CP="$CP:$j"; done
exec javac -cp "$CP" -d /tmp/jout "$@"
EOF

COPY <<'EOF' /usr/local/bin/kchk-api
#!/bin/sh
if [ -z "$1" ]; then
  echo "usage: kchk-api <API> <file...>"
  echo "baked APIs:"
  ls "$ANDROID_JARS_DIR" | sed 's/^api-/  /;s/\.jar$//'
  echo "cached APIs (from $ANDROID_CACHE_DIR/apis):"
  ls "$ANDROID_CACHE_DIR/apis" 2>/dev/null | sed 's/^api-/  /;s/\.jar$//' || echo "  (none)"
  exit 1
fi
API=$1; shift
JAR="$ANDROID_JARS_DIR/api-${API}.jar"
[ -f "$JAR" ] || JAR="$ANDROID_CACHE_DIR/apis/api-${API}.jar"
if [ ! -f "$JAR" ]; then
  echo "ERROR: api-${API}.jar not baked or cached. Fetch it first:"
  echo "  fetch-android-api ${API}"
  exit 1
fi
CP="$JAR"
for j in "$CAP_DEPS"/*.jar "$ANDROID_CACHE_DIR"/maven/*.jar; do [ -e "$j" ] && CP="$CP:$j"; done
exec kotlinc -cp "$CP" -d /tmp/out.jar "$@"
EOF

COPY <<'EOF' /usr/local/bin/kchk-matrix
#!/bin/sh
if [ -z "$1" ]; then echo "usage: kchk-matrix <file...>"; exit 1; fi
echo "Matrix compile check across baked + cached APIs:"
FAIL=0
JARS="$(ls "$ANDROID_JARS_DIR"/api-*.jar 2>/dev/null) $(ls "$ANDROID_CACHE_DIR"/apis/api-*.jar 2>/dev/null)"
for JAR in $JARS; do
  API=$(basename "$JAR" .jar | sed 's/^api-//')
  CP="$JAR"
  for j in "$CAP_DEPS"/*.jar "$ANDROID_CACHE_DIR"/maven/*.jar; do [ -e "$j" ] && CP="$CP:$j"; done
  if kotlinc -cp "$CP" -d /tmp/out.jar "$@" 2>/tmp/matrix.err >/dev/null ; then
    printf "  API %-3s : OK\n" "$API"
  else
    printf "  API %-3s : FAIL\n" "$API"
    grep -E "error:|warning:" /tmp/matrix.err | head -3 | sed 's/^/         /'
    FAIL=1
  fi
done
exit $FAIL
EOF

COPY <<'EOF' /usr/local/bin/fetch-android-api
#!/bin/sh
if [ -z "$1" ]; then echo "usage: fetch-android-api <API>"; exit 1; fi
API=$1
mkdir -p "$ANDROID_CACHE_DIR/apis"
DEST="$ANDROID_CACHE_DIR/apis/api-${API}.jar"
if [ -f "$DEST" ]; then echo "already cached: $DEST"; exit 0; fi
INDEX="$ANDROID_CACHE_DIR/apis/repo-index.xml"
[ -f "$INDEX" ] || curl -fSL "https://dl.google.com/android/repository/repository2-3.xml" -o "$INDEX"
zip=$(grep -oE "platform-${API}(-ext[0-9]+)?_r[0-9]+\.zip" "$INDEX" | sort -Vr | head -1)
if [ -z "$zip" ]; then echo "ERROR: no platform-${API} zip in repo index"; exit 1; fi
tmpzip=$(mktemp)
curl -fSL "https://dl.google.com/android/repository/$zip" -o "$tmpzip" && \
  unzip -p "$tmpzip" 'android-*/android.jar' > "$DEST" && \
  rm "$tmpzip" && \
  echo "fetched: $DEST via $zip ($(stat -c%s "$DEST") bytes)" && \
  exit 0
echo "ERROR: fetch failed for API ${API}"
exit 1
EOF

# Fetch arbitrary Maven artifact into on-demand cache (persistent via bind mount).
# Tries default repos (Google Maven + Maven Central) unless override supplied.
# AARs auto-extract classes.jar ; pure jars copied as-is.
COPY <<'EOF' /usr/local/bin/fetch-android-lib
#!/bin/sh
if [ -z "$1" ]; then
  echo "usage: fetch-android-lib <group:artifact:version> [maven-repo-url]"
  echo "  default repos: dl.google.com/android/maven2, repo.maven.apache.org/maven2"
  exit 1
fi
COORD=$1
CUSTOM_REPO=${2:-}
GROUP=${COORD%%:*}
REST=${COORD#*:}
ARTIFACT=${REST%%:*}
VERSION=${REST##*:}
GROUP_PATH=$(echo "$GROUP" | tr . /)
mkdir -p "$ANDROID_CACHE_DIR/maven"
DEST="$ANDROID_CACHE_DIR/maven/${ARTIFACT}-${VERSION}.jar"
if [ -f "$DEST" ]; then echo "already cached: $DEST"; exit 0; fi
REPOS="${CUSTOM_REPO:-https://dl.google.com/android/maven2 https://repo.maven.apache.org/maven2}"
for repo in $REPOS; do
  for ext in aar jar; do
    URL="${repo}/${GROUP_PATH}/${ARTIFACT}/${VERSION}/${ARTIFACT}-${VERSION}.${ext}"
    code=$(curl -sI -o /dev/null -w "%{http_code}" "$URL")
    if [ "$code" = "200" ]; then
      tmp=$(mktemp)
      curl -fSL "$URL" -o "$tmp" || { rm -f "$tmp"; continue; }
      if [ "$ext" = "aar" ]; then
        unzip -p "$tmp" classes.jar > "$DEST" 2>/dev/null
        rm -f "$tmp"
        [ -s "$DEST" ] || { rm -f "$DEST"; continue; }
      else
        mv "$tmp" "$DEST"
      fi
      echo "fetched: $DEST via $URL ($(stat -c%s "$DEST") bytes)"
      exit 0
    fi
  done
done
echo "ERROR: could not fetch $COORD"
exit 1
EOF

RUN chmod +x /usr/local/bin/kchk /usr/local/bin/jchk /usr/local/bin/kchk-api /usr/local/bin/kchk-matrix /usr/local/bin/fetch-android-api /usr/local/bin/fetch-android-lib

USER node
```

## 3. Variant — Azul Zulu 17 instead of Debian OpenJDK

Preferred when you want a vendor-packaged JDK (cleaner debug traces, stable
versioning). Replace the `openjdk-17-jdk-headless` RUN block above with :

```dockerfile
# Azul Zulu 17 via official Azul apt repo (multi-arch amd64/arm64)
RUN apt-get update && apt-get install -y --no-install-recommends \
      gnupg unzip ca-certificates \
    && curl -fsSL https://repos.azul.com/azul-repo.key \
        | gpg --dearmor -o /usr/share/keyrings/azul-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/azul-archive-keyring.gpg] https://repos.azul.com/zulu/deb stable main" \
        > /etc/apt/sources.list.d/zulu.list \
    && apt-get update && apt-get install -y --no-install-recommends zulu17-jdk \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

```
