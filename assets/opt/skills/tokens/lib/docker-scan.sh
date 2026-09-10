#!/usr/bin/env bash
# tokens skill — docker-volume scanner for cross-devcontainer aggregation.
#
# Emits registry data from any devcontainer's `claude-code-config-*` named
# volume without a bind-mount or compose modification. Spawns one alpine
# per volume, reads read-only. Never exits non-zero — docker missing or
# no matching volumes yields empty stdout so callers treat it as
# "local-only mode".
#
# Subcommands:
#   list-volumes                       — one volume name per line
#   read-projects <vol>                — cat projects.jsonl from <vol>
#   append-project-event <vol> <line>  — append one JSONL line to <vol>'s registry
#   rewrite-projects <vol> <file>      — atomic rewrite of <vol>'s registry from local <file>
#
# All commands are best-effort. Docker absent → silent no-op.

set -u

VOLUME_PREFIX='claude-code-config-'
ALPINE_IMAGE='alpine:latest'

have_docker() {
  command -v docker >/dev/null 2>&1
}

cmd_list_volumes() {
  have_docker || return 0
  docker volume ls --format '{{.Name}}' 2>/dev/null \
    | grep -E "^${VOLUME_PREFIX}" \
    | sort -u \
    || true
}

cmd_read_projects() {
  local vol="${1:-}"
  [ -n "$vol" ] || return 0
  have_docker || return 0
  docker run --rm -v "${vol}:/data:ro" "$ALPINE_IMAGE" \
    cat /data/tokens/projects.jsonl 2>/dev/null \
    || true
}

cmd_append_project_event() {
  local vol="${1:-}" line="${2:-}"
  [ -n "$vol" ] && [ -n "$line" ] || return 0
  have_docker || return 0
  printf '%s\n' "$line" | docker run --rm -i -v "${vol}:/data" "$ALPINE_IMAGE" \
    sh -c 'mkdir -p /data/tokens && cat >> /data/tokens/projects.jsonl' \
    2>/dev/null || true
}

cmd_rewrite_projects() {
  local vol="${1:-}" src="${2:-}"
  [ -n "$vol" ] && [ -f "$src" ] || return 0
  have_docker || return 0
  cat "$src" | docker run --rm -i -v "${vol}:/data" "$ALPINE_IMAGE" \
    sh -c 'mkdir -p /data/tokens && cat > /data/tokens/projects.jsonl.new && mv /data/tokens/projects.jsonl.new /data/tokens/projects.jsonl' \
    2>/dev/null || true
}

case "${1:-}" in
  list-volumes)          shift; cmd_list_volumes "$@" ;;
  read-projects)         shift; cmd_read_projects "$@" ;;
  append-project-event)  shift; cmd_append_project_event "$@" ;;
  rewrite-projects)      shift; cmd_rewrite_projects "$@" ;;
  ''|-h|--help)
    cat <<'EOF'
docker-scan.sh — cross-devcontainer volume helper (best-effort, never fails)

Subcommands:
  list-volumes                       one volume name per line
  read-projects <vol>                stdout: /data/tokens/projects.jsonl from <vol>
  append-project-event <vol> <line>  append one JSONL line to <vol>'s registry
  rewrite-projects <vol> <file>      atomic rewrite of <vol>'s registry
EOF
    ;;
  *)
    printf 'unknown subcommand: %s\n' "$1" >&2
    exit 0
    ;;
esac
