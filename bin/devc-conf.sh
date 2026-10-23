#!/usr/bin/env bash
# devc-conf.sh — one parser for the `.txt` config family.
#
# SOURCED, never executed :
#   . /usr/local/bin/devc-conf.sh
#   while IFS= read -r entry; do … ; done < <(conf_entries "$file")
#
# The format, one contract for every list the image reads — the firewall
# allowlists, hooks/disabled.txt, skills/disabled.txt :
#
#   - one entry per line
#   - blank lines ignored
#   - a line whose first non-blank character is `#` is a comment
#   - an inline `# …` is cut off
#   - leading and trailing whitespace trimmed, a trailing CR tolerated
#   - a last line without a trailing newline still counts
#   - a missing file means "no entries", not an error
#
# Every reader used to hand-roll those rules, and no two spellings agreed :
# `sed 's/#.*//' | tr -d '[:space:]'`, `${line%%#*}` inside a read loop,
# `grep -cE '^[[:space:]]*[^#[:space:]]'`. They disagreed about interior
# whitespace and about the unterminated last line, which is exactly the kind
# of difference nobody notices until a config silently does nothing.
#
# Interior whitespace is PRESERVED here. `ports_entries` strips it, because a
# `host : port` entry has never meant anything else — that squeeze is a ports
# rule, not a format rule, and it stays where it belongs.

# Emits the active entries of a config file, one per line.
#
# The trim is pure bash — no `xargs`, which would choke on quotes inside a
# comment — and inlined rather than delegated to a helper, because a `$(…)`
# per line forks a subshell per line and this runs on the boot path.
conf_entries() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  local raw line
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    # No separate CR strip: `\r` is in [:space:], so the trailing trim below
    # already takes it. The CRLF assertions in conf.test.sh / parse-ports.sh
    # are what keep that true.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] && printf '%s\n' "$line"
  done < "$f"
  # The `&&` above is the loop's last command, so a file whose final line is
  # blank or a comment would make the whole function exit 1 — and a caller
  # running under `set -e` would die on a config file that is merely
  # well-formatted. "No entries" is never an error here.
  return 0
}

# ports.txt — one `host:port` per line, the direct-TCP allowlist. Renamed from
# direct-tcp-allow.txt (which described the mechanism, an ACCEPT that bypasses
# the proxy, rather than the intent). `ports` is the symmetric counterpart of
# `domains`: names go through the proxy, ports are reached directly.
#
# One resolver, one parser, both used by every site that reads the file. There
# used to be eight hand-rolled copies, two of them in init-firewall.sh alone,
# 200 lines apart and disagreeing about whether the path was absolute.
ports_file() {
  local dir="${1:-${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}}"
  if [ -f "$dir/ports.txt" ]; then
    # Both present: the new name wins, and the old one is not silently applied.
    [ -f "$dir/direct-tcp-allow.txt" ] &&
      echo "⚠ both ports.txt and direct-tcp-allow.txt exist — reading ports.txt, ignoring the old one" >&2
    printf '%s' "$dir/ports.txt"
  elif [ -f "$dir/direct-tcp-allow.txt" ]; then
    echo "⚠ direct-tcp-allow.txt is deprecated — rename it to ports.txt" >&2
    printf '%s' "$dir/direct-tcp-allow.txt"
  fi
}

# The cleaned `host:port` entries of a ports file, one per line. The extra
# squeeze over conf_entries drops interior whitespace, so `host : 9222` and
# `host:9222` are the same entry.
#
# The squeeze is per line, not `| tr -d '[:space:]'` over the stream: that
# class includes `\n`, so a stream-wide delete glues every entry into one
# (`host:9222ollama:11434`). test-firewall.sh shipped exactly that.
ports_entries() {
  local entry
  while IFS= read -r entry; do
    entry="${entry//[[:space:]]/}"
    [ -n "$entry" ] && printf '%s\n' "$entry"
  done < <(conf_entries "${1:-}")
}

# inbound.txt — one `udp:<port>` or `tcp:<port>` per line, the ports a peer
# outside the container may open a connection to. The only exception to
# `INPUT DROP` ; baked, never read from the workspace (init-firewall.sh § 5a).
#
# Stricter than ports_entries, on purpose : a ports.txt typo opens nothing (the
# host does not resolve), an inbound typo would reach iptables. So every line is
# validated here and a bad one is named on stderr and dropped — never applied,
# never silently ignored. No ranges : one port per line.
#
# A `udp:<port>` line may end in the word `out`, whitespace-separated : that
# port may also OPEN new UDP flows to public addresses (STUN, ICE hole punching
# — a WebRTC peer reaching the internet). It is the one place the firewall lets
# an unaudited channel out, so the grammar is as strict as the rest : `out`
# exactly, last on the line, udp only. The entry is emitted as `udp:<port> out`
# (one space) ; init-firewall.sh § 5a decides what it means per mode.
inbound_entries() {
  local raw entry flag port
  while IFS= read -r raw; do
    entry="$raw" flag=""
    case "$entry" in *[[:space:]]out) flag=" out"; entry="${entry%out}" ;; esac
    entry="${entry//[[:space:]]/}"
    port="${entry#*:}"
    if ! [[ "$entry" =~ ^(udp|tcp):[1-9][0-9]{0,4}$ ]] || [ "$port" -gt 65535 ]; then
      echo "⚠ inbound.txt: rejected '$raw' — expected udp:<port> or tcp:<port>, port 1-65535, optionally followed by ' out'" >&2
    elif [ -n "$flag" ] && [ "${entry%%:*}" != udp ]; then
      echo "⚠ inbound.txt: rejected '$raw' — 'out' is udp only" >&2
    else
      printf '%s\n' "$entry$flag"
    fi
  done < <(conf_entries "${1:-}")
}
