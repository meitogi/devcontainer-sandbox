# Add a skill

**Goal.** Teach the agent a procedure it should follow the same way every time,
available as a slash command. A skill is how "always run the linter before you
propose a commit" stops being something you retype.

*Every command in a code block on this page runs in a terminal **inside the
container**, unless the step says otherwise.*

---

## Steps

### 1. Create the directory and the file

A skill is a directory whose name is the command, containing
`<name>.skill.md`:

```
mkdir -p .devcontainer/skills/lint-gate
```

`.devcontainer/skills/lint-gate/lint-gate.skill.md`:

```markdown
# Lint gate

Before proposing any commit:

1. Run `npm run lint` and `npm test`.
2. If either fails, fix it. Do not propose the commit.
3. Quote the passing output in your proposal.
```

The body of that file *is* the prompt. It becomes `/lint-gate`.

### 2. Optionally, add hooks

If the skill needs Claude Code settings of its own — a hook that fires on an
event, for instance — put them in `hooks.json` beside the `.skill.md`. Its
shape is Claude Code's own settings format, and it is **merged** into the
agent's settings rather than replacing them:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/my-notifier" }
        ]
      }
    ]
  }
}
```

Spell every command with an **absolute path**. The file is read from
`~/.claude/`, not from the directory you wrote it in, so a relative path
resolves somewhere you did not intend.

### 3. Install it

Skills are installed by a startup step that runs on **every** container start,
so a restart is enough — no rebuild:

```
devc-hook post-start
```

Or, to install skills only:

```
sync-skills
```

Both are safe to run repeatedly.

---

## How to check it worked

```
ls ~/.claude/commands/lint-gate.md
```

The file exists. Then:

```
boot-summary
```

The `Skills` line counts one more than it did.

Finally, start a new Claude Code session and type `/lint-gate`. The command
appears with your text behind it. A session that was already open does not see
a skill added under it — open a new one.

---

## Variants

**Keep it to yourself.** A file named `<name>.local.skill.md`, or a directory
named `<name>.local/`, is gitignored. Use it for a personal command you do not
want to impose on the repository.

**Replace one the image ships.** Create a directory with the same name under
`.devcontainer/skills/`. The project layer wins over the image — see
[the three layers](../concepts.md#the-three-layers).

**Remove one the image ships.** List it in `.devcontainer/skills/disabled.txt`,
one per line:

```
notify-queue
```

The key is the **directory name**, not the command name — two of the shipped
skills are hooks-only and have no command at all, so a command name could never
reach them. Listing a skill withdraws both its command and its hooks, including
ones a previous boot already installed.

---

## Reference

The layering rules, and how to ship a skill from an image that extends this one
rather than from a project:
[EXTENDING.md § Skills](https://github.com/meitogi/devcontainer-sandbox/blob/master/EXTENDING.md#skills).
