# Allow a domain

**Goal.** Something your project needs — a registry, a CDN, an API — is being
refused by the firewall, and you want it allowed. Deliberately, and only it.

The hard part is not the edit. It is knowing *which* hostnames to add. Guessing
a vendor's CDN from its `.com` does not work, and the container already knows
the answer.

*Every command in a code block on this page runs in a terminal **inside the
container**, unless the step says otherwise.*

---

## First: which kind of refusal is it?

There are two, they look different, and they are found in different places.

### A host that is not on the allowlist

The container's resolver answers only for hostnames on the list. Anything else
gets no address at all, so the connection never starts. Your tool reports a
**name resolution** failure and names the host:

```
npm error code ENOTFOUND
npm error network request to https://cdn.example.net/pkg.tgz failed
```

`ENOTFOUND`, `EAI_AGAIN`, `Could not resolve host`, `Name or service not
known` — all the same cause. **That error message is your list.** Nothing else
records it: the resolver refuses silently by design, and `firewall-blocks` will
not show it.

Confirm a specific host in one command:

```
getent hosts cdn.example.net
```

No output means it is not allowed. Output means it is, and your problem is
something else.

### A host that is allowed, but the request was refused

This only happens in `strict` mode, where an L7 filter reads the request and
can allow `GET` on one path while refusing `POST` on another. You get an HTTP
error, usually `403`, from a host that clearly resolves. **This** is what
`firewall-blocks` records:

```
firewall-blocks
```

It prints the recent refusals with their reason, the host and the path. Those
are policy decisions, not missing hostnames — adding the host again will change
nothing. You need a path or a method, which lives in
`firewall/policy.d/<host>.yaml`. That file lists what the host is allowed to
serve:

```yaml
endpoints:
  - path: "^/v1/models$"
    methods: [GET]
  - path: "^/v1/jobs/[^/]+$"
    methods: [GET, POST]
```

`path` is a regular expression matched against the request path, `methods` are
the verbs allowed on it, and anything unlisted is refused. The files the image
ships under `/etc/devcontainer-firewall/policy.d/` are worked examples,
including the header and body-size options this minimum leaves out.

> In `basic` mode there is no L7 filter, so this case cannot occur and
> `firewall-blocks` stays empty. See
> [path scopes apply in strict only](../concepts.md#path-scopes-apply-in-strict-only).

---

## Then: add it at the right scope

Three files, differing only in who they are for. Pick by audience, not by
convenience.

| File | Committed | Use it when |
|---|---|---|
| `firewall/domains.local.txt` | no, gitignored | it is yours alone, or you are still experimenting. The cheapest and the most revertible — start here when unsure |
| `firewall/domains.d/<name>.txt` | yes | your colleagues need it too, and it belongs to one identifiable concern (`python.txt`, `maps-api.txt`). One file per concern keeps it reviewable |
| `firewall/domains.txt` | yes | it is part of what this project fundamentally is |

The syntax is one hostname per line. `#` starts a comment, blank lines are
ignored.

```
cdn.example.net
registry.example.org
```

Write a comment above each entry saying what needed it. An allowlist entry
nobody can explain is one nobody dares remove.

For a service that is not HTTP — a database, a local model server — reached as
`host:port`, use `firewall/ports.txt` instead. Same comment rules, one
`host:port` per line, and the bare word `host` means your own machine:

```
db.internal:5432
host:11434
```

Put only non-HTTP services there. Anything speaking HTTP or HTTPS, on any port,
belongs in the `domains` files above.

## Then: rebuild

The allowlist is **baked** into the image at build time, not read at startup.
Editing the file and restarting changes nothing, and the boot panel will tell
you so:

```
  ⚠ Firewall   staged on disk, NOT applied — rebuild to bake them in
```

In VS Code's Command Palette: **Dev Containers: Rebuild Container**.

This is deliberate. A ruleset compiled once at build is one that nothing inside
the running container can quietly widen — including the agent. See
[bake](../concepts.md#bake--baked--staged).

---

## How to check it worked

Re-run whatever failed. Then confirm the three facts:

```
getent hosts cdn.example.net
```

returns an address.

```
boot-summary
```

shows a verdict of `✓ all clear` and a `Firewall` line whose entry count has
gone up by what you added. If you used `domains.local.txt`, that line also
carries a `+N local` suffix, and the word after it must be `baked in` — `STAGED`
there means the file is on disk and the rebuild did not happen.

```
firewall-blocks
```

reports nothing new for that host.

If your install now completes and those three agree, the change is real and it
is the whole change.

---

## If it still fails

- **Resolves, but connection times out** — the host is on the DNS allowlist but
  the traffic is not HTTP. It needs an entry in `ports.txt`, not `domains.txt`.
- **403 from a host you just added, in `strict`** — the host is allowed and the
  *path* is not. Read `firewall-blocks` for the reason and add a
  `policy.d/<host>.yaml`.
- **Nothing changed at all** — you restarted instead of rebuilding. The panel's
  `STAGED` warning is the confirmation.

Everything else: [Troubleshooting](../troubleshooting.md).
