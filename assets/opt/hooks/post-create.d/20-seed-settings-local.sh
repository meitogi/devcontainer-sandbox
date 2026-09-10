#!/usr/bin/env bash
# @name seed-settings-local
# @phase post-create
# @required false
# @description Seed .claude/settings.local.json from .example baseline if missing.
# Mirrors install.sh's initial seeding; this rerun-safe check restores the live
# file after a rebuild or accidental delete. Fallback path covers the dogfood
# repo, which never runs install.sh on itself.

set -eE

EX=/workspace/.claude/settings.local.json.example
[ -f "$EX" ] || EX=/workspace/templates/v2/.claude/settings.local.json.example
LIVE=/workspace/.claude/settings.local.json

if [ -f "$EX" ] && [ ! -f "$LIVE" ]; then
  mkdir -p /workspace/.claude
  cp "$EX" "$LIVE"
  echo "✓ .claude/settings.local.json seeded from ${EX#/workspace/}"
fi
