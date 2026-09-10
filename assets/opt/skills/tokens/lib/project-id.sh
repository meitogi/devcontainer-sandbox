#!/bin/bash
# tokens skill — resolve PROJECT_ROOT and PROJECT_ID.
# Sourced by hook.sh (not executed).

resolve_project_root() {
  local d start
  start="${TOKENS_START_DIR:-$(pwd)}"
  d="$start"
  while [ "$d" != "/" ]; do
    if [ -d "$d/.git" ]; then
      echo "$d"
      return 0
    fi
    d=$(dirname "$d")
  done
  echo "$start"
}

resolve_project_id() {
  local id
  id=$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null)
  if [ -n "$id" ]; then echo "$id"; return 0; fi
  if [ -n "$HOST_WORKSPACE_PATH" ]; then echo "$HOST_WORKSPACE_PATH"; return 0; fi
  id=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$id" ]; then echo "$id"; return 0; fi
  echo "$PROJECT_ROOT"
}

PROJECT_ROOT=$(resolve_project_root)
PROJECT_ID=$(resolve_project_id)
