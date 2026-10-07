#!/usr/bin/env bash
# @name seed-settings-local
# @phase post-create
# @required false
# @description Seed .claude/settings.local.json from .example baseline if missing.
# Mirrors the seeding `devc init` does at scaffold time; this rerun-safe check
# restores the live file after a rebuild or accidental delete.

set -eE

EX=/workspace/.claude/settings.local.json.example
LIVE=/workspace/.claude/settings.local.json

if [ -f "$EX" ] && [ ! -f "$LIVE" ]; then
  mkdir -p /workspace/.claude
  cp "$EX" "$LIVE"
  echo "✓ .claude/settings.local.json seeded from ${EX#/workspace/}"
fi
