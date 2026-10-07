# Firewall — hot reload of the local layer

Companion to [`firewall.md`](firewall.md). Explains how to add a host
to `domains.local.txt` (and, in `strict`, an endpoint to
`policy.local.d/`) and pick it up **without rebuilding the
devcontainer**. Works in **both `basic` and `strict`** ; only `off`
is refused (there is no firewall to reload).

## When to use `reload-firewall`

- Firewall mode = `basic` or `strict` (check
  `cat /etc/devcontainer-firewall/default-mode`).
- Ponctual need : add one or two hosts for a lookup / dep install /
  external API call, without killing the session.
- Only the **local layer** is reloaded. The committed sources
  (`domains.txt`, `domains.d/`, `policy.d/`) are read from the baked
  copy in `/etc/devcontainer-firewall/` — editing them in the workspace
  still needs a rebuild.

## Usage

Edit the local layer as usual :

```
# .devcontainer/firewall/domains.local.txt
hetzner.com
[GET] example.internal.io/api/*
```

In `strict`, a new host also needs its L7 endpoints in
`.devcontainer/firewall/policy.local.d/<host>.yaml`, otherwise mitmproxy
blocks the paths even though DNS + ipset let the host through.

Preview — unprivileged, safe from anywhere, including a Claude session :

```
reload-firewall --dry-run
```

It prints the fingerprints of the local files, the host allowlist delta,
the L7 overrides (strict) and the ruleset diff. It never touches the
live firewall.

Apply — a human, from a host terminal :

```
wtf firewall reload
```

Auto-detects the compose `app` container and runs the direct form :

```
docker exec -it -u 0 <container> /usr/local/bin/reload-firewall
```

`-it` is required : the script shows the same diff as `--dry-run` and
waits for a typed `yes` before applying.

## Guards

The apply path refuses, in this order :

1. **Mode** — anything other than `basic` / `strict`. Legacy alias
   `okeish` is refused with an actionable message.
2. **Not root** — needs root for `ipset`, `pkill` and `/var/run/`.
3. **`$CLAUDECODE` set** — an agent produces the diff with `--dry-run`
   and asks the user to apply it.
4. **stdin not a TTY** — the confirmation prompt cannot be answered.
5. **Empty candidate** — a ruleset that allows zero hosts is never
   applied.

Guards 3 and 4 are honesty guards, not a security boundary — see below.

## Why root-only via docker exec (no sudo)

Passwordless sudo is intentionally NOT configured for `reload-firewall`
(unlike `init-firewall.sh` and `test-firewall.sh`, which are baked into
`/etc/sudoers.d/node-firewall`). Reason : `reload-firewall` widens the
allowlist from files in `.devcontainer/firewall/`, which any node-uid
process can write (an npm postinstall included). Allowing node-uid to
trigger it passwordless would let that process inject arbitrary hosts
into the firewall — a supply-chain / lateral-movement risk.

Root elevation via `docker exec -u 0` requires host-side docker socket
access. No docker socket is mounted in the container, so the attack
surface is scoped to whoever already controls the host docker daemon.

Expected output — sub-500 ms :

```
  ✓ dnsmasq restarted
  elapsed: 210ms  |  hosts: base=93 local=3  |  ipset IPs: base=71 local=0
  ✓ mitmproxy addons pick up policy.compiled.yaml via mtime check (zero downtime)   ← strict only
```

`ipset IPs: local=0` right after reload is normal — the entries appear
as clients query the host and dnsmasq resolves upstream.

## What the script does

1. **Build a candidate** in a scratch dir — baked committed sources
   from `/etc/devcontainer-firewall/` + the workspace
   `domains.local.txt` and `policy.local.d/*.yaml` — and run
   `compile-policy.py --split-local` on it. Outputs
   `dnsmasq-domains-base.conf`, `dnsmasq-domains-local.conf` and
   `policy.compiled.yaml`. A compile error aborts with nothing applied.
   `--dry-run` and the apply share this code path, so the approved diff
   is the installed diff.
2. **Show the diff** against the live files in
   `/var/run/devcontainer-firewall/` and ask for `yes`. An identical
   candidate exits without touching anything.
3. **Pre-flight** — the `allowed-domains-local` ipset must exist (the
   firewall is booted), otherwise the new hosts would resolve but stay
   blocked.
4. **Install** the three files by write-then-rename, so the mitmproxy
   addons never observe a half-written `policy.compiled.yaml`.
5. **Flush local ipset** — `ipset flush allowed-domains-local`. The
   base ipset stays intact ; connections currently opened to baseline
   hosts are not dropped.
6. **Restart dnsmasq** — full restart (pkill + relaunch) with the same
   four conf-files as boot (`dnsmasq.conf`, base, local, injections).
   SIGHUP is NOT enough — per `dnsmasq(8)` it never re-parses
   `--conf-file`, so new `server=` / `ipset=` lines would be silently
   ignored. A dnsmasq that fails to come back is reported as DNS down,
   never as success.
7. **Strict : mitmproxy** — nothing to restart. The addons
   (`policy_enforce`, `format_detect`) stat `policy.compiled.yaml` on
   each request and re-read it when its mtime changes.
8. **Summary** — elapsed ms + host counts per group + IP counts per
   ipset.

## Ephemeral by design

Nothing is written to `/etc/devcontainer-firewall/`. A reload lasts as
long as the container does ; the next start returns to the baked,
human-audited ruleset. To make local overrides survive a rebuild, opt
in at build time with `FIREWALL_ALLOW_LOCAL_AT_REBUILD=1`.

## Split-ipset architecture

In both modes, init-firewall.sh emits two dnsmasq conf files and
creates two ipsets :

- `allowed-domains-base` — populated from `domains.txt`, `domains.d/*.txt`,
  `policy.d/*.yaml`, plus the Docker host-gateway IP.
- `allowed-domains-local` — populated from `domains.local.txt` and
  `policy.local.d/*.yaml`. This is the only ipset the reload script
  flushes.

The iptables ACCEPT rules match on those two ipsets — directly in
`basic`, restricted to the mitmproxy UID owner in `strict`. Zero perf
impact — netfilter set matching is O(1) per rule.

**Partition rule** — a host that exists in the baseline and is
`redefine`d by `domains.local.txt` stays in the base group with its
new methods. Only truly new hosts introduced by the local layer go
to the local group.

## Verification loop

1. `curl -sSf https://github.com` — baseline host, should pass.
2. Edit `.devcontainer/firewall/domains.local.txt`, add `hetzner.com`
   (+ `policy.local.d/hetzner.com.yaml` in strict).
3. `reload-firewall --dry-run` — `+ hetzner.com` in the host delta.
4. `wtf firewall reload` from the host, type `yes` — OK in <500 ms.
5. `curl -sSf https://hetzner.com` — new host, should pass without
   rebuild.
6. `curl -sSf https://github.com` — baseline still up (no downtime).

## Related files

- `/usr/local/bin/reload-firewall` — the script. Shipped by the image ; the
  project copy it replaced (`.devcontainer/reload-firewall`) is retired.
- `/usr/local/bin/init-firewall.sh` — boot-time split-ipset setup.
- `/usr/local/bin/compile-policy.py` — `--split-local` mode.
- `/etc/devcontainer-firewall/tests/split-local.sh` — unit tests for the
  split emit logic.
- `/etc/devcontainer-firewall/tests/reload-firewall-guards.sh` — the
  guard cascade.
- [`firewall.md`](firewall.md) — full firewall pipeline (strict mode,
  mitmproxy, HTTPS_PROXY propagation).
