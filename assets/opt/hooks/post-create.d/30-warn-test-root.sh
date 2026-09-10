#!/usr/bin/env bash
# @name warn-test-root
# @phase post-create
# @required false
# @description Warn if test-root has sudo access — the real risk is the sudoers entry, not the file.

set -eE

if sudo -l 2>/dev/null | grep -q "test-root"; then
  echo ""
  echo "⚠️  test-root.sh has sudo access! Remove the test RUN line in Dockerfile before committing."
fi
