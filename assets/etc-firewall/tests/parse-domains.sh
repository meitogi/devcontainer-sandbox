#!/usr/bin/env bash
# Unit tests for compile-policy.py extended-syntax parser.
# Standalone — only requires python3 + jq.
# Usage: ./parse-domains.sh

set -uo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
# Overridable for the repo layout (bin/compile-policy.py) — the default is
# the legacy in-tree location kept for in-container runs.
COMPILE="${COMPILE_POLICY:-$THIS_DIR/../compile-policy.py}"

if [ ! -f "$COMPILE" ]; then
  echo "❌ compile-policy.py not found at $COMPILE" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq required (apt install jq)" >&2
  exit 1
fi

PASS=0
FAIL=0

# parse_str <input_text> → JSON {entries, errors} on stdout
parse_str() {
  local tmp; tmp=$(mktemp)
  printf '%s' "$1" > "$tmp"
  python3 "$COMPILE" --parse-only --json "$tmp" 2>/dev/null
  rm -f "$tmp"
}

expect_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✔ $desc"
    PASS=$((PASS+1))
  else
    echo "  ❌ $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAIL=$((FAIL+1))
  fi
}

host_of()        { echo "$1" | jq -r '.entries[0].host'; }
methods_of()     { echo "$1" | jq -c '.entries[0].methods'; }
paths_of()       { echo "$1" | jq -c '.entries[0].paths'; }
disable_of()     { echo "$1" | jq -r '.entries[0].disable'; }
errors_count()   { echo "$1" | jq '.errors | length'; }
entries_count()  { echo "$1" | jq '.entries | length'; }

# --- A. Format 1 — bare host ---
echo "▌ Format 1 — bare host"
out=$(parse_str 'api.example.com')
expect_eq "1. bare host parsed"              "$(host_of "$out")"     "api.example.com"
expect_eq "1b. bare host defaults to GET"    "$(methods_of "$out")"  '["GET"]'
expect_eq "1c. bare host no paths"           "$(paths_of "$out")"    '[]'

out=$(parse_str '*.cdn.example.com')
expect_eq "2. wildcard prefix stripped"      "$(host_of "$out")"     "cdn.example.com"

out=$(parse_str 'api.example.com  # inline comment')
expect_eq "3. inline comment stripped"       "$(host_of "$out")"     "api.example.com"

# --- B. Format 2 — inline methods ---
echo "▌ Format 2 — methods inline"
out=$(parse_str '[POST] api.test.com')
expect_eq "4. [POST] single method"          "$(methods_of "$out")"  '["POST"]'

out=$(parse_str '[POST,DELETE] api.foo.com')
expect_eq "5. [POST,DELETE] CSV"             "$(methods_of "$out")"  '["POST","DELETE"]'

out=$(parse_str '[POST, DELETE] api.bar.com')
expect_eq "6. CSV with spaces tolerated"     "$(methods_of "$out")"  '["POST","DELETE"]'

out=$(parse_str '[*] api.internal.com')
expect_eq "7. [*] all-methods sentinel"      "$(methods_of "$out")"  '["*"]'

out=$(parse_str '[post,get] api.case.com')
expect_eq "8. case-insensitive normalize"    "$(methods_of "$out")"  '["POST","GET"]'

# --- C. Format 3 — multi-line indented paths ---
echo "▌ Format 3 — multi-line indented paths"
input='[*] api.anthropic.com
  /v1/messages
  /v1/files
  /v1/usage'
out=$(parse_str "$input")
expect_eq "9. 3 paths attached"              "$(paths_of "$out")"    '["/v1/messages","/v1/files","/v1/usage"]'
expect_eq "9b. one entry only"               "$(entries_count "$out")"  "1"

out=$(parse_str $'[*] api.foo.com\n /v1/wrong')
expect_eq "10. 1-space indent → error"       "$(errors_count "$out")"   "1"

out=$(parse_str $'[*] api.foo.com\n    /v1/wrong')
expect_eq "11. 4-space indent → error"       "$(errors_count "$out")"   "1"

out=$(parse_str $'[*] api.foo.com\n\t/v1/wrong')
expect_eq "12. tab indent → error"           "$(errors_count "$out")"   "1"

input='[*] api.foo.com
  /v1/messages

  /v1/files'
out=$(parse_str "$input")
expect_eq "13. blank line in block tolerated" "$(paths_of "$out")"   '["/v1/messages","/v1/files"]'

input='[*] api.foo.com
  /v1/messages
  # comment in block
  /v1/files'
out=$(parse_str "$input")
expect_eq "14. comment-only in block tolerated" "$(paths_of "$out")" '["/v1/messages","/v1/files"]'

input='[*] api.foo.com
  /v1/messages
api.bar.com'
out=$(parse_str "$input")
expect_eq "15. block terminated by next host" "$(entries_count "$out")" "2"

# --- D. Format 4 — single-line path ---
echo "▌ Format 4 — single-line path"
out=$(parse_str 'POST api.anthropic.com/v1/messages')
expect_eq "16. bare method + path"           "$(methods_of "$out")"  '["POST"]'
expect_eq "16b. bare method + path: path"    "$(paths_of "$out")"    '["/v1/messages"]'

out=$(parse_str '[GET,POST] api.foo.com/files')
expect_eq "17. bracket methods + path"       "$(paths_of "$out")"    '["/files"]'

# --- E. Format 5 — wildcards ---
echo "▌ Format 5 — wildcards"
out=$(parse_str '[GET] api.github.com/repos/anthropics/*')
expect_eq "18. trailing * preserved in path" "$(paths_of "$out")"    '["/repos/anthropics/*"]'

out=$(parse_str '[POST] *.statsig.com')
expect_eq "19. wildcard host stripped"       "$(host_of "$out")"     "statsig.com"
expect_eq "19b. wildcard host methods"       "$(methods_of "$out")"  '["POST"]'

out=$(parse_str '[GET] *.foo.com/api/*')
expect_eq "20. wildcard host + path: host"   "$(host_of "$out")"     "foo.com"
expect_eq "20b. wildcard host + path: path"  "$(paths_of "$out")"    '["/api/*"]'

# --- F. Retro-compat (A1 simple syntax) ---
echo "▌ Retro-compat (A1)"
out=$(parse_str '[POST] host.com')
expect_eq "21. A1 [POST] host equivalent"    "$(methods_of "$out")"  '["POST"]'
out=$(parse_str 'host.com')
expect_eq "22. bare host unchanged"          "$(host_of "$out")"     "host.com"

# --- G. Override / disable ---
echo "▌ Override / disable"
out=$(parse_str '!disable api.anthropic.com')
expect_eq "23. !disable flag"                "$(disable_of "$out")"  "true"
expect_eq "23b. !disable methods empty"      "$(methods_of "$out")"  '[]'

out=$(parse_str '!disable *.statsig.com')
expect_eq "24. !disable + wildcard: host"    "$(host_of "$out")"     "statsig.com"
expect_eq "24b. !disable + wildcard: flag"   "$(disable_of "$out")"  "true"

out=$(parse_str '!disable nonexistent.com')
expect_eq "25. !disable nonexistent (no err)" "$(errors_count "$out")" "0"

# --- H. Parse errors ---
echo "▌ Parse errors"
out=$(parse_str '[POST api.foo.com')
expect_eq "26. malformed bracket → error"    "$(errors_count "$out")"   "1"

out=$(parse_str '[GET] api foo.com')
expect_eq "27. invalid hostname char → error" "$(errors_count "$out")"  "1"

out=$(parse_str '[FOO] api.bar.com')
expect_eq "28. unknown method → error"       "$(errors_count "$out")"   "1"

out=$(parse_str '[] api.foo.com')
expect_eq "29. empty methods bracket → error" "$(errors_count "$out")"  "1"

out=$(parse_str '  /orphan-path')
expect_eq "30. orphan indented path → error" "$(errors_count "$out")"   "1"

# --- I. Additive merge across domains.txt + domains.d/*.txt (F2) ---
echo "▌ Additive cross-file merge (F2)"

# Helper: build a temp config dir + compile to a temp policy file.
compile_cfg() {
  local cfg_dir="$1"
  local out_pol; out_pol=$(mktemp)
  local out_dns; out_dns=$(mktemp)
  python3 "$COMPILE" --config-dir "$cfg_dir" \
    --out-policy "$out_pol" --out-dnsmasq "$out_dns" >/dev/null 2>&1 \
    && cat "$out_pol"
  rm -f "$out_pol" "$out_dns"
}

# Case 31: same host in domains.txt + domains.d/npm.txt → paths concatenate
cfg=$(mktemp -d)
mkdir -p "$cfg/domains.d" "$cfg/policy.d" "$cfg/policy.local.d"
cat > "$cfg/domains.txt" <<EOF
[GET,HEAD] registry.npmjs.org
  /@anthropic-ai/*
EOF
cat > "$cfg/domains.d/npm.txt" <<EOF
[GET,HEAD] registry.npmjs.org
  /express*
  /vite*
EOF
touch "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
paths_cnt=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print(len(d['domains']['registry.npmjs.org']['paths']))")
expect_eq "31. cross-file paths merged (count)" "$paths_cnt" "3"
has_anthropic=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print('yes' if '/@anthropic-ai/*' in d['domains']['registry.npmjs.org']['paths'] else 'no')")
expect_eq "31b. baseline path preserved"        "$has_anthropic"      "yes"
has_express=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print('yes' if '/express*' in d['domains']['registry.npmjs.org']['paths'] else 'no')")
expect_eq "31c. domains.d path added"           "$has_express"        "yes"
rm -rf "$cfg"

# Case 32: domains.d/ absent → only domains.txt processed
cfg=$(mktemp -d)
mkdir -p "$cfg/policy.d" "$cfg/policy.local.d"
echo '[GET,HEAD] api.example.com' > "$cfg/domains.txt"
touch "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
host_present=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print('yes' if 'api.example.com' in d['domains'] else 'no')")
expect_eq "32. domains.d/ absent → baseline still works" "$host_present" "yes"
rm -rf "$cfg"

# Case 33: !disable in domains.local.txt removes host added by domains.d/
cfg=$(mktemp -d)
mkdir -p "$cfg/domains.d" "$cfg/policy.d" "$cfg/policy.local.d"
echo '[GET,HEAD] registry.npmjs.org' > "$cfg/domains.txt"
echo '[GET,HEAD] sketchy-host.com' > "$cfg/domains.d/npm.txt"
echo '  /foo*' >> "$cfg/domains.d/npm.txt"
echo '!disable sketchy-host.com' > "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
disabled=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print('removed' if 'sketchy-host.com' not in d.get('domains', {}) else 'present')")
expect_eq "33. !disable removes host from domains.d/" "$disabled" "removed"
rm -rf "$cfg"

# Case 34: multiple domains.d/*.txt files all loaded
cfg=$(mktemp -d)
mkdir -p "$cfg/domains.d" "$cfg/policy.d" "$cfg/policy.local.d"
echo '[GET,HEAD] api.example.com' > "$cfg/domains.txt"
echo '[GET,HEAD] host-a.com' > "$cfg/domains.d/eco-a.txt"
echo '[GET,HEAD] host-b.com' > "$cfg/domains.d/eco-b.txt"
touch "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
both_present=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print('both' if 'host-a.com' in d['domains'] and 'host-b.com' in d['domains'] else 'missing')")
expect_eq "34. multiple domains.d/*.txt loaded"      "$both_present"  "both"
rm -rf "$cfg"

# Case 35: committed !disable (project domains.txt) removes a base-layer
# host shipped via domains.d/ — the 3-level opt-out.
cfg=$(mktemp -d)
mkdir -p "$cfg/domains.d" "$cfg/policy.d" "$cfg/policy.local.d"
printf '[GET] nvd.nist.gov\n  /vuln/*\n[GET] keep-me.com\n' > "$cfg/domains.d/00-base.txt"
printf '!disable nvd.nist.gov\n' > "$cfg/domains.txt"
touch "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
state=$(echo "$pol" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin)['domains']; print(('removed' if 'nvd.nist.gov' not in d else 'present') + '+' + ('kept' if 'keep-me.com' in d else 'lost'))")
expect_eq "35. committed !disable removes base-layer host" "$state" "removed+kept"
rm -rf "$cfg"

# Case 36: committed !disable + redeclare in the SAME file — the disabling
# file's own entries survive, the base definition is dropped.
cfg=$(mktemp -d)
mkdir -p "$cfg/domains.d" "$cfg/policy.d" "$cfg/policy.local.d"
printf '[GET] github.com\n  /anthropics/*\n' > "$cfg/domains.d/00-base.txt"
printf '!disable github.com\n[GET] github.com\n  /myorg/*\n' > "$cfg/domains.txt"
touch "$cfg/domains.local.txt"
pol=$(compile_cfg "$cfg")
paths=$(echo "$pol" | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)['domains']['github.com']
pats = ' '.join(sorted(e['path'] for e in d.get('endpoints', [])))
print(pats)")
case "$paths" in
  *myorg*) [[ "$paths" == *anthropics* ]] && redecl="base-leaked" || redecl="narrowed" ;;
  *) redecl="lost" ;;
esac
expect_eq "36. !disable + same-file redeclare narrows"     "$redecl"       "narrowed"
rm -rf "$cfg"

# Case 37: --list-hosts applies the same rule
tmp_base=$(mktemp); tmp_proj=$(mktemp)
printf '[GET] dropme.com\n[GET] keep.com\n' > "$tmp_base"
printf '!disable dropme.com\n[GET] added.com\n' > "$tmp_proj"
hosts=$(python3 "$COMPILE" --list-hosts "$tmp_proj" "$tmp_base" | tr '\n' ' ' | sed 's/ $//')
expect_eq "37. --list-hosts honors committed !disable"     "$hosts"        "added.com keep.com"
rm -f "$tmp_base" "$tmp_proj"

echo
echo "═══════════════════════════════════════════════════════"
echo "  Tests : $((PASS+FAIL)) | ✔ $PASS | ❌ $FAIL"
echo "═══════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
