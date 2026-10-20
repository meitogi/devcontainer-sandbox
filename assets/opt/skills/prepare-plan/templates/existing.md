# Template — `EXISTING.md` (multi-session)

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

````markdown
# Existing — technical inventory

> File map of the area this plan touches : `path — role`, one line per
> file or module, no code excerpts, ~60 lines max. The code and
> `git log` are the detail ; this file only says where to look. Updated
> when a session adds / removes / restructures files.
> For chronological history, see [LOG.md](LOG.md).
> For decisions and philosophy, see [ROLLOUT.md](ROLLOUT.md).

{{existing_body}}
````

When exploration was skipped, `{{existing_body}}` is :

```markdown
## To be filled

This inventory was not pre-populated when the plan was scaffolded —
session 1's first action is to fill it. Use `Read` and/or `Explore`
sub-agents to map, as `path — role` lines (no code excerpts, ~60 lines
max) :

- Directory structure of the relevant area
- Existing functions / modules that may be reused
- Tests covering the area
- Known gaps / pain points the rollout will address
```

When exploration ran, `{{existing_body}}` is the aggregated findings,
shaped as the same `path — role` map — never pasted agent output.
