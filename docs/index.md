# devcontainer-sandbox — documentation

A firewalled devcontainer base image with Claude Code baked in: your editor's
environment, described by your repository, on a network that reaches only the
hosts you listed.

Pick the path that matches why you are here.

## I want to use it

Read in this order the first time — each page leaves you able to follow the
next.

1. **[Getting started](getting-started.md)** — from nothing to a container that
   runs. What a devcontainer is, what this image adds, the scaffolding wizard,
   the first boot, and the first thing that will go wrong.
2. **[Concepts](concepts.md)** — the vocabulary every other page assumes:
   allowlist, DNS vs L7, the three firewall modes, bake, the three layers, the
   lifecycle phases, skills, patchers, sentinels, Phase B, heartbeat.
3. **[Boot warnings](boot-warnings.md)** — your container's startup panel said
   something. One section per warning: what it means, why it matters, how to
   fix it.
4. **[Troubleshooting](troubleshooting.md)** — sorted by symptom, not by
   component. Start here when something is wrong and the panel is clean.

## I want to extend it

One page per gesture. Each states the goal, the steps, and how to check it
actually worked.

- **[Add a skill](how-to/add-a-skill.md)** — teach the agent a procedure,
  available as a slash command.
- **[Add a lifecycle hook](how-to/add-a-lifecycle-hook.md)** — run something of
  your own at startup, in the right phase.
- **[Allow a domain](how-to/allow-a-domain.md)** — your install is blocked.
  How to find the hostnames rather than guess them, and at which scope to add
  them.
- **[Add a language stack](how-to/add-a-stack.md)** — PHP, Python, Go, a JDK:
  a project `Dockerfile` on top of the one base.
- **[Patch the extension](how-to/patch-the-extension.md)** — modifying Claude
  Code itself, and the reasons not to.

Reference, once the how-tos are not enough —
[EXTENDING.md](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md):
the layer resolution rules in full, and how to publish a *derived image* for a
team rather than configure a single project.

## I maintain it

- [README](https://github.com/meitogi/devcontainer-sandbox/blob/master/README.md)
  — what the image contains, the tag scheme, and how to verify a pulled image.
- [TESTING.md](https://github.com/meitogi/devcontainer-sandbox/blob/master/TESTING.md)
  — the assertion catalogue.
- [RELEASING.md](https://github.com/meitogi/devcontainer-sandbox/blob/master/RELEASING.md)
  — the gate and the publish steps.

---

> **This index is a map, not a landing page.** Every line above points at a
> page that exists. A map that lists pages that do not exist is worse than no
> map — so what is still missing is named here, and never linked:
>
> - **Using the image, as reference** — tags, `devcontainer.json`, the compose
>   capabilities the firewall needs, verifying a pulled image. It is written,
>   and it is still inside the README rather than here.

These pages are also inside every container built on this image, at
`/opt/devcontainer/base/docs/` — the same files, so the agent working in your
repository reads exactly what you read.
