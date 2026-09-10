"""Shared utilities for vscode-ext-patchs/*.py scripts.

Surface
-------
- ANSI color constants
- banner(title, reason, impact_lines): generalised red banner
- resolve_ext_dir(argv): argv[1] or autodiscover anthropic.claude-code-*
- check_files(ext_dir, names): banner + sys.exit(1) if any required file
  is missing

Each patch script imports from here via `from _common import ...`. The
script's directory is auto-added to sys.path[0], so no package layout
is needed.
"""

import os
import sys
from pathlib import Path

RED, YELLOW, GREEN, BOLD, RESET = (
    "\033[31m", "\033[33m", "\033[32m", "\033[1m", "\033[0m"
)


def banner(title, reason, impact_lines):
    bar = "═" * 78
    out = [f"{RED}{BOLD}{bar}", f"  ⚠  {title}", f"  Reason: {reason}"]
    for line in impact_lines:
        out.append(f"  {line}")
    out.append(f"{bar}{RESET}")
    print("\n" + "\n".join(out) + "\n", file=sys.stderr)


def resolve_ext_dir(argv):
    if len(argv) >= 2:
        return Path(argv[1])
    home = Path(os.environ.get("HOME", "/home/node"))
    base = home / ".vscode-server" / "extensions"
    if not base.is_dir():
        banner(
            "CLAUDE CODE EXTENSION DIRECTORY NOT FOUND",
            f"{base} does not exist",
            ["No EXT_DIR arg given; auto-discovery failed",
             "Patch cannot proceed"],
        )
        sys.exit(1)
    candidates = sorted(base.glob("anthropic.claude-code-*"))
    if not candidates:
        banner(
            "CLAUDE CODE EXTENSION NOT FOUND",
            f"No anthropic.claude-code-* under {base}",
            ["No EXT_DIR arg given; auto-discovery failed",
             "Patch cannot proceed"],
        )
        sys.exit(1)
    return candidates[-1]


def check_files(ext_dir, names):
    missing = [n for n in names if not (ext_dir / n).is_file()]
    if missing:
        banner(
            "EXTENSION FILE(S) MISSING",
            f"In {ext_dir}: {', '.join(missing)}",
            ["Patch cannot proceed"],
        )
        sys.exit(1)
