# Firewall — hot reload of the local layer (`basic` mode)

Companion to [`firewall.md`](firewall.md). Explains how to add a host
to `domains.local.txt` and pick it up **without rebuilding the
devcontainer**, when the firewall is running in `basic` mode.

## When to use `reload-local.sh`

- Firewall mode = `basic` (check `cat /etc/devcontainer-firewall/default-mode`).
- Ponctual need : add one or two hosts for a lookup / dep install /
  external API call, without killing the session.
- `strict` mode → NOT supported. The mitmproxy L7 layer would need
  `policy.compiled.yaml` reloaded too, which requires a rebuild for
  now. The script refuses to run in strict.

## Usage

Edit the local layer as usual :

```
# .devcontainer/firewall/domains.local.txt
hetzner.com
[GET] example.internal.io/api/*
```

Root-only by design (see security note below). Invoke via one of :

```
wtf firewall reload
```

Runs from the host, auto-detects the compose `app` container, elevates
via `docker exec -u 0`. Convenience wrapper for the direct form :

```
docker exec -u 0 <container> /workspace/.devcontainer/reload-local.sh
```

## Why root-only via docker exec (no sudo)

Sudo passwordless is intentionally NOT configured for `reload-local.sh`
(unlike `init-firewall.sh` and `test-firewall.sh`, which are baked into
`/etc/sudoers.d/node-firewall`). Reason: `reload-local.sh` MUTATES the
allowlist based on files in `.devcontainer/firewall/` (which node writes
during normal editing). Allowing node-uid to trigger it passwordless
would let any process running as node inject arbitrary hosts into the
firewall allowlist — a supply-chain / lateral-movement risk.

Root elevation via `docker exec -u 0` requires host-side docker socket
access (which is a trust boundary controlled by the host user), so the
attack surface is scoped to whoever already controls the host docker
daemon.

Expected output — sub-500 ms :

```
  ✔ dnsmasq restarted (SIGHUP does NOT re-parse --conf-file)
  elapsed: 210ms  |  hosts: base=93 local=3  |  ipset IPs: base=71 local=0
```

`ipset IPs: local=0` right after reload is normal — the entries appear
as clients query the host and dnsmasq resolves upstream.

## What the script does

1. **Wall-guard** — reads `/etc/devcontainer-firewall/default-mode`,
   refuses anything other than the literal `"basic"`. Legacy alias
   `okeish` is refused with an actionable message pointing to the fix.
2. **Root check** — needs root for `/etc/`, `/var/run/`, `ipset`,
   `pkill`.
3. **Resync** — copies `domains.local.txt` and `policy.local.d/*.yaml`
   from the workspace to `/etc/devcontainer-firewall/`. Deletions in
   the workspace propagate.
4. **Recompile** — runs `compile-policy.py --split-local` targeting
   both `dnsmasq-domains-base.conf` and `dnsmasq-domains-local.conf`.
   Base is rewritten too (a local `redefine` of a baseline host can
   change its methods — no-op semantically in basic but keeps artifacts
   coherent).
5. **Flush local ipset** — `ipset flush allowed-domains-local`. The
   base ipset stays intact ; connections currently opened to baseline
   hosts are not dropped.
6. **Restart dnsmasq** — full restart (pkill + relaunch) with the
   same three conf-files as `init-firewall.sh` uses at boot. SIGHUP
   is NOT enough — per `dnsmasq(8)`, it only re-reads `/etc/hosts`,
   `--addn-hosts`, `--hostsdir`, `--dhcp-*` files. It does NOT
   re-parse `--conf-file` arguments, so new `server=` / `ipset=`
   lines in the recompiled local conf would be silently ignored.
7. **Summary** — elapsed ms + host counts per group + IP counts per
   ipset.

## Split-ipset architecture (basic mode)

In basic mode, init-firewall.sh emits two dnsmasq conf files and
creates two ipsets :

- `allowed-domains-base` — populated from `domains.txt`, `domains.d/*.txt`,
  `policy.d/*.yaml`, plus the Docker host-gateway IP.
- `allowed-domains-local` — populated from `domains.local.txt` and
  `policy.local.d/*.yaml`. This is the only ipset the reload script
  flushes.

Two iptables ACCEPT rules match on those two ipsets. Zero perf impact —
netfilter set matching is O(1) per rule.

**Partition rule** — a host that exists in the baseline and is
`redefine`d by `domains.local.txt` stays in the base group with its
new methods. Only truly new hosts introduced by the local layer go
to the local group.

## Strict mode is unchanged

In `strict`, init-firewall.sh continues to :

- Emit a single `dnsmasq-domains.conf` file with the legacy
  `allowed-domains` ipset.
- Create one ipset `allowed-domains`.
- Emit one iptables ACCEPT rule filtering by mitmproxy UID owner.

Zero regression path — `reload-local.sh` refuses to run there ; only
`sudo devcontainer rebuild` will pick up changes.

## Verification loop (post-rebuild)

Run these after `sudo devcontainer rebuild` (host-side) to confirm the
new split-ipset stack works end-to-end :

1. `curl -sSf https://github.com` — baseline host, should pass.
2. `curl -sSf https://netcup.com` — already-local host, should pass.
3. Edit `.devcontainer/firewall/domains.local.txt`, add `hetzner.com`.
4. `sudo .devcontainer/reload-local.sh` — expects OK in <500 ms.
5. `curl -sSf https://hetzner.com` — new host, should pass without
   rebuild.
6. `curl -sSf https://github.com` — baseline still up (no downtime).
7. `ipset list allowed-domains-base | grep -c '^[0-9]'` > `ipset list
   allowed-domains-local | grep -c '^[0-9]'` — isolation verified.
8. Force strict mode + rerun script — should exit 1 with a clear
   error message :
   ```
   sudo sh -c 'echo strict > /etc/devcontainer-firewall/default-mode'
   sudo .devcontainer/reload-local.sh
   ```

## Related files

- [`../reload-local.sh`](../reload-local.sh) — the script.
- [`../init-firewall.sh`](../init-firewall.sh) — boot-time split-ipset
  setup (basic mode only).
- [`../firewall/compile-policy.py`](../firewall/compile-policy.py) —
  `--split-local` mode.
- [`../firewall/tests/split-local.sh`](../firewall/tests/split-local.sh)
  — unit tests for the split emit logic.
- [`firewall.md`](firewall.md) — full firewall pipeline (strict mode,
  mitmproxy, HTTPS_PROXY propagation).
