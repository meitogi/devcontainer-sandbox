#!/usr/bin/env bash
# tokens skill — standalone Anthropic pricing fetcher.
# Zero deps beyond: bash, curl, POSIX awk/sed/grep, date, mv, printf, tr, mkdir.
# Writes ${CLAUDE_HOME:-$HOME/.claude}/tokens/pricing.json atomically ;
# keeps 5 rotating backups. Never crashes: on total failure, pricing.json
# is left untouched.
#
# ============================================================================
# How pricing is obtained
# ============================================================================
#
# The script does NOT hit a single "official pricing API" — Anthropic doesn't
# publish one at the time of writing. Instead it tries a cascade of 5 sources
# top-to-bottom, taking the first one that yields >=1 valid model :
#
#   1. HTTP GET https://api.anthropic.com/v1/models     (type=api)
#      The public models endpoint. Historically returns IDs only, no prices —
#      we still try it in case a future version embeds pricing structurally.
#      If no prices are extractable, we fall through to source 2.
#
#   2. https://docs.claude.com/en/docs/about-claude/pricing   (type=jsonld)
#      Extract every <script type="application/ld+json">…</script> block.
#      JSON-LD is a stable machine-readable format used for SEO / rich
#      snippets — if Anthropic ever exposes prices as structured data, this
#      is where they'll surface first. Fall through if the tag is absent or
#      yields no valid models.
#
#   3. Same URL as source 2 (type=html)
#      Full HTML page. Tags stripped, entities decoded, lowercased, whitespace
#      collapsed, then regex-scanned. The docs page is more stable than the
#      marketing page (fewer redesigns).
#
#   4. https://www.anthropic.com/pricing                     (type=html)
#      Marketing page fallback. Same HTML-strip + regex scan.
#
#   5. Hardcoded fallback (in-script HARDCODED table, mirror of the current
#      lib/pricing.js PRICING dict). Only used if the file doesn't exist yet
#      (first-run seed). On re-run failure the file is left as-is — recap
#      keeps working with the previous snapshot, and pricingFileInfo() in
#      recap.js will warn if the snapshot ages past 90 days.
#
# The source list itself is user-editable at
# ${CLAUDE_HOME}/tokens/pricing-sources.json. Bundled defaults live at
# lib/pricing-sources.json and are copied on first run. Users can flip
# `enabled: false` on any source or edit URLs to survive Anthropic site
# redesigns without touching this script.
#
# ============================================================================
# Parsing strategy (for sources 2-4)
# ============================================================================
#
# After type-specific normalization (jsonld extraction OR html-strip), the
# content is joined to a single line and passed to `extract_prices` (awk).
# The extractor uses two positional passes :
#
#   Pass A — model discovery : `claude-[a-z0-9-]+`, deduplicated, remembering
#            the byte position of each first occurrence. Zero hardcoded list —
#            any new tier (`claude-opus-5`, `claude-agent-pro-6`) shows up on
#            its own.
#
#   Pass B — price discovery : tolerant regex
#            `\$?\s*[0-9]+(\.[0-9]+)?\s*(/|per)\s*(m|million)\s*(tokens?|tok|toks)`
#            catches `$5.00 / MTok`, `5 per million tokens`, `5.00/MTok`, etc.
#            Each match records position + numeric value.
#
# Assembly : for each unique model, take the FIRST FOUR prices whose position
# lies AFTER the model's position, in text order. Map them positionally to
# (input, cache_read, cache_create, output) — this is Anthropic's canonical
# ordering on the pricing pages.
#
# ============================================================================
# Sanity + validation
# ============================================================================
#
#   - Bounds        : 0.01 < each price < 1000 USD/MTok. Out-of-bounds → drop.
#   - Positional    : cache_read < input  AND  input < cache_create  AND
#                     cache_create < output * 3. Any violation → drop.
#                     This catches misalignment (e.g. we grabbed the previous
#                     model's tail 4 prices) without hardcoding tier names.
#   - Field count   : all 4 prices must be present ; else drop.
#   - Global result : >=1 valid model or the whole run is aborted (pricing.json
#                     untouched, exit non-zero, `recap.js` keeps working with
#                     the previous file).
#   - Diff-warn     : if a model's input price moved > 3x vs. the previous
#                     pricing.json, print a warning but DON'T block the write.
#
# ============================================================================
# Atomicity + rollback
# ============================================================================
#
#   - Rendered JSON goes to pricing.json.new via printf against a fixed
#     template (no jq — we own the shape).
#   - The current pricing.json is renamed to pricing.json.bak.<epoch> before
#     the new one moves into place.
#   - Only the 5 most recent .bak.<epoch> files are kept ; older ones are
#     pruned by `ls -1t | tail -n +6`.
#   - `--rollback` restores the newest .bak over pricing.json in one mv.
#     No backup found → exit non-zero with actionable message.
#
# ============================================================================
# Model-alias reconciliation (`--reconcile`)
# ============================================================================
#
# When a model ID appears in the logs but has no entry in pricing.json
# and no prefix match in the hardcoded PRICING dict, recap.js warns and
# suggests running `refresh-pricing.sh --reconcile`. This mode :
#
#   1. Walks the local project's log files (session 3 scope ; cross-project
#      / cross-container discovery lands in session 4).
#   2. Diffs each distinct model ID against pricing.json.prices keys + any
#      existing model-aliases.json entries + hardcoded PRICING prefixes.
#   3. For each unmapped ID under a TTY, prompts the user for a tier
#      (opus / sonnet / haiku / skip). `--non-interactive` skips prompts
#      and just prints the unmapped IDs — useful in cron / CI.
#   4. Writes the chosen mapping to
#      ${CLAUDE_HOME}/tokens/model-aliases.json atomically. The alias
#      resolver in lib/pricing.js consults this file first, so the next
#      recap silently prices the aliased model.

set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
TOKENS_DIR="$CLAUDE_HOME/tokens"
PRICING_JSON="$TOKENS_DIR/pricing.json"
SOURCES_JSON="$TOKENS_DIR/pricing-sources.json"
ALIASES_JSON="$TOKENS_DIR/model-aliases.json"
BACKUP_KEEP=5
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BUNDLED_SOURCES="$SCRIPT_DIR/lib/pricing-sources.json"

DRY_RUN=0
ROLLBACK=0
RECONCILE=0
NON_INTERACTIVE=0
SOURCE_OVERRIDE=""

warn() { printf '%s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: refresh-pricing.sh [flags]

  --dry-run             extract + print, don't touch pricing.json
  --source=<url>        bypass source cascade, use only this URL (file:// ok)
  --rollback            restore newest pricing.json.bak.* over pricing.json
  --reconcile           interactive: map unknown model IDs seen in logs to a tier
  --non-interactive     with --reconcile, print unmapped IDs without prompting
  -h, --help            this help

Env: CLAUDE_HOME (default $HOME/.claude).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --rollback) ROLLBACK=1 ;;
    --reconcile) RECONCILE=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --source=*) SOURCE_OVERRIDE="${arg#--source=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $arg (try --help)" ;;
  esac
done

for cmd in curl awk sed grep date mv printf mkdir tr; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing dep: $cmd"
done

mkdir -p "$TOKENS_DIR"

if [ ! -f "$SOURCES_JSON" ] && [ -f "$BUNDLED_SOURCES" ]; then
  cp "$BUNDLED_SOURCES" "$SOURCES_JSON"
  warn "seeded $SOURCES_JSON from bundled defaults."
fi

# Hardcoded fallback — mirror of lib/pricing.js PRICING (USD per MTok).
# key|in|cache_read|cache_create|out
HARDCODED='claude-opus-4-7|5.00|0.50|10.00|25.00
claude-opus-4-6|5.00|0.50|10.00|25.00
claude-opus-4-5|5.00|0.50|10.00|25.00
claude-opus-4-1|15.00|1.50|30.00|75.00
claude-sonnet-4-6|3.00|0.30|6.00|15.00
claude-sonnet-4-5|3.00|0.30|6.00|15.00
claude-sonnet-4|3.00|0.30|6.00|15.00
claude-haiku-4-5|1.00|0.10|2.00|5.00
claude-haiku-3-5|0.80|0.08|1.60|4.00
claude-haiku-3|0.25|0.03|0.50|1.25'

# -------- Helpers --------

do_rollback() {
  latest=$(ls -1t "$TOKENS_DIR"/pricing.json.bak.* 2>/dev/null | head -1)
  if [ -z "${latest:-}" ]; then
    die "no backup found under $TOKENS_DIR/pricing.json.bak.* — nothing to roll back."
  fi
  mv "$latest" "$PRICING_JSON"
  warn "rolled back: $PRICING_JSON restored from $(basename "$latest")."
}

rotate_backup() {
  if [ -f "$PRICING_JSON" ]; then
    ts=$(date +%s)
    mv "$PRICING_JSON" "$TOKENS_DIR/pricing.json.bak.$ts"
  fi
  ls -1t "$TOKENS_DIR"/pricing.json.bak.* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
    [ -n "$old" ] && rm -f "$old"
  done
}

# Strip HTML tags, decode common entities, lowercase, single-space.
normalize_html() {
  sed -e 's/<[^>]*>/ /g' \
      -e 's/&nbsp;/ /g' \
      -e 's/&amp;/\&/g' \
      -e 's/&lt;/</g' \
      -e 's/&gt;/>/g' \
      -e 's/&quot;/"/g' \
      -e "s/&#x27;/'/g" \
      -e "s/&#039;/'/g" \
      "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | tr -s ' '
}

# Extract <script type="application/ld+json">…</script> blocks, lowercase.
extract_jsonld() {
  awk '
    BEGIN { on = 0; buf = "" }
    {
      if (!on && match($0, /<script[^>]*application\/ld\+json[^>]*>/)) {
        on = 1
        rest = substr($0, RSTART + RLENGTH)
        buf = buf rest " "
        next
      }
      if (on) {
        if (match($0, /<\/script>/)) {
          buf = buf substr($0, 1, RSTART - 1) " "
          on = 0
          next
        }
        buf = buf $0 " "
      }
    }
    END { print buf }
  ' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | tr -s ' '
}

# stdin (normalized single-line text) → "model|in|cr|cc|out" lines on stdout.
# Positional heuristic: first 4 prices after each unique model ID position map to
# (input, cache_read, cache_create, output). Sanity check filters bad alignments.
extract_prices() {
  awk '
    {
      line = $0
      n_models = 0; n_prices = 0
      # models (unique, first-occurrence order)
      pos = 1
      while (1) {
        tail = substr(line, pos)
        if (!match(tail, /claude-[a-z0-9-]+/)) break
        m_start = pos + RSTART - 1
        m_len = RLENGTH
        m_text = substr(line, m_start, m_len)
        if (!seen_model[m_text]) {
          seen_model[m_text] = 1
          n_models++
          model_txt[n_models] = m_text
          model_pos[n_models] = m_start
        }
        pos = m_start + m_len
      }
      # prices ($5.00 / MTok, 5 per million tokens, etc.)
      pos = 1
      while (1) {
        tail = substr(line, pos)
        if (!match(tail, /\$?[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*(\/|per)[[:space:]]*(m|million)[[:space:]]*(tokens?|tok|toks)/)) break
        p_start = pos + RSTART - 1
        p_len = RLENGTH
        p_text = substr(line, p_start, p_len)
        if (match(p_text, /[0-9]+(\.[0-9]+)?/)) {
          val = substr(p_text, RSTART, RLENGTH) + 0
          n_prices++
          price_pos[n_prices] = p_start
          price_val[n_prices] = val
        }
        pos = p_start + p_len
      }
      # emit
      for (i = 1; i <= n_models; i++) {
        mp = model_pos[i]
        count = 0
        pin = 0; pcr = 0; pcc = 0; pout = 0
        for (j = 1; j <= n_prices; j++) {
          if (price_pos[j] <= mp) continue
          count++
          if (count == 1) pin = price_val[j]
          else if (count == 2) pcr = price_val[j]
          else if (count == 3) pcc = price_val[j]
          else if (count == 4) { pout = price_val[j]; break }
        }
        if (count < 4) continue
        if (pin  <= 0.01 || pin  >= 1000) continue
        if (pcr  <= 0.01 || pcr  >= 1000) continue
        if (pcc  <= 0.01 || pcc  >= 1000) continue
        if (pout <= 0.01 || pout >= 1000) continue
        if (pcr >= pin) continue
        if (pin >= pcc) continue
        if (pcc >= pout * 3) continue
        printf "%s|%.6f|%.6f|%.6f|%.6f\n", model_txt[i], pin, pcr, pcc, pout
      }
    }
  '
}

# Fetch a URL, apply type-specific extraction, emit "model|in|cr|cc|out" lines.
# Returns 0 iff >=1 valid model extracted.
try_source() {
  url="$1"; stype="${2:-html}"
  tmp=$(mktemp)
  if ! curl -sfL --max-time 20 "$url" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  case "$stype" in
    jsonld)
      norm=$(extract_jsonld "$tmp")
      if [ -z "$norm" ]; then
        norm=$(normalize_html "$tmp")
      fi
      ;;
    api|html|*)
      norm=$(normalize_html "$tmp")
      ;;
  esac
  rm -f "$tmp"
  out=$(printf '%s\n' "$norm" | extract_prices)
  if [ -z "$out" ]; then
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

# Emit "url|type" pairs from SOURCES_JSON in file order, skipping disabled.
read_sources() {
  [ -f "$SOURCES_JSON" ] || return 0
  awk '
    /^[[:space:]]*\{/ { in_obj = 1; url = ""; type = ""; enabled = 1 }
    in_obj && /"enabled"[[:space:]]*:/ {
      if (match($0, /false/)) enabled = 0
    }
    in_obj && /"url"[[:space:]]*:/ {
      if (match($0, /"url"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"url"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        url = s
      }
    }
    in_obj && /"type"[[:space:]]*:/ {
      if (match($0, /"type"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"type"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        type = s
      }
    }
    /^[[:space:]]*\}/ && in_obj {
      if (enabled && url != "") printf "%s|%s\n", url, (type != "" ? type : "html")
      in_obj = 0
    }
  ' "$SOURCES_JSON"
}

# Emit JSON to stdout given "model|in|cr|cc|out" lines on stdin.
render_pricing_json() {
  src_url="$1"
  fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  awk -v src="$src_url" -v fetched="$fetched_at" '
    BEGIN {
      printf "{\n"
      printf "  \"fetched_at\": \"%s\",\n", fetched
      printf "  \"source_url\": \"%s\",\n", src
      printf "  \"prices\": {"
      first = 1
    }
    {
      n = split($0, f, "|")
      if (n != 5) next
      if (!first) printf ","
      first = 0
      printf "\n    \"%s\": {\"in\": %s, \"cache_read\": %s, \"cache_create\": %s, \"out\": %s}", f[1], f[2], f[3], f[4], f[5]
    }
    END {
      if (!first) printf "\n  "
      printf "}\n"
      printf "}\n"
    }
  '
}

# Warn if any model moved > 3x vs. previous pricing.json.
diff_previous() {
  new_content="$1"
  [ -f "$PRICING_JSON" ] || return 0
  # crude JSON scan: for each model in new, grep old for the same key and compare "in"
  printf '%s\n' "$new_content" | awk '
    /"prices"[[:space:]]*:/ { in_prices = 1 }
    in_prices && /"claude-[a-z0-9-]+":[[:space:]]*\{/ {
      if (match($0, /"claude-[a-z0-9-]+"/)) {
        key = substr($0, RSTART + 1, RLENGTH - 2)
        if (match($0, /"in"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
          s = substr($0, RSTART, RLENGTH)
          sub(/^"in"[[:space:]]*:[[:space:]]*/, "", s)
          print key "|" s
        }
      }
    }
  ' | while IFS='|' read -r k v; do
    old=$(grep -oE "\"$k\"[[:space:]]*:[[:space:]]*\{[^}]*\"in\"[[:space:]]*:[[:space:]]*[0-9.]+" "$PRICING_JSON" 2>/dev/null | grep -oE '"in"[[:space:]]*:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)
    if [ -n "$old" ] && [ -n "$v" ]; then
      awk -v k="$k" -v o="$old" -v n="$v" 'BEGIN {
        if (o == 0) exit
        r = n / o
        if (r > 3 || r < 0.33) printf "warn: model %s input price moved %.2fx (%s -> %s)\n", k, r, o, n > "/dev/stderr"
      }'
    fi
  done
}

# -------- Reconcile flow --------

# Emit distinct model IDs seen in project logs.
# Sources (unioned):
#   1) current-project walk (cwd walk-up → .claude/tokens/logs)
#   2) every project listed in local $CLAUDE_HOME/tokens/projects.jsonl
#   3) every project listed in `claude-code-config-*` docker volumes via lib/docker-scan.sh
# Sources 2+3 use each row's host_workspace_path (preferred) or project_root
# to find its logs. Docker absent / no matching volumes → silently skips.
collect_seen_models() {
  {
    # 1) Current-project walk.
    root="$(pwd)"
    while [ "$root" != "/" ]; do
      if [ -d "$root/.claude/tokens/logs" ] || [ -d "$root/.git" ]; then break; fi
      root=$(dirname "$root")
    done
    if [ -d "$root/.claude/tokens/logs" ]; then
      find "$root/.claude/tokens/logs" -type f -name '*.jsonl' 2>/dev/null | while read -r f; do
        grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed 's/^"model"[[:space:]]*:[[:space:]]*"//; s/"$//'
      done
    fi

    # 2+3) Registry union: local projects.jsonl + every docker volume's projects.jsonl.
    scan="$(dirname "$0")/lib/docker-scan.sh"
    ch="${CLAUDE_HOME:-$HOME/.claude}"
    if [ -f "$scan" ]; then
      {
        [ -f "$ch/tokens/projects.jsonl" ] && cat "$ch/tokens/projects.jsonl"
        bash "$scan" list-volumes 2>/dev/null | while read -r vol; do
          [ -z "$vol" ] && continue
          bash "$scan" read-projects "$vol"
        done
      } | while IFS= read -r line; do
        [ -z "$line" ] && continue
        p=$(printf '%s' "$line" | grep -oE '"host_workspace_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -1)
        [ -z "$p" ] && p=$(printf '%s' "$line" | grep -oE '"project_root"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -1)
        [ -z "$p" ] && continue
        [ -d "$p/.claude/tokens/logs" ] || continue
        find "$p/.claude/tokens/logs" -type f -name '*.jsonl' 2>/dev/null | while read -r f; do
          grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed 's/^"model"[[:space:]]*:[[:space:]]*"//; s/"$//'
        done
      done
    fi
  } | sort -u
}

# Return the newest key of a given tier from pricing.json + hardcoded (tier ∈ opus|sonnet|haiku).
newest_for_tier() {
  tier="$1"
  if [ -f "$PRICING_JSON" ]; then
    cand=$(grep -oE "\"claude-$tier-[a-z0-9-]+\"" "$PRICING_JSON" 2>/dev/null | sort -u | sed 's/^"//; s/"$//' | sort -r | head -1 || true)
    if [ -n "${cand:-}" ]; then
      printf '%s\n' "$cand"
      return
    fi
  fi
  printf '%s\n' "$HARDCODED" | grep -oE "^claude-$tier-[a-z0-9-]+" | sort -r | head -1
}

# Read existing aliases (key|value lines).
read_aliases() {
  [ -f "$ALIASES_JSON" ] || return 0
  awk '
    {
      s = $0
      while (match(s, /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        pair = substr(s, RSTART, RLENGTH)
        n = split(pair, parts, "\"")
        # parts: 1="" 2=key 3=":" 4=val
        printf "%s|%s\n", parts[2], parts[4]
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$ALIASES_JSON"
}

# Write aliases atomically. Input: key|value lines on stdin.
write_aliases() {
  tmp="$ALIASES_JSON.new"
  awk 'BEGIN { printf "{" }
    {
      n = split($0, f, "|")
      if (n != 2 || f[1] == "" || f[2] == "") next
      if (!first) first = 1; else printf ","
      printf "\n  \"%s\": \"%s\"", f[1], f[2]
    }
    END {
      if (first) printf "\n"
      printf "}\n"
    }
  ' >"$tmp"
  mv "$tmp" "$ALIASES_JSON"
}

do_reconcile() {
  seen=$(collect_seen_models)
  if [ -z "$seen" ]; then
    warn "no models seen in local project logs — nothing to reconcile."
    return 0
  fi
  # Known set = pricing.json prices keys ∪ existing aliases keys.
  known=""
  if [ -f "$PRICING_JSON" ]; then
    known=$(grep -oE '"claude-[a-z0-9-]+"[[:space:]]*:[[:space:]]*\{' "$PRICING_JSON" 2>/dev/null | grep -oE 'claude-[a-z0-9-]+' | sort -u)
  fi
  alias_keys=$(read_aliases | awk -F'|' 'NF==2 { print $1 }')
  # Diff.
  unmapped=$(printf '%s\n' "$seen" | grep -vxF -f <(printf '%s\n%s\n' "$known" "$alias_keys" | sort -u) 2>/dev/null || true)
  # Also skip prefix-matching hardcoded keys (e.g. claude-opus-4-7-2026-01 matches claude-opus-4-7).
  filtered=""
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    hit=0
    for k in $(printf '%s\n' "$HARDCODED" | awk -F'|' '{print $1}'); do
      case "$m" in
        "$k"*) hit=1; break ;;
      esac
    done
    [ "$hit" -eq 0 ] && filtered="$filtered$m
"
  done <<EOF
$unmapped
EOF
  filtered=$(printf '%s' "$filtered" | sed '/^$/d')
  if [ -z "$filtered" ]; then
    warn "reconcile: no unmapped models — all clear."
    return 0
  fi
  # Non-interactive OR non-TTY: just print.
  if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
    warn "unmapped models seen in logs:"
    printf '%s\n' "$filtered" >&2
    return 0
  fi
  # Existing aliases as starting set.
  existing=$(read_aliases)
  # Prompt loop.
  new_aliases=""
  printf '%s\n' "$filtered" | while IFS= read -r m; do
    [ -z "$m" ] && continue
    printf "\n« Model '%s' seen in your logs is not in the pricing table.\n  Which known tier? [1] opus  [2] sonnet  [3] haiku  [4] skip » " "$m" >&2
    read -r choice </dev/tty || choice=4
    case "$choice" in
      1) target=$(newest_for_tier opus) ;;
      2) target=$(newest_for_tier sonnet) ;;
      3) target=$(newest_for_tier haiku) ;;
      *) continue ;;
    esac
    printf '%s|%s\n' "$m" "$target" >>"$TOKENS_DIR/.reconcile.tmp"
  done
  # Merge existing + new, write atomically.
  merged=$(mktemp)
  {
    printf '%s\n' "$existing"
    [ -f "$TOKENS_DIR/.reconcile.tmp" ] && cat "$TOKENS_DIR/.reconcile.tmp"
  } | awk -F'|' 'NF==2 && $1 != "" && $2 != "" && !seen[$1]++ { print }' >"$merged"
  cat "$merged" | write_aliases
  rm -f "$merged" "$TOKENS_DIR/.reconcile.tmp"
  warn "reconcile: aliases written to $ALIASES_JSON."
}

# -------- Main --------

if [ "$ROLLBACK" -eq 1 ]; then
  do_rollback
  exit 0
fi

if [ "$RECONCILE" -eq 1 ]; then
  do_reconcile
  exit 0
fi

# Assemble source list.
if [ -n "$SOURCE_OVERRIDE" ]; then
  sources_list="$SOURCE_OVERRIDE|html"
else
  sources_list=$(read_sources)
  if [ -z "$sources_list" ]; then
    warn "no sources configured — check $SOURCES_JSON."
    exit 1
  fi
fi

# Try each source in order.
extracted=""
picked_url=""
IFS='
'
for entry in $sources_list; do
  url="${entry%|*}"
  stype="${entry##*|}"
  [ -z "$url" ] && continue
  warn "trying $stype source: $url"
  if extracted=$(try_source "$url" "$stype"); then
    picked_url="$url"
    warn "extracted $(printf '%s\n' "$extracted" | wc -l | tr -d ' ') model(s) from $url."
    break
  fi
done
unset IFS

# Source 5 — hardcoded seed (first-run only).
if [ -z "$extracted" ]; then
  if [ ! -f "$PRICING_JSON" ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "all network sources failed — seeding pricing.json with hardcoded fallback."
    extracted="$HARDCODED"
    picked_url="hardcoded-fallback"
  else
    if [ -f "$PRICING_JSON" ]; then
      warn "all network sources failed — pricing.json unchanged."
    else
      warn "all network sources failed and --dry-run set — nothing to print."
    fi
    exit 1
  fi
fi

# Render JSON.
json_out=$(printf '%s\n' "$extracted" | render_pricing_json "$picked_url")

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$json_out"
  exit 0
fi

# Diff-warn vs previous, then atomic write with backup rotation.
diff_previous "$json_out"
tmp="$PRICING_JSON.new"
printf '%s\n' "$json_out" >"$tmp"
rotate_backup
mv "$tmp" "$PRICING_JSON"
warn "wrote $PRICING_JSON (source: $picked_url)."
