# devcontainer-sandbox — documentation

A firewalled devcontainer base image with Claude Code baked in. This folder is
the human-facing documentation; pick the path that matches why you are here.

> **This index is deliberately short.** It is a map, not a landing page — every
> line below either points somewhere or says plainly that the page is not
> written yet. A map that lists pages that do not exist is worse than no map.

## I want to use it

- **[Boot warnings](boot-warnings.md)** — the panel your container prints at
  startup said something. What the words mean, why it matters, and how to fix
  it. Starts with a glossary, so it is also the place to look up `L7`,
  `allowlist`, `bake`, `sentinel` or `Phase B`.
- [Quickstart](../README.md#quickstart) — scaffold a project onto this image.
- [Using the image](../README.md#using-the-image) — tags, `devcontainer.json`,
  compose, non-Node stacks.

## I want to extend it

- [EXTENDING.md](../EXTENDING.md) — the three layers (this image, an image that
  `FROM`s it, your project), hooks, skills, firewall, extension patches.

## I maintain it

- [TESTING.md](../TESTING.md) — the assertion catalogue.
- [RELEASING.md](../RELEASING.md) — the gate and the publish steps.

## Not written yet

The pages a newcomer needs most are the ones that do not exist. Named here so
the gap is visible rather than implied:

- **Getting started from zero** — what a devcontainer is, what this image adds
  on top, and a first project that works.
- **Concepts** — firewall modes, the allowlist, layers, lifecycle phases,
  patchers. Every other page assumes these words; none of them defines them.
- **How to add things** — a skill, a lifecycle hook, a domain your install
  needs, a language stack, a patcher. This one is half-written already and
  unpublished: it is baked into the image at
  `/opt/devcontainer/base/knowledge/extension-points.md`, readable only from
  inside a running container.
- **Troubleshooting** — my install is blocked, the extension is not patched,
  notifications never arrive, the container will not start.
