#!/usr/bin/env bash
# bare-project.sh — a throwaway project on the image and CLI of THIS tree,
# scaffolded by `devc init`, opened in VS Code. The light companion of
# release-check.sh: no gate, no verdict, no --no-cache build — just "does the
# current image + current CLI boot a bare project, with the options I pick".
# Entry point: `wtf image bare [--pat] [--shared-creds] [--published]`.
#
# Defaults — the tree, not the registries:
#   image  devcontainer-sandbox:local, the one `wtf image release-check` (or
#          `test/run-image-suites.sh --build`) leaves on this machine. Refused
#          when absent; a baked version other than package.json's is reported.
#   CLI    packages/devcontainer-cli of this monorepo: built when dist/ is
#          behind src/, `npm pack`ed, installed in the scratch against a DEAD
#          registry — so the initializeCommand provably runs this checkout and
#          nothing published. `devc init --yes` runs from the same checkout.
#
# --published  the registries instead: the GHCR tag the CLI template pins and
#              the npm version the CLI package.json names. Both must resolve.
# --pat        wire the extension patchers. The token comes from
#              ~/.config/devc/ext-patches.env (left for `devc initialize` to
#              project at boot — the shared-credentials path), else from
#              EXT_PATCHES_TOKEN in the environment, else from this repo's
#              .devcontainer/.env (as release-check does); none = refusal.
# --shared-creds  mount the CLAUDE_CREDS_VOLUME of this repo's .devcontainer/.env
#              (a real signed-in Claude session) instead of a throwaway
#              claude-creds-bare-project that is wiped at every run.
# --build      build devcontainer-sandbox:local from this tree first (cached
#              layers, unlike the gate's --no-cache) — the quick path when the
#              gate has not run on this machine, or ran before the last commit.
# --simulate   no docker, no registry, no VS Code: scaffold + pack + offline
#              install only — the in-container rehearsal of this script.
#
# Host only: VS Code opens the project on the Mac's daemon, and that is the
# daemon whose devcontainer-sandbox:local counts. Inside a devcontainer,
# `docker` talks to the nested dind — a release-check played there leaves an
# image VS Code can never reach. Refused on /.dockerenv unless --simulate.
# Every run is also written to <monorepo>/.tmp/bare.log.
#
# Scratch: <monorepo>/.tmp/bare/ (gitignored; under the repo and not ~/tmp
# because VS Code's workspace-trust prompt otherwise opens Restricted Mode),
# DC_PROJECT=bare-project. Every container / volume / image whose name carries
# that id is removed at the start of a run. Named volumes of other projects,
# the shared creds volume included, are never candidates.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROJECT_ROOT="$(cd "$REPO/../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/packages/devcontainer-cli"
DC_PROJECT=bare-project
SCRATCH="$PROJECT_ROOT/.tmp/bare"
IMG="${IMG:-devcontainer-sandbox:local}"
PKG=@meitogi/devcontainer-cli
MACHINE_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/devc/ext-patches.env"

PAT=0; SHARED=0; PUBLISHED=0; SIMULATE=0; BUILD=0
for a in "$@"; do case "$a" in
  --pat) PAT=1 ;; --shared-creds) SHARED=1 ;; --published) PUBLISHED=1 ;; --simulate) SIMULATE=1 ;; --build) BUILD=1 ;;
  -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "bare-project.sh: unknown flag $a (see --help)" >&2; exit 2 ;;
esac; done

if [ "$SIMULATE" != 1 ] && [ -f /.dockerenv ]; then
  echo "bare-project.sh: this runs on the Mac, not inside a devcontainer — the project opens in VS Code on the host daemon, and the nested dind's devcontainer-sandbox:local is invisible to it. (--simulate for the in-container rehearsal.)" >&2
  exit 2
fi
LOG="$PROJECT_ROOT/.tmp/bare.log"; mkdir -p "$PROJECT_ROOT/.tmp"
exec > >(tee "$LOG") 2>&1
echo "## wtf image bare $* — $(date '+%F %T') — log: $LOG"

sect() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ✔ %s\n' "$*"; }
info() { printf '   · %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
env_val() { grep -h "^$1=" "$PROJECT_ROOT/.devcontainer/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }

[ -d "$CLI_DIR" ] || die "no CLI checkout at $CLI_DIR"
command -v npm >/dev/null || die "npm not on PATH"
[ "$SIMULATE" = 1 ] || command -v docker >/dev/null || die "docker not on PATH"

# ---- 1. what runs: image + CLI ---------------------------------------------
sect "1. image and CLI under test"
TREE_VER="$(jq -r .version "$REPO/package.json")"
CLI_VER="$(jq -r .version "$CLI_DIR/package.json")"
PIN="$(sed -n 's/.*BASE_IMAGE:-\([^}]*\)}.*/\1/p' "$CLI_DIR/templates/devcontainer/docker-compose.yml" | head -1)"
if [ "$PUBLISHED" = 1 ]; then
  IMG="$PIN"
  if [ "$SIMULATE" = 1 ]; then info "(simulate) would require $IMG on GHCR and $PKG@$CLI_VER on npm"
  else
    docker manifest inspect "$IMG" >/dev/null 2>&1 || die "$IMG is not on GHCR — push the tag and let CI finish, or drop --published"
    ok "image $IMG (GHCR)"
    v="$(npm view "$PKG" version 2>/dev/null || true)"
    [ "$v" = "$CLI_VER" ] || die "npm serves $PKG $v, the tree says $CLI_VER — approve the staged release, or drop --published"
    ok "CLI $PKG@$CLI_VER (npm)"
  fi
  DEVC="npx --yes $PKG@$CLI_VER"
else
  if [ "$SIMULATE" = 1 ]; then info "(simulate) would require the local image $IMG"
  else
    if [ "$BUILD" = 1 ]; then
      info "docker build -t $IMG (cached) from ${REPO}…"
      docker build -t "$IMG" --build-arg BASE_VERSION="$TREE_VER" "$REPO" >"$PROJECT_ROOT/.tmp/bare-build.log" 2>&1 \
        || die "build failed — see $PROJECT_ROOT/.tmp/bare-build.log"
    fi
    docker image inspect "$IMG" >/dev/null 2>&1 \
      || die "$IMG is not on this machine — build it first: wtf image release-check --no-purge (the gate), or wtf image bare --build (cached, no gate)"
    BAKED="$(docker image inspect -f '{{index .Config.Labels "org.stitchu.base.version"}}' "$IMG" 2>/dev/null || true)"
    if [ "$BAKED" = "$TREE_VER" ]; then ok "image $IMG, baked $BAKED = package.json"
    else info "image $IMG is baked '$BAKED' while package.json says '$TREE_VER' — rebuild if that is not on purpose"; fi
  fi
  if [ ! -f "$CLI_DIR/dist/src/cli.js" ] \
     || [ -n "$(find "$CLI_DIR/src" -newer "$CLI_DIR/dist/src/cli.js" -print -quit 2>/dev/null)" ]; then
    info "dist/ is behind src/ — npm run build (devcontainer-cli)"
    ( cd "$CLI_DIR" && env -u npm_config_dry_run npm run build ) >/dev/null
  fi
  DEVC="node $CLI_DIR/bin/devc.mjs"
  ok "CLI $CLI_VER @ $(git -C "$CLI_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit) (checkout, packed below)"
fi
[ "$SIMULATE" = 1 ] && DEVC="node $CLI_DIR/bin/devc.mjs"

# ---- 2. options -------------------------------------------------------------
sect "2. options"
EXT_ARGS=""
if [ "$PAT" = 1 ]; then
  EXT_REPO="$(grep -h '^EXT_PATCHES_REPO=' "$MACHINE_ENV" 2>/dev/null | cut -d= -f2- || true)"
  EXT_ARGS="--ext-patches-repo ${EXT_REPO:-meitogi/claude-ext-patchs}"
  if grep -q '^EXT_PATCHES_TOKEN=.\+' "$MACHINE_ENV" 2>/dev/null; then
    unset EXT_PATCHES_TOKEN
    ok "patchers on — token in $MACHINE_ENV, projected into .env by devc initialize at boot"
  elif [ -n "${EXT_PATCHES_TOKEN:-}" ]; then
    ok "patchers on — EXT_PATCHES_TOKEN from the environment, written live into .env"
  elif [ -n "$(env_val EXT_PATCHES_TOKEN)" ]; then
    export EXT_PATCHES_TOKEN="$(env_val EXT_PATCHES_TOKEN)"
    ok "patchers on — token read from this repo's .devcontainer/.env (as release-check does), written live into .env"
  else
    die "--pat but no token. Export EXT_PATCHES_TOKEN, or write $MACHINE_ENV (mode 600):
   EXT_PATCHES_REPO=meitogi/claude-ext-patchs
   EXT_PATCHES_REF=
   EXT_PATCHES_TOKEN=<the PAT>"
  fi
else
  info "patchers off (--pat to wire them)"
fi
if [ "$SHARED" = 1 ]; then
  CREDS="$(env_val CLAUDE_CREDS_VOLUME)"
  [ -n "$CREDS" ] || CREDS="claude-creds-$(env_val DC_PROJECT)"
  if [ "$SIMULATE" = 1 ] || docker volume inspect "$CREDS" >/dev/null 2>&1; then ok "creds: $CREDS (shared with this repo's container)"
  else info "creds: $CREDS does not exist on this machine — the project opens without a Claude session"; fi
else
  CREDS="claude-creds-$DC_PROJECT"; info "creds: $CREDS, throwaway (--shared-creds for a signed-in session)"
fi

# ---- 3. sweep ---------------------------------------------------------------
sect "3. sweep $DC_PROJECT"
if [ "$SIMULATE" != 1 ]; then
  if [ -f "$SCRATCH/.devcontainer/docker-compose.yml" ]; then
    ( cd "$SCRATCH/.devcontainer" && docker compose down -v --remove-orphans --rmi local ) >/dev/null 2>&1 || true
  fi
  for c in $(docker ps -a --format '{{.Names}}' | grep -i "$DC_PROJECT" || true); do docker rm -f "$c" >/dev/null && info "container removed: $c"; done
  for v in $(docker volume ls --format '{{.Name}}' | grep -i "$DC_PROJECT" || true); do docker volume rm "$v" >/dev/null && info "volume removed: $v"; done
  for i in $(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -i "$DC_PROJECT" || true); do docker image rm -f "$i" >/dev/null && info "image removed: $i"; done
fi
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; git -C "$SCRATCH" init -q
ok "$SCRATCH (empty git repo)"

# ---- 4. scaffold ------------------------------------------------------------
sect "4. devc init --yes"
INSTALL=""; [ "$PUBLISHED" = 1 ] && [ "$SIMULATE" != 1 ] || INSTALL="--no-install"
$DEVC init --yes $INSTALL --project-id "$DC_PROJECT" --display-name "Bare project" \
  --creds-volume "$CREDS" --stack node --cc "${PIN##*-cc}" $EXT_ARGS "$SCRATCH" | sed 's/^/   /'
ENV="$SCRATCH/.devcontainer/.env"
if [ "$PUBLISHED" != 1 ]; then
  printf '\n# === wtf image bare: the image of this tree, not the pin ===\nBASE_IMAGE=%s\n' "$IMG" >> "$ENV"
  rm -f "$SCRATCH"/meitogi-devcontainer-cli-*.tgz
  ( cd "$CLI_DIR" && env -u npm_config_dry_run npm pack --pack-destination "$SCRATCH" --silent ) >/dev/null
  TGZ="$(ls -1 "$SCRATCH"/meitogi-devcontainer-cli-*.tgz | tail -1)"
  # The dead registry is the assertion: this install, and the npx the shim
  # runs at boot, resolve the checkout offline or not at all.
  ( cd "$SCRATCH" && env -u npm_config_dry_run npm install --save-dev --no-audit --no-fund --ignore-scripts \
      --registry=http://127.0.0.1:9/ "$TGZ" ) >"$SCRATCH/.cli-install.log" 2>&1 \
    || die "offline install of ${TGZ##*/} failed — see $SCRATCH/.cli-install.log"
  ok "initializeCommand will run ${TGZ##*/} (installed offline)"
fi

# ---- 5. controls ------------------------------------------------------------
sect "5. controls"
eff="$(grep -h '^BASE_IMAGE=' "$ENV" | tail -1 | cut -d= -f2- || true)"
[ "${eff:-$PIN}" = "$IMG" ] && ok "effective image: $IMG" || die "effective image ${eff:-$PIN}, expected $IMG"
grep -E "^(DC_PROJECT|CLAUDE_CREDS_VOLUME|EXT_PATCHES_REPO)=" "$ENV" | sed 's/^/   /'
if [ "$PAT" = 1 ]; then
  tok="$(grep -E '^EXT_PATCHES_TOKEN=' "$ENV" || true)"
  case "$tok" in
    "") die "EXT_PATCHES_TOKEN line missing — init did not wire the patchers" ;;
    "EXT_PATCHES_TOKEN=") ok "EXT_PATCHES_TOKEN empty, filled at boot from $MACHINE_ENV" ;;
    *) ok "EXT_PATCHES_TOKEN set (${#tok} chars)" ;;
  esac
else
  grep -q '^EXT_PATCHES_' "$ENV" && die "patchers lines present without --pat" || ok "no EXT_PATCHES_* line"
fi
CHECK="$PROJECT_ROOT/plans/devcontainer-v3/migrate/check-in-container.sh"
if [ -f "$CHECK" ]; then cp "$CHECK" "$SCRATCH/check-in-container.sh"; ok "check-in-container.sh copied at the root"
else info "no plans/devcontainer-v3/migrate/check-in-container.sh here — nothing copied"; fi

# ---- 6. open ----------------------------------------------------------------
sect "6. open"
[ "$SIMULATE" = 1 ] && { info "(simulate) not opening VS Code"; exit 0; }
ctx="$(docker context show 2>/dev/null || echo desktop-linux)"
authority="$(python3 - "$SCRATCH" "$ctx" <<'PY'
import json, sys
folder, context = sys.argv[1], sys.argv[2]
cfg = folder + "/.devcontainer/devcontainer.json"
o = {"hostPath": folder, "localDocker": False, "settings": {"context": context},
     "configFile": {"$mid": 1, "fsPath": cfg, "external": "file://" + cfg, "path": cfg, "scheme": "file"}}
print("dev-container+" + json.dumps(o, separators=(",", ":")).encode().hex())
PY
)"
cat <<TXT
   code --folder-uri "vscode-remote://${authority}/workspace"
   (fallback: code "$SCRATCH", then "Dev Containers: Reopen in Container")
   Inside, once booted: bash /workspace/check-in-container.sh
   Expected on a bare project: § 2 "(no overlay fragment)", § 3 no project skill
   dir, § 5 patchers only with --pat, § 5b exactly one sync-creds command,
   § 6 "(no daemon startup file)".
TXT
code --folder-uri "vscode-remote://${authority}/workspace"
