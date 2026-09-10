#!/usr/bin/env bash
# firewall-digest.sh — one implementation of the firewall source digest.
#
# SOURCED, never executed :
#   . /usr/local/bin/firewall-digest.sh
#   digest=$(fw_sources_digest /etc/devcontainer-firewall 0)
#
# Two callers must agree byte-for-byte on this value :
#   - firewall-docker-setup.sh, at image build time, records it in
#     <cfg>/effective/sources.sha256
#   - init-firewall.sh, at every boot, recomputes it and installs the frozen
#     effective/ set only when it matches
#
# A second copy of this logic would drift. Drifting the safe way costs a
# permanent cache miss (silent, harmless) ; drifting the unsafe way serves a
# stale ruleset with no log line. Hence one file, sourced by both.
#
# What goes in — exactly the inputs compile-policy.py reads in compile mode
# (mode_compile), plus the two things that change the meaning of its output
# without being parser inputs :
#
#   domains.txt              compile-policy.py mode_compile
#   domains.local.txt        idem
#   domains.d/*.txt          idem, sorted
#   policy.d/*.yaml          idem, sorted
#   policy.local.d/*.yaml    idem, sorted
#   default-mode             selects --split-local and the ipset name
#   compile-policy.py        compiler semantics drift across base-image bumps
#   local-included           the bake-time .local opt-in decision
#
# What stays out, because compile-policy.py never opens them : dnsmasq.conf,
# ports.txt (feeds dnsmasq-injections.conf, which init-firewall.sh
# truncates and rebuilds on every boot anyway), tests/, addons/,
# domains.android.txt, domains.capacitor-android.txt.

# One line per file : "<sha256>  <relpath>", or "absent  <relpath>" when it is
# missing. The relpath matters — without it, swapping two files' contents would
# not move the digest.
_fw_digest_entry() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    printf '%s  %s\n' "$(sha256sum < "$path" | cut -d' ' -f1)" "$label"
  else
    printf 'absent  %s\n' "$label"
  fi
}

# A "dir" header is emitted whether or not the directory exists, so an absent
# directory and an empty one hash the same — they compile the same too.
_fw_digest_dir() {
  local dir="$1" pattern="$2" label="$3" f
  printf 'dir  %s\n' "$label"
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _fw_digest_entry "$f" "$label/${f##*/}"
  done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print | LC_ALL=C sort)
}

# fw_sources_digest <config-dir> <local-included:0|1>
fw_sources_digest() {
  local cfg="$1" local_included="${2:-0}"
  local compiler="${FW_COMPILER:-/usr/local/bin/compile-policy.py}"
  {
    _fw_digest_entry "$cfg/domains.txt"       "domains.txt"
    _fw_digest_entry "$cfg/domains.local.txt" "domains.local.txt"
    _fw_digest_entry "$cfg/default-mode"      "default-mode"
    _fw_digest_dir   "$cfg/domains.d"      '*.txt'  "domains.d"
    _fw_digest_dir   "$cfg/policy.d"       '*.yaml' "policy.d"
    _fw_digest_dir   "$cfg/policy.local.d" '*.yaml' "policy.local.d"
    _fw_digest_entry "$compiler" "compile-policy.py"
    printf 'local-included  %s\n' "$local_included"
  } | LC_ALL=C sha256sum | cut -d' ' -f1
}
