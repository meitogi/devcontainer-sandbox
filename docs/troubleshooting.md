# Troubleshooting — sorted by what you are seeing

This page is indexed by symptom, because that is what you have when you open
it. If your container printed a `⚠` line at startup, go straight to
[Boot warnings](boot-warnings.md) instead — it has one section per warning.

Whatever the symptom, the first two commands are the same:

```
boot-summary
```

reprints what the container actually started with, and its `Log` line names the
file holding the whole startup sequence.

---

## "My install fails with ENOTFOUND / EAI_AGAIN / could not resolve host"

The firewall is working. The host your tool wants is not on the allowlist, so
it has no address and the connection never starts.

The error message names the host, and that message is the only record — the
resolver refuses silently by design, so `firewall-blocks` will **not** show
this kind of refusal.

→ [Allow a domain](how-to/allow-a-domain.md)

## "I get a 403 from a host that clearly works"

Different problem. The host is allowed; the *request* was refused by the L7
filter, which reads paths and methods. This only happens in `strict` mode.

```
firewall-blocks
```

names the reason and the path. The fix is a path or a method in
`firewall/policy.d/<host>.yaml`, not another hostname.

→ [path scopes apply in strict only](concepts.md#path-scopes-apply-in-strict-only)

## "I edited the firewall config and nothing changed"

Expected. The ruleset is compiled into the image when it is **built**, not read
when the container starts — that is what stops anything inside the container
from quietly widening it. The boot panel says so:

```
  ⚠ Firewall   staged on disk, NOT applied — rebuild to bake them in
```

In VS Code's Command Palette: **Dev Containers: Rebuild Container**, not
Reopen.

The same applies to `firewall/default-mode`: changing `strict` to `basic` is a
rebuild, not a restart.

→ [bake / baked / staged](concepts.md#bake--baked--staged)

## "Rebuild or Reopen?"

| You changed | Do this |
|---|---|
| anything under `firewall/` | **Rebuild** — it is baked |
| the `Dockerfile` or `docker-compose.yml` | **Rebuild** |
| a `post-start` fragment | Reopen, or just `devc-hook post-start` |
| an `on-create` or `post-create` fragment | **Rebuild** — those phases only run at creation |
| a skill under `.devcontainer/skills/` | `sync-skills`, then a new Claude session |
| `devcontainer.json` | **Rebuild** |

When in doubt, rebuild. It is slower, never wrong, and the panel will confirm
what you got.

## "The first start takes ten minutes and shows nothing"

Normal, once. VS Code pulls a 2–3 GB image, bakes your allowlist into it, then
runs three startup phases — and shows none of it until you open the progress
panel. Click **show log** in the notification, or open the terminal panel.

Later starts take seconds. If a *later* start is also slow, read the file named
on the panel's `Log` line: a fragment is hanging, and its `@name` will be the
last one in there.

## "The model selector is the stock one" (or another patch is missing)

Patchers modify the Claude Code extension, and they are optional — most
projects run none, and `Patchers   none` on the panel is correct for them.

If you expect patchers, the panel says which of two things happened:

- `an apply would change it — it is running unpatched` — an extension update
  replaced the file and nothing reapplied. Rebuild.
- `nothing cached for this line — no patcher applied` — there is no patcher set
  cut for the Claude Code version this container runs. That is a refusal, not a
  failure: another version's set is never substituted.

→ [Patch the extension](how-to/patch-the-extension.md)

## "No notifications arrive"

The notifier daemon touches a file every ten seconds. When it stops, the panel
says:

```
  ⚠ Notify     heartbeat stopped — notifications will not arrive
```

A notifier that is not running fails silently by nature, which is why it is on
the panel at all. Restarting the container restarts it.

→ [heartbeat](concepts.md#heartbeat)

## "`claude` works but the panel says npm fallback"

The image normally points `claude` at the binary already inside the VS Code
extension instead of downloading a second copy. When that does not work it
falls back to an npm install, which works — it just means the container is
about 224 MB heavier than it needed to be, and the extension and the CLI can
drift apart.

→ [Phase B](concepts.md#phase-b)

## "I need one host right now and I do not want to rebuild"

There is a sanctioned escape hatch, and it is deliberately awkward. Put the
host in `firewall/domains.local.txt`, then from your **host machine**:

```
docker exec -u 0 -it <container> reload-firewall --dry-run
```

Drop `--dry-run` to apply, after reading the diff. It needs root, it needs a
human at the keyboard, and **it lasts only as long as the container** — the
next start returns to the baked, audited ruleset. Make it permanent by adding
the host properly and rebuilding.

## "A skill I added does not appear"

Three things to check, in order:

1. `ls ~/.claude/commands/<name>.md` — if it is missing, the file is not named
   `<name>.skill.md` inside a directory named `<name>`.
2. Run `sync-skills` and read its output; it names what it installed.
3. Open a **new** Claude Code session. A session already running does not pick
   up a command added underneath it.

→ [Add a skill](how-to/add-a-skill.md)

## "A lifecycle fragment of mine never runs"

Ask what would run, before guessing:

```
devc-hook post-start --dry-run
```

It lists every fragment in order with the layer it came from. If yours is
absent, the filename is wrong — it must sit directly in `<phase>.d/` and end in
`.sh`. If it is present but you see no effect, it ran and failed: a non-required
fragment that exits non-zero gets a warning and the phase continues. Its outcome
is in the startup log named on the panel.

→ [Add a lifecycle hook](how-to/add-a-lifecycle-hook.md)

---

## None of the above

Open an issue: <https://github.com/meitogi/devcontainer-sandbox/issues>.

Attach the file named on the panel's `Log` line — it holds the whole start
sequence — and the output of `boot-summary`. Those two answer most of the
questions a reply would otherwise have to ask.

Back to [the documentation map](index.md), or to
[Getting started](getting-started.md) if you arrived here mid-setup.
