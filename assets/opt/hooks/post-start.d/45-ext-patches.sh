#!/usr/bin/env bash
# @name ext-patches
# @phase post-start
# @required false
# @description Applies patchers to the baked VS Code extension, from a local directory (EXT_PATCHES_DIR), a pinned source tarball (EXT_PATCHES_REPO/REF/TOKEN), or the project's own patchers under $DEVC_CONFIG_DIR/claude/vscode-ext-patchs — which are merged over the other two and are a source on their own. Ships no default and names no repository: with none of the three present it exits 0 in silence, which is this image's nominal state.

# Every restart: normally a sentinel check that exits in milliseconds without touching the network. Re-applies only if a VS Code extension update replaced the bundle.
#
# All of the logic lives in ext-patches-sync so the two phases cannot drift.
# @required false, and the tool never returns non-zero: patchers are the
# operator's business, and not having them must never stop a container.

set -uo pipefail
command -v ext-patches-sync >/dev/null 2>&1 || exit 0
ext-patches-sync || true
