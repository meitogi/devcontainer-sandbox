// ANSI constants shared by the visual-loop scripts.
//
// Vendored, not imported: the scripts were authored in a tree where these lived
// at `scripts/lib/colors.mjs` two levels above them. That file ships in no
// project and exists in no tree — every one of the five importers was therefore
// broken on import, everywhere, before this copy. The values below are not a
// guess: they are the ones `agents-watch.mjs` inlined verbatim for the same six
// names, with the same stated reason (one convention, no second import path).
//
// Bright variants (`31;1`) rather than plain (`31`) — that is what the inlined
// copy carries, and a duller red here would silently change every warning.

export const RESET = '\x1b[0m'
export const BOLD = '\x1b[1m'
export const DIM = '\x1b[2m'
export const RED = '\x1b[31;1m'
export const GREEN = '\x1b[32;1m'
export const YELLOW = '\x1b[33;1m'
