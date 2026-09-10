# What this image does to the Claude Code extension

This image ships Anthropic's Claude Code VS Code extension, and it modifies it.
Sixteen small Python patchers rewrite three files of the extension bundle at
**image build time** — `package.json`, `extension.js` and `webview/index.js`.

That is an unusual thing for a base image to do, so this page exists to make it
inspectable: what each patch changes, why it is there, and what it costs you.
Nothing here is hidden behind a flag you have to discover.

## Choosing what gets applied

At build, with a `--build-arg`:

    docker build --build-arg CLAUDE_CODE_EXT_PATCHS=ux,fix .

At runtime, in a container started from an already-built image:

    restore-ext-patches ux,fix        # restore pristine files, replay a selection
    restore-ext-patches none          # a completely unpatched extension
    restore-ext-patches --list        # what is baked, and what is live right now

Both accept the same vocabulary: `all`, `none`, category names (`ux`, `fix`,
`notify`), patch names, or any comma-separated mix of the three. A token that
names nothing fails loudly instead of being ignored — a typo that silently
dropped a patch would be worse than a broken build.

The default is `all`.

Two things worth knowing. First, patches rewrite files **in place**, so once
the image is built there is no original left in the extension directory; the
`CLAUDE_CODE_EXT_PATCHS` environment variable you can read inside the container
only records what the build chose, and changing it does nothing on its own.
Second, that is exactly why the build keeps a pristine copy of the three files
under `/usr/local/share/claude-ext-orig/` before touching them — that copy is
what `restore-ext-patches` replays from, and it is what makes the runtime
selection real rather than decorative. A reload of the VS Code window is
required for any runtime change to be visible.

## The sixteen

| Patch | Category | Rewrites |
|---|---|---|
| `disable-webview-auth-redirect` | ux | `package.json`, `extension.js`, `webview/index.js` |
| `fix-style-pills` | ux | `package.json`, `extension.js`, `webview/index.js` |
| `icon-fix-open-in-current-panel` | ux | `package.json`, `extension.js` |
| `model-badge-footer` | ux | `package.json`, `extension.js`, `webview/index.js` |
| `model-mode-affinity` | ux | `webview/index.js` |
| `opus-4-7-legacy-picker-fix` | ux | `extension.js`, `webview/index.js` |
| `plan-preview-find-widget` | ux | `extension.js` |
| `webview-login-retry-button` | ux | `extension.js`, `webview/index.js` |
| `model-selection-fix` | fix | `extension.js`, `webview/index.js` |
| `navigator-pending-migration-fix` | fix | `extension.js` |
| `rename-session-restore-empty-file-fallthrough` | fix | `package.json`, `extension.js` |
| `authority-writer` | notify | `extension.js` |
| `handle-uri-workspace` | notify | `extension.js` |
| `outbound-action-injector` | notify | `extension.js` |
| `user-action-observer` | notify | `extension.js` |
| `webview-simulated-click` | notify | `webview/index.js` |

`ux` is comfort — nothing outside the editor depends on it. `fix` works around
a defect in a specific upstream version. `notify` is one half of the
notification channel described at the end of this page; those five are the ones
to look at first if you care about what leaves your workspace.

---

## disable-webview-auth-redirect

**What it does.** Adds a `claudeCode.disableWebviewAuthRedirect` setting. When
you turn it on, an authentication error no longer throws the chat panel back to
the login screen — the error appears inline and the conversation stays put.

**Why.** The existing `claudeCode.disableLoginPrompt` setting only gates the
extension-side login modal; it is never plumbed through to the webview. On a
401 the webview receives an assistant message tagged
`error:"authentication_failed"` and unconditionally calls `showLogin()`, which
re-renders the whole panel as the login view. People who authenticate from
outside the editor want that hijack gone without losing the deliberate login
paths.

**What changes visibly.** Nothing, until you enable the setting: it defaults to
`false`, which is the stock behaviour.

**Cost and side effects.** None.

**Mechanics.** Three coordinated edits — the setting declaration in
`package.json`, the gate in `extension.js`, and the error branch in
`webview/index.js`. Sentinels
`claude-code-disable-webview-auth-redirect-{inject,gate}-v1` and `-isauth-v2`.

## fix-style-pills

**What it does.** Adds a `claudeCode.fixStylePills` setting, on by default,
that squares off the two rounded pills in the prompt-input footer — the model
pill and the Remote Control pill — so they match the footer buttons beside
them. On bundles older than 2.1.258, where that footer does not exist yet, it
hides the legacy model pill instead.

**Why.** From 2.1.258 the stock footer names the model itself, in a pill whose
fully-rounded 1em style sits next to square 5px buttons. The mismatch is the
only thing separating the two, and the pill is the element people look at most.
Before 2.1.258 there was no such footer, so the same setting takes its earlier
meaning: hide the pill `model-badge-footer` supersedes.

**What changes visibly.** The model and Remote Control pills get a 5px radius,
2px 8px padding and 0.85em text — the shape `menuButton` and `usageButtonV2`
already use.

**Cost and side effects.** None. It supersedes `claudeCode.hideModelLegacyPill`
and strips that patch's injections wherever it finds them.

**Mechanics.** The setting is declared in `package.json` and evaluated
extension-host side inside the `IS_SIDEBAR` bootstrap template of
`extension.js`, which is where the global reaches the webview; on the restyle
path the rules ride in as a `<style>` element and `webview/index.js` is only
cleaned of superseded injections. Sentinel `/*fsp-boot-v3*/`, written on both
paths and therefore the one `--list` reads. The legacy path writes two more,
`/*fsp-pill-v1*/` and `/*fsp-row-v1*/`, in `webview/index.js`; they are
deliberately not declared, because `--list` requires every declared sentinel at
once and these two never coexist with the restyle path.

## icon-fix-open-in-current-panel

**What it does.** Adds a `primary` value to `claudeCode.preferredLocation` that
opens Claude in the editor column you are already working in, as a tab at the
end of the group, instead of splitting the editor or moving to the panel.

**Why.** Every entry point — the activity-bar icon, the status bar item, the
command palette, the `+` button — resolved its target column differently, and
the symbolic `ViewColumn.Active` meant clicking twice could split the editor
rather than reuse the tab.

**What changes visibly.** Only if you select `primary` in settings; the other
values behave exactly as shipped.

**Cost and side effects.** None.

**Mechanics.** Six steps across `package.json` and `extension.js`, the central
one resolving the column from `tabGroups.activeTabGroup.viewColumn` as an
integer. Detectable by the enum description string
`Primary Editor (Active Column)` in `package.json`. Step 1 refuses to claim the
`primary` value if a future upstream version declares it with a different
description.

## model-badge-footer

**What it does.** Puts a small read-only badge in the composer footer naming
the model currently answering you.

**Why.** Nothing in the stock UI states which model is in use; the information
exists but only inside the `/model` picker, which costs two clicks and a config
fetch. That matters more than convenience suggests, because the model can
change without you doing anything — a refusal fallback silently reassigns it.

**What changes visibly.** A badge between the context indicator and the
permission-mode selector.

**Cost and side effects.** None.

**Mechanics.** Injected into `webview/index.js` after the footer spacer, so it
groups with the session-state controls rather than the left-hand action cluster
that grows with attachments. Sentinels `/*mbf-v2*/`, `/*mbf-open*/` and
`/*mbf-boot-v2*/`; the patcher strips its previous injection before
re-applying.

## model-mode-affinity

**What it does.** On an **empty** session, picking a model also moves the
permission mode: a non-Opus/Fable model chosen while in `plan` switches to
`acceptEdits`, and an Opus/Fable model chosen while in `acceptEdits` switches
to `plan`.

**Why.** The two controls sit side by side and are almost always changed
together: you drop to a smaller model for a mechanical task and stay stuck in
Plan, then come back to a bigger one to think and stay in "edit
automatically".

**What changes visibly.** The permission-mode selector moves on its own when
you change model in a session with no history.

**Cost and side effects.** None. The mapping is deliberately two-way and
restricted to those two modes, so it is reversible; `default`, `auto` and
`bypassPermissions` are never entered nor left.

**Mechanics.** Hooks `setModel()` in `webview/index.js`. Sentinel `/*mma-v1*/`.

## opus-4-7-legacy-picker-fix

**What it does.** Keeps a chosen set of flagship models in the `/model` picker
even after the server-side tier filter stops listing them as current, and shows
a "Loading models…" badge while the config fetch is in flight.

**Why.** When a model is rotated out of the "current" tier the picker drops it
silently, although the binary still accepts the model ID. On the five-to-ten
second first fetch after a window reload the picker was also simply blank, with
no indication that more was coming.

**What changes visibly.** More entries in the model picker than the server
would offer, and a loading badge instead of an empty list.

**Cost and side effects.** It pins a list of model IDs, so it is the patch most
likely to age. Review it when you bump `CLAUDE_CODE_VERSION`.

**Mechanics.** `webview/index.js` and `extension.js`, sentinel
`/*opus-fix-v7*/`, older tags stripped on re-apply. The picker component name
is minified and drifts between versions (`dt1` → `UXe` → `VXe`), so the anchor
is the surrounding structure rather than the name.

## plan-preview-find-widget

**What it does.** Enables Cmd+F / Ctrl+F in the read-only plan preview panel.

**Why.** VS Code webviews support a documented `enableFindWidget` option; the
plan viewer simply never opted in, so long plans could not be searched.

**What changes visibly.** The native find widget opens in the plan preview.

**Cost and side effects.** None.

**Mechanics.** A one-token addition to the options of
`createWebviewPanel("claudePlanPreview", …)` in `extension.js`, anchored on the
view type string. Detectable by `enableFindWidget:!0`.

## webview-login-retry-button

**What it does.** Adds a "Continue where I left off" button to the login
screen, which repaints the webview and resumes the persisted session instead of
requiring a fresh start.

**Why.** Even with `disable-webview-auth-redirect`, the login screen can still
appear when opening a new chat tab. Without this button the recovery path was
to type a throwaway message into the chat to reset the session.

**What changes visibly.** One extra button on the login screen.

**Cost and side effects.** None.

**Mechanics.** `extension.js` and `webview/index.js`, five gates, hooking the
`acquireVsCodeApi()` call site to expose the API on `window` at boot. Sentinels
`claude-code-webview-vscode-api-window-v1`,
`claude-code-webview-login-retry-button-v1`,
`claude-code-webview-retry-reload-handler-v1`.

---

## model-selection-fix

**What it does.** Makes the model you configured in
`.claude/settings.local.json` actually win, makes the picker show it ticked in
both render phases, and gives the footer's model pill a label from the moment a
tab opens.

**Why.** Two defects, both observed rather than inferred. `getModelSetting()`
falls back from the merged settings to the raw parse of the user-level
`settings.json` alone — a file that structurally cannot know about
`.claude/settings.local.json` — so under a race the fallback is not a degraded
version of the same answer but a different answer from a narrower file. In
measurement, three pushes out of eight carried the wrong model.

Holding the session's model back until the settings are trustworthy leaves the
pill that 2.1.258 added to the footer with nothing to read: it falls back to the
word "Model" and stays there for the life of the tab, since the session model is
seeded once and never revisited. The pill is a readout, so it displays the
best-known setting rather than waiting — the same value the picker's tick
already uses.

**What changes visibly.** The model you asked for is the model you get, the
picker's tick agrees with it, and the footer pill names it — "Opus 5 (1M)"
rather than "Model" — before you send anything.

**Cost and side effects.** None.

**Mechanics.** `extension.js` and `webview/index.js`, sentinel `/*msf-v1*/`.

## navigator-pending-migration-fix

**What it does.** Neutralises `globalThis.navigator` before the extension
bundle loads.

**Why.** Recent VS Code installs `navigator` as a "pending migration" accessor
that throws on **any** access, `typeof` included, to push extensions to migrate
now that Node has `navigator` as a real global. Claude Code 2.1.x bundles a Zod
version that reads `navigator` at module load, which trips the throw during
top-level `require` — before the activation function is even called.

**What changes visibly.** Without it: the Claude panel fails to open, the
activity-bar icon flashes and dies, and the output channel shows
`PendingMigrationError: navigator is now a global in nodejs`.

**Cost and side effects.** None. Setting `navigator` to `undefined` is the Node
environment the bundle was written for; every access in it is already guarded
by a `typeof` check.

**Mechanics.** A short IIFE prepended to `extension.js`, sentinel
`/*__VSCODE_NAVIGATOR_PENDING_MIGRATION_FIX_v1__*/`.

> **This is the one patch the extension does not work without.** It is marked
> `critical` in the registry. You may still exclude it — `none` means none —
> but the build will say so in red, and the extension will not activate. If you
> land in that state, `restore-ext-patches fix` is the way out, without a
> rebuild. The longer write-up is in `navigator-pending-migration-fix.md`.

## rename-session-restore-empty-file-fallthrough

**What it does.** Restores the automatic tab rename that follows your first
prompt.

**Why.** Broken from 2.1.205 by a defensive `if(!s) return !0;` in
`renameSession()`: it treats "the session transcript file is not on disk yet"
as "this session already has a custom title, skip". Since 2.1.205 the CLI
batches the first flush about four seconds after the session starts, so on a
first prompt the file is deterministically absent and the rename is always
skipped.

**What changes visibly.** The tab title becomes a generated summary instead of
staying on the truncated first prompt.

**Cost and side effects.** None.

**Mechanics.** A retry-poll with a fallback write in `extension.js`, sentinel
`notify-queue-rename-session-nofile-v1`. The sentinel carries a `notify-queue`
prefix for historical reasons only — this patch has nothing to do with
notifications, and a grep for "notify" will mislead you here.

---

## authority-writer

**What it does.** Writes the container's VS Code remote authority (a string
like `dev-container+<hex>`) into `.devcontainer/notify/queue/.authority` in your
workspace when the extension loads.

**Why.** A notification that can focus the right window needs a URL naming that
window, and the authority is the only part of it that cannot be derived from
inside the container. The extension can read it from
`workspace.workspaceFolders[0].uri.authority`; nothing else in the container
can.

**What changes visibly.** Nothing.

**Cost and side effects.** **Creates `.devcontainer/notify/queue/` in your
workspace** if it does not exist, and writes one small file there. On a miss it
polls every 200 ms for up to 30 seconds, then stops.

**Mechanics.** An IIFE prepended to `extension.js`, sentinel
`/*__NOTIFY_QUEUE_AUTHORITY_WRITER_v1__*/`.

## handle-uri-workspace

**What it does.** Teaches the extension's URI handler to accept a `workspace`
(and optional `sleep`) parameter, so a link can focus a specific window before
revealing a session in it.

**Why.** Clicking a notification should land in the window the notification came
from. Without the parameter the URI is delivered to whichever window happens to
handle it.

**What changes visibly.** Nothing, unless something hands the editor such a
URI.

**Cost and side effects.** None. A URI without the new parameter takes exactly
the historical path.

**Mechanics.** `extension.js`, sentinel `notify-queue-uri-workspace-v2`.

## user-action-observer

**What it does.** Logs every message the chat webview sends to the extension —
prompts, permission answers, interrupts, session lifecycle — to the "Claude
VSCode" output channel and to a JSONL file in your workspace.

**Why.** It is the chokepoint where a user's intent becomes an action, so it is
where a notification channel learns that a question has been answered.

**What changes visibly.** Extra `[user-action]` lines in the output channel.

**Cost and side effects.** **Writes
`.devcontainer/logs/claude-code-vscode-ext-inbound.jsonl`.** Each record holds
a timestamp, session and channel ids, the event type and its payload — which
for a prompt includes the text you typed. Read the honesty section below before
deciding you are comfortable with that.

**Mechanics.** Wraps `webview.onDidReceiveMessage` at all three call sites in
`extension.js`, each with different minified names, in one pass. Sentinel
`notify-queue-user-action-v3`.

## outbound-action-injector

**What it does.** The inbound half of a remote-control channel: it watches a
file in your workspace and, for each line, answers a pending tool-permission
prompt on your behalf — the same accept or reject a click on Allow or Deny
performs.

**Why.** It is what lets a notification on your desktop carry working Allow and
Deny buttons rather than merely telling you to come back to the editor.

**What changes visibly.** Nothing, until something writes to the file.

**Cost and side effects.** The heaviest of the five. It **polls
`.devcontainer/logs/claude-code-vscode-ext-outbound.jsonl` every 200 ms** for
as long as a Claude panel is open, creates that file and
`claude-code-vscode-ext-pending-perms.jsonl` alongside it, and records every
outstanding permission request. Anything able to write that file inside your
workspace can approve a tool call as if you had clicked. Treat the file as
part of your trust boundary; if that is not a trade you want, exclude the
`notify` category.

**Mechanics.** Two injections into `extension.js` — a singleton watcher at the
top of `setupPanel()`, guarded so only the first panel starts it, and
instrumentation on `sendRequest`. Sentinels `notify-queue-outbound-inject-v1`,
`-perm-log-v2`, `-perm-settle-v2`, `-session-track-v1`.

## webview-simulated-click

**What it does.** The webview half of the same channel: it receives the
replayed answer and calls the accept or reject method on the matching pending
permission request.

**Why.** The answer has to arrive through the same code path a real click takes,
otherwise the rest of the extension never learns the question was settled.

**What changes visibly.** Nothing.

**Cost and side effects.** None on its own — it is inert without
`outbound-action-injector`.

**Mechanics.** Three coordinated injections into `webview/index.js`. The wire
request id is not stored on the permission-request object, so two of the three
exist only to carry it to the point where the match is made. Sentinels
`notify-queue-webview-sim-click-v2`, `-perm-reqid-callsite-v1`,
`-perm-reqid-tag-v1`.

---

## The honest part: what the `notify` patches write

These five are one end of a notification channel. Its other end — the desktop
application that consumes the queue and shows the notification — is **not** part
of this image yet. What this image does ship is the producing side: the
`notify-queue` skill, a boot fragment that clears the JSONL files at every
container start, and these patches.

So on a container you have just started, with nothing configured, the
extension will:

- create `.devcontainer/notify/queue/` in your workspace and write a small
  `.authority` file into it;
- append every message you send in the chat, prompt text included, to
  `.devcontainer/logs/claude-code-vscode-ext-inbound.jsonl`;
- create and poll `.devcontainer/logs/claude-code-vscode-ext-outbound.jsonl`
  every 200 ms, and keep a record of pending permission requests next to it.

Two mitigations already in the image: `.devcontainer/logs/` is created anyway
for the hook phase logs, so that directory is not something the patches
introduce, and the three JSONL files are deleted at every container start —
they are observation data, not history. Neither of those changes the fact that
while a container runs, the prompts you type sit in a file in your workspace,
and that a process able to write one of those files can answer a permission
prompt for you.

If your workspace is a git repository you share, add `.devcontainer/logs/` and
`.devcontainer/notify/` to `.gitignore`.

If you do not want any of it:

    docker build --build-arg CLAUDE_CODE_EXT_PATCHS=ux,fix .   # at build
    restore-ext-patches ux,fix                                 # or afterwards

Nothing else in the image depends on those five patches. Removing them costs
you desktop notifications, and nothing more.

---

## Writing your own

An image built `FROM` this one can add its own patchers, and the seam is
documented — see `AUTHORING.md` next to this file for the header contract,
how to pick an anchor in a minified bundle that survives a version bump, and
how to fail in a way that does not break someone's build.
