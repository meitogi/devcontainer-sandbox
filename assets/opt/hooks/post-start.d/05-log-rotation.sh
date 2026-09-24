#!/usr/bin/env bash
# @name log-rotation
# @phase post-start
# @required false
# @description Drop hook logs older than 7 days from .devcontainer/tmp/logs/. Runs at every container start, gating disk usage of the phase logs written by the dispatcher.

set -eE

mkdir -p /workspace/.devcontainer/tmp/logs 2>/dev/null || true
find /workspace/.devcontainer/tmp/logs -maxdepth 1 -type f \
    \( -name '*.log' -o -name '*.trace' \) -mtime +7 -delete 2>/dev/null || true
