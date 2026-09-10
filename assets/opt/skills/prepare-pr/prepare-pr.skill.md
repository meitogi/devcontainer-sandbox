---
description: Generate a PR draft (body .md + metadata .yaml) for host-side manual or automated execution
argument-hint: "[optional one-line PR description]"
---

# /prepare-pr — generate a PR draft pair (.md + .yaml)

The main devcontainer runs the Level 1 strict firewall: `gh pr create` and
`git push` to non-`anthropics/*` paths are blocked at the network layer.
PR creation happens on the **host**. This skill produces a draft pair so
the operator can run `gh pr create` manually (or, later, via a host CLI
that consumes the `.yaml`).

## When to use

- The user says "prépare le PR", "create the PR", "open a PR".
- A feature/fix is complete on a branch and ready for review.

## Process

Run the following inspection steps. Do not run any remote-write command
(`git push`, `gh pr create`, …) — they are firewalled.

1. **Inspect git state** (use the Bash tool):
   ```bash
   git rev-parse --abbrev-ref HEAD
   git log origin/main..HEAD --pretty=format:"- %s"
   git diff origin/main..HEAD --stat
   git diff origin/main..HEAD | head -200
   ```
   If `origin/main` is unreachable (firewall or never fetched), fall back
   to `main..HEAD`. Surface the substitution to the user.

2. **Derive a task slug** from the current branch:
   - `feat/foo-bar` → `foo-bar`
   - `fix/db-timeout` → `db-timeout`
   - Detached HEAD → ask the user for a slug, do not invent one.

3. **Write two sibling files** under `/workspace/.devcontainer/pr-drafts/`:
   - `<slug>-<unix-ts>.md` — **human document, manual workflow**. Pure
     markdown : H1 with title, bulleted metadata (base/head/draft/labels),
     `---` separator, then PR body. Wrapped in a 4-backtick `markdown`
     fence so it renders as one copy-pasteable block in any viewer.
   - `<slug>-<unix-ts>.yaml` — **automation document**. Same fields
     plus the body inlined as a `body: |` block scalar, so a future
     host CLI / wtf command can `yq` everything from a single file.

   Both files share the same base name and carry the exact same
   information — they MUST be kept in sync.

### `.md` file (pure markdown, human-friendly copy-paste)

The `.md` is the **human-readable** version of the draft. It's formatted
as clean markdown so the operator can read it at a glance and grab any
block (title, base/head/labels, body) and paste it directly into the
GitHub web UI or a `gh pr create` invocation.

The metadata header (H1 title, bulleted base/head/draft/labels) is
plain markdown — it renders normally. Only the **body** sits inside a
**4-backtick** ` ```` markdown` fence. The fence makes the body
render as a single copy-pasteable code block in any markdown viewer
(IDE preview, GitHub render, `bat`). 4 backticks (not 3) so any
triple-backtick code blocks inside the PR body keep rendering
correctly.

The `.yaml` sibling carries the same fields **plus the body inlined**
as a `body: |` block scalar, so future automation only needs to parse
the `.yaml` (one file = full draft).

Template:

```markdown
# [ai-assisted] <concise description>

- **Base branch** : `main`
- **Head branch** : `<current branch>`
- **Draft** : `true`
- **Labels** : `ai-assisted`

---

````markdown
## Summary

- <bullet 1>
- <bullet 2>

## Test plan

- [x] <what was tested>
- [ ] <manual verification needed>

## Files changed

- `<file>` (+X -Y) — <one-line intent>
````
```

Copy-paste flow on the host:

- **Title** → copy the `# [ai-assisted] …` line (drop the leading `# `).
- **Body** → copy the content of the 4-backtick block (one click in any
  viewer that exposes copy-on-fence).
- **`--base` / `--head` / `--draft` / `--label` flags** → read off the
  bullets directly.

### `.yaml` file (metadata + body inline, fully self-contained)

The body is inlined as a YAML literal block scalar (`body: |`) so a
single `yq` call gives a future host CLI everything it needs to run
`gh pr create`. No need to also open the `.md`.

```yaml
title: "[ai-assisted] <concise description>"
base: main
head: <current branch>
draft: true
labels:
  - ai-assisted
body: |
  ## Summary
  - <bullet 1>
  - <bullet 2>

  ## Test plan
  - [x] <what was tested>
  - [ ] <manual verification needed>

  ## Files changed
  - `<file>` (+X -Y) — <one-line intent>
```

Future automation example:

```bash
yq -r .title  <draft>.yaml                                   # → "[ai-assisted] foo"
yq -r .body   <draft>.yaml | gh pr create --body-file - ...  # body piped raw
```

4. **Display next step** to the user:
   ```
   ✅ PR draft ready:
       .devcontainer/pr-drafts/<slug>-<ts>.md     ← human (copy-paste)
       .devcontainer/pr-drafts/<slug>-<ts>.yaml   ← automation (yq)

   Open the .md on your host : the title is the H1, the base/head/
   labels are the bullets, and everything after `---` is the PR body.
   Copy whichever chunk you need into `gh pr create` or the GitHub
   web UI.
   ```

## Constraints

- **Never** run `gh pr create`, `gh pr edit`, `git push`, or any write to
  GitHub from the container — the firewall returns 503 and you should not
  retry with workarounds.
- **Title prefix MUST be `[ai-assisted]`** so reviewers can filter.
- **`draft: true` is mandatory** — humans promote to "ready for review"
  after inspection.
- **Body MUST include `## Summary` and `## Test plan`**. `## Files changed`
  is recommended when the diff touches more than three files.
- **Both files MUST be produced** with the same base name. Skipping the
  `.yaml` breaks the future host-CLI consumer; skipping the `.md` removes
  the copy-pasteable artefact.
- **In the `.md`, only the body (Summary/Test plan/Files changed) is
  wrapped in a 4-backtick `markdown` fence.** The H1 title, the bulleted
  metadata, and the `---` separator stay outside the fence so the file
  reads as plain markdown. 4 backticks (not 3) so any nested
  triple-backtick code blocks inside the body render intact.
- Draft path is always under `/workspace/.devcontainer/pr-drafts/`
  (bind-mounted, gitignored except `.keep`). Never put drafts elsewhere.

## Failure modes

- **Detached HEAD** → ask the user for a branch name before proceeding.
- **No commits ahead of base** → do not write a draft; tell the user the
  branch is empty.
- **Branch name has no `/` prefix** (e.g. `quickfix`) → use the full
  branch name as the slug, lowercased and sanitized to `[a-z0-9-]`.
- **`origin/main` unfetchable** → fall back to `main..HEAD` and warn.
