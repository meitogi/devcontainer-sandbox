#!/usr/bin/env bash
# @name ext-patches
# @phase on-create
# @required false
# @description Applies patchers to the baked VS Code extension, from a local directory (EXT_PATCHES_DIR), a source tarball (EXT_PATCHES_REPO/TOKEN, EXT_PATCHES_REF pinned or, unset, this Claude Code version's newest tag), or the project's own patchers under $DEVC_CONFIG_DIR/claude/vscode-ext-patchs — which are merged over the other two and are a source on their own. Ships no default and names no repository: with none of the three present it exits 0 in silence, which is this image's nominal state.

# First boot: the extension is freshly baked, so this is where patchers actually get fetched and applied.
#
# All of the logic lives in ext-patches-sync so the two phases cannot drift.
# @required false, and the tool never returns non-zero: patchers are the
# operator's business, and not having them must never stop a container.
#
# --create is the ONLY difference between this fragment and the post-start one:
# an auto ref asks /tags here, and resolves from the cache at every restart.
# The cache lives in the workspace and survives a rebuild, so without this a
# new container kept booting the line some earlier container had cached —
# measured on symptems 2026-10-05, r2 served a day after r3 was published.

set -uo pipefail
command -v ext-patches-sync >/dev/null 2>&1 || exit 0
ext-patches-sync --create || true
