#!/usr/bin/env bash
# escalation.sh — privilege-escalation pentest: can the container user become
# root at all?
#
# privilege.sh attacks the firewall's CONTROL PLANE (sudo grants, config
# ownership, the reload command, the frozen bake). It answers "can node widen
# the allowlist?". This suite answers the broader question underneath it:
# "can node stop being node?" — the classic local-escalation surface, which
# no test covered before.
#
# Seven vectors, each an invariant of the published image :
#   1. SUID / SGID binaries      — frozen inventory, any newcomer fails
#   2. file capabilities         — none granted
#   3. root files node can write — none
#   4. root's PATH directories   — none writable (else sudo becomes hijackable)
#   5. the Docker socket         — absent, loudly
#   6. NET_ADMIN / NET_RAW       — granted to the container, unusable by node
#   7. what sudo init-firewall.sh consumes — nothing under /workspace
#
# Run as the container user (node), NOT as root :
#   bash /etc/devcontainer-firewall/tests/escalation.sh
#   docker run --rm -u node <image> bash /etc/devcontainer-firewall/tests/escalation.sh
#
# It reads only the installed image, never the repo, so it is replayable by
# anyone on a published tag. That is deliberate: an audit nobody else can run
# is a claim, not evidence.

set -u

FW="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  – $1 (skipped: $2)"; }

# assert_denied "label" cmd...  — the command MUST fail.
assert_denied() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ko "$label — SUCCEEDED, that is a privilege hole"
  else
    ok "$label — denied"
  fi
}

if [ "$(id -u)" -eq 0 ]; then
  echo "⚠️  running as root — this suite only means something as the container user."
  echo "   Re-run without -u 0."
  exit 2
fi

echo "═══ escalation.sh — running as $(id -un) (uid $(id -u)) ═══"
echo "    groups: $(id -Gn | tr ' ' ',')"
echo

# ══════════════════════════════════════════════════════════════════════════
echo "== 1. SUID / SGID inventory is frozen =="
# The image ships exactly the Debian bookworm shadow/util-linux/sudo set and
# adds none of its own — no `chmod u+s` anywhere in the Dockerfile. Freezing
# the list is what turns "we did not add any" into a claim that keeps holding:
# a base-image bump, a new apt package or a careless RUN shows up here as a
# diff instead of silently widening the surface.
#
# Every entry below is a stock Debian binary, present because shadow, sudo and
# util-linux ship them:
#   chage/expiry            shadow — read/alter password ageing (SGID shadow)
#   chfn/chsh/passwd/gpasswd/newgrp/su  shadow — account edits (SUID root)
#   mount/umount            util-linux — SUID root, mount(8) needs it
#   sudo                    the sudo binary itself; the narrow policy is what
#                           constrains it, and privilege.sh asserts that policy
#   unix_chkpwd             PAM helper — SGID shadow, verifies passwords
EXPECTED_SETUID="/usr/bin/chage /usr/bin/chfn /usr/bin/chsh /usr/bin/expiry /usr/bin/gpasswd /usr/bin/mount /usr/bin/newgrp /usr/bin/passwd /usr/bin/su /usr/bin/sudo /usr/bin/umount /usr/sbin/unix_chkpwd"

ACTUAL_SETUID=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null \
                | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$ACTUAL_SETUID" = "$EXPECTED_SETUID" ]; then
  ok "SUID/SGID inventory matches the frozen list ($(echo "$ACTUAL_SETUID" | wc -w) binaries)"
else
  ko "SUID/SGID inventory CHANGED — every newcomer is a candidate escalation path"
  for b in $ACTUAL_SETUID; do
    case " $EXPECTED_SETUID " in *" $b "*) ;; *) echo "      + $b  (new — justify it or remove it)" ;; esac
  done
  for b in $EXPECTED_SETUID; do
    case " $ACTUAL_SETUID " in *" $b "*) ;; *) echo "      - $b  (gone — update the frozen list)" ;; esac
  done
fi

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 2. no file capabilities =="
# A capability on a file is a SUID bit that `find -perm` does not see, so the
# check above is only half an inventory without this one.
GETCAP=""
for c in /usr/sbin/getcap /sbin/getcap "$(command -v getcap 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { GETCAP="$c"; break; }
done
if [ -n "$GETCAP" ]; then
  CAPS=$("$GETCAP" -r / 2>/dev/null | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
  [ -z "$CAPS" ] \
    && ok "getcap -r / is empty (no file carries a capability)" \
    || ko "file capabilities present: $CAPS"
else
  # Deliberately NOT a skip. getcap arrives with libcap2-bin; if it ever goes
  # missing the assertion would evaporate in silence and this suite would go
  # green having measured nothing — the exact false-green this file exists to
  # prevent. The Dockerfile installs libcap2-bin explicitly for this reason.
  ko "getcap absent — the capability inventory could not be taken (install libcap2-bin)"
fi

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 3. no root-owned file is writable by $(id -un) =="
# Regular files only, and symlinks are skipped on purpose: a symlink's own
# permission bits are ignored by the kernel, so `-writable` on one reports on
# its TARGET and produces false hits. The real example in this image is
# /usr/local/bin/claude → /home/node/.vscode-server/…/claude : node owns its
# own CLI, which is expected and harmless because nothing ever runs it with
# privilege (privilege.sh asserts the sudo grants are exactly two other
# binaries). A target that matters on its own is caught on its own line.
WRITABLE=$(find / -xdev -user root -type f -writable \
             -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' \
             -not -path '/tmp/*'  -not -path '/run/*' -not -path '/var/tmp/*' \
             -not -path '/workspace/*' -not -path '/home/node/*' \
             2>/dev/null | sort | head -20)
if [ -z "$WRITABLE" ]; then
  ok "no root-owned regular file is writable by $(id -un)"
else
  ko "root-owned files writable by $(id -un) — each one is a root-code-injection point"
  echo "$WRITABLE" | sed 's/^/      /'
fi

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 4. root's PATH directories are not writable =="
# This is what makes the NOPASSWD grant safe. `sudo init-firewall.sh` runs a
# root shell script that calls iptables, ipset, dnsmasq, dig… by name. A
# writable directory earlier in root's PATH would let node drop a fake
# `iptables` there and have root execute it — escalation without ever touching
# the firewall config the other suite guards.
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [ -d "$d" ] || { skip "PATH dir $d" "absent"; continue; }
  [ -w "$d" ] \
    && ko "$d is WRITABLE — sudo init-firewall.sh becomes a \$PATH hijack" \
    || ok "$d not writable"
done

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 5. no Docker socket inside the container =="
# The whole confinement rests on this. A reachable socket is not an escalation
# to root in the container — it is root ON THE HOST, and it makes every other
# assertion in this file and in privilege.sh irrelevant. The compose template
# mounts none; this asserts the property rather than trusting the template.
for s in /var/run/docker.sock /run/docker.sock /var/run/docker/docker.sock; do
  [ -e "$s" ] \
    && ko "$s EXISTS — container escape to host root, everything else is moot" \
    || ok "$s absent"
done

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 6. NET_ADMIN / NET_RAW are granted to the container, not to $(id -un) =="
# The template adds both caps so init-firewall.sh (as root) can program
# netfilter. The claim under test is that the grant stops at root: an
# unprivileged process inherits nothing. privilege.sh checks the same boundary
# from the netfilter side (ipset/iptables/pkill refused); this checks it from
# the kernel side, which is where the caps actually live.
CAPEFF=$(grep -E '^CapEff:' /proc/self/status 2>/dev/null | awk '{print $2}')
CAPPRM=$(grep -E '^CapPrm:' /proc/self/status 2>/dev/null | awk '{print $2}')
if [ -z "$CAPEFF" ]; then
  ko "could not read CapEff from /proc/self/status"
else
  [ "$CAPEFF" = "0000000000000000" ] \
    && ok "CapEff is empty ($CAPEFF) — no effective capability" \
    || ko "CapEff is $CAPEFF — $(id -un) holds effective capabilities"
  [ "$CAPPRM" = "0000000000000000" ] \
    && ok "CapPrm is empty ($CAPPRM) — none permitted either" \
    || ko "CapPrm is $CAPPRM — $(id -un) could raise capabilities"
fi
# A raw socket is the concrete thing CAP_NET_RAW buys. Refused = the cap is
# genuinely absent, not merely unlisted.
assert_denied "open a SOCK_RAW socket (needs CAP_NET_RAW)" \
  python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, 1)'

echo
# ══════════════════════════════════════════════════════════════════════════
echo "== 7. sudo init-firewall.sh consumes nothing from /workspace =="
# THE invariant the narrow sudo policy rests on. init-firewall.sh is the only
# arbitrary-code path node can trigger as root without a password. The moment
# it reads one workspace-controlled byte — a config, a domains file, a sourced
# library — that NOPASSWD grant becomes "node executes chosen input as root".
# The bake-only migration closed this deliberately (vector #13); this keeps it
# closed. Full-line comments are stripped; anything else counts as a real read.
for f in /usr/local/bin/init-firewall.sh /usr/local/bin/devc-conf.sh; do
  [ -r "$f" ] || { skip "workspace-free check on $(basename "$f")" "absent or unreadable"; continue; }
  HITS=$(grep -nE '/workspace' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [ -z "$HITS" ]; then
    ok "$(basename "$f") references /workspace only in comments"
  else
    ko "$(basename "$f") reads /workspace — the NOPASSWD grant is no longer safe"
    echo "$HITS" | sed 's/^/      /'
  fi
done
# The config root it does read must be image content, root-owned.
if [ -d "$FW" ]; then
  OWNER=$(stat -c '%U' "$FW" 2>/dev/null || echo unknown)
  [ "$OWNER" = "root" ] \
    && ok "$FW is root-owned (the config it actually reads)" \
    || ko "$FW owned by $OWNER — its input is not image content"
else
  skip "config root ownership" "$FW absent"
fi

echo
echo "═══════════════════════════════════════════════════════"
echo "  escalation : $((PASS+FAIL)) run | ✔ $PASS | ❌ $FAIL | – $SKIP skipped"
echo "═══════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
