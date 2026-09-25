# Add a language stack

**Goal.** Your project is not Node, or not only Node. You need PHP, Python, Go,
a JDK — something the base image does not carry.

There is no PHP image and no Android image. A stack is a **project
`Dockerfile`** that derives from this one base and adds its toolchain. One base
to audit, one base to update, and your additions visible in your own repository
rather than hidden in someone else's image.

*Every command in a code block on this page runs in a terminal **inside the
container**, unless the step says otherwise.*

---

## The fast way: ask the agent

Inside the container:

```
/prepare-stack
```

It asks what the stack is rather than guessing from a manifest, writes the
`Dockerfile`, **discovers** the allowlist by measurement instead of guesswork,
and wires up lint and test. It is the same procedure as below, done for you,
and its acceptance criterion is zero firewall refusals.

If you would rather do it by hand, read on.

---

## Steps

### 1. Start from a worked example

Three are published. Each is a complete, paste-ready `Dockerfile` for that
stack, with the allowlist entries it needs and the reasoning for each block —
open the one closest to yours and copy from it rather than paraphrasing:

- [PHP 8.2 + Composer](https://github.com/meitogi/devcontainer-sandbox/blob/master/stacks/php.md)
- [OpenJDK 17 + Kotlin + Android SDK](https://github.com/meitogi/devcontainer-sandbox/blob/master/stacks/android.md)
- [the above + Coursier + Capacitor + AndroidX](https://github.com/meitogi/devcontainer-sandbox/blob/master/stacks/android-capacitor.md)

For a stack with no example, they are still the model: the shape is always the
same, only the `RUN` that installs the toolchain changes.

### 2. Keep the firewall bake stage. It is not optional.

Every project `Dockerfile` opens with a throwaway stage that compiles your
allowlist into the image:

```dockerfile
FROM ghcr.io/meitogi/devcontainer-sandbox:${BASE_VERSION}-cc${CLAUDE_CODE_VERSION} AS fw-bake
USER root
COPY firewall/ /tmp/fw-src/
RUN /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /out
```

and the real stage copies its output in:

```dockerfile
COPY --from=fw-bake /out/ /etc/devcontainer-firewall/
```

The base image ships the firewall *machinery* and **no allowlist at all** — the
allowlist is yours, which is what stops the image from ever silently widening
your rules. Skipping the bake does not produce a container without a firewall;
it produces one where startup fails at the first phase while the image itself
looks perfectly healthy.

`devc init` already wrote both stages. If you are editing that file, leave them
where they are and add your toolchain after.

### 3. Add your toolchain

As `USER root`, in the final stage, before it switches back to `USER node`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.11 python3.11-venv python3-pip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node
```

Pin versions rather than taking whatever is current, so a rebuild six months
from now produces the same container. Keep it to one `RUN` where you can: each
one is a layer, and the cleanup has to happen in the same `RUN` as the install
to actually save anything.

This step runs during the **build**, which is not subject to the container's
firewall — that only governs the running container. Which is why the next step
exists.

### 4. Discover the allowlist, do not invent it

Your new toolchain reaches hosts Node never did — a package registry, a
mirror, a signing service. Rebuild, run your install, and let it fail. Then
read what was refused and add exactly that.

Full method, including the two different kinds of refusal and where each one is
recorded: [Allow a domain](allow-a-domain.md).

### 5. Rebuild

In VS Code's Command Palette: **Dev Containers: Rebuild Container**. Both the
toolchain and the allowlist are baked, so both need it — *Reopen* is not
enough.

---

## How to check it worked

```
boot-summary
```

Verdict `✓ all clear`, and the `Firewall` line showing your entry count as
`baked in`.

Then, in order:

```
php --version
```

(or whatever your toolchain's is) — it answers.

```
firewall-blocks
```

— reports nothing after a full, clean dependency install.

Those three together are the acceptance criterion: the tool is present, the
network is exactly as wide as you wrote, and nothing was refused on the way.

---

## Reference

The layering rules, and how to publish a stack as a **shared image** for a team
rather than as one project's `Dockerfile`:
[EXTENDING.md](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md).
