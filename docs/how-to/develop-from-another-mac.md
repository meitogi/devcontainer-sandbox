# Develop from another Mac

**Goal.** The project and its devcontainer live on one Mac — call it
**Mac 2** — and you work from another, **Mac 1**, that keeps the VS Code
window, your Git client and your GitHub credentials. Over the local network or
a VPN, it makes no difference once `ssh mac2` answers.

The route is **Remote-SSH to Mac 2, then Reopen in Container**. The commits the
agent makes on Mac 2 come back to Mac 1 over ssh, you review and push them from
Mac 1 : the container never holds push credentials.

*Commands in this page say where they run : **Mac 1** or **Mac 2** (the
macOS Terminal), or **container** (a terminal inside the devcontainer).*

---

## Read this first : what changes when the window and the files part

### 1. `initializeCommand` runs on Mac 2

`initializeCommand` is the one lifecycle hook that runs outside the container,
[on the host machine](https://containers.dev/implementors/json_reference/) —
the machine where the Dev Containers extension drives Docker. In a Remote-SSH
window that is **Mac 2**, not the Mac you sit at. So on Mac 2 :

- `.devcontainer/initialize.sh` needs **Node 18 or later**. It looks in the
  usual version-manager folders (nvm, fnm, asdf, Volta, Homebrew) on its own,
  so a Node there is enough even when the ssh login shell does not see it.
- `devc initialize` writes `.devcontainer/.env`, the `.vscode/settings.json`
  stub and the empty Claude credentials volume **on Mac 2** — where the
  container mounts them, which is what you want.

This is also why a *remote Docker context* (`docker context create …
--docker host=ssh://…` on Mac 1) is not the route : `initializeCommand` would
run on Mac 1 and prepare a tree the container on Mac 2 never mounts —
[Docker does not bind-mount your local files into a remote container](https://code.visualstudio.com/remote/advancedcontainers/develop-remote-host).

### 2. Notifications show up on Mac 2's screen

`devc initialize` also starts the notification daemon — on Mac 2. The agent's
« I'm done » / « I need you » notifications therefore appear on Mac 2, not on
the Mac in front of you. Nothing to fix on your side ; it changes when the
notification loop moves into a VS Code extension, which runs where the window is.

### 3. Ports : TCP comes to Mac 1, UDP does not

- **Forwarded ports** (`forwardPorts`, `portsAttributes`, auto-forward) travel
  through the ssh connection and land on **Mac 1's `localhost`**. A
  `*.localhost` subdomain still resolves to Mac 1, so per-branch routers keep
  working. A port marked `requireLocalPort` fails if Mac 1 already uses it —
  typically the same project still open *locally* on Mac 1 : close that one.
- **ssh carries TCP only.** A UDP port — a direct WebRTC path, a game server's
  UDP — never reaches Mac 1 through the forward.
- **Published ports** (compose `ports:`, `appPort`) bind on **Mac 2**. Bound to
  `127.0.0.1`, nothing outside Mac 2 reaches them ; bound to all interfaces,
  every machine on the network reaches them at `mac2.local:<port>`.
- `host.docker.internal`, and anything the container expects to find « on the
  host » (the agent browser's Chromium, a local model server), is **Mac 2**.

### 4. What does not travel with the folder

- **Docker volumes** — the Claude login and history, databases. They live in
  Mac 1's Docker. `remote-sync.sh volumes` copies the ones you pick (step 3),
  the devcontainer's and those of any compose stack started from a folder of
  the project. Such a host-side stack must then be started on Mac 2 : that is
  where `host.docker.internal` points now.
- **Worktrees the agent made inside the container** : their `.git` file points
  at `/workspace/…`, a path that exists only inside a container. Git cannot
  open them from either Mac ; their commits are in the parent repository
  anyway, and the sync script skips them.
- **Git LFS files** of commits that are not on GitHub yet : an ssh fetch brings
  the pointers, not the files. Review works ; the files arrive once pushed.

---

## Steps

Everything on Mac 1 goes through one script, [remote-sync.sh](remote-sync.sh),
next to this page. Its header is the full reference ; `bash ~/remote-sync.sh
--help` prints it. Fetch it once, on Mac 1 :

```
curl -fsSLo ~/remote-sync.sh https://raw.githubusercontent.com/meitogi/devcontainer-sandbox/master/docs/how-to/remote-sync.sh
```

### 1. Prepare Mac 2 (once, on Mac 2)

- **System Settings → General → Sharing → Remote Login** : on.
- **Docker Desktop** installed and started.
- Git (the Command Line Tools) :

```
xcode-select --install
```

- Node 18 or later, for `initializeCommand` — nvm, Homebrew or the installer
  from nodejs.org, any of them.
- The name to reach it by :

```
scutil --get LocalHostName
```

### 2. Reach Mac 2 from Mac 1 (once, on Mac 1)

Add an alias to `~/.ssh/config` — replace `Mac-Studio` with the name step 1
printed and `me` with your user name on Mac 2 :

```
Host mac2
  HostName Mac-Studio.local
  User me
```

Then a key, so neither ssh nor VS Code asks for a password :

```
ssh-copy-id mac2
```

(`ssh-keygen -t ed25519` first if `~/.ssh` has no key.) Check :

```
ssh mac2 git --version
```

It must print a version, not a prompt. In VS Code, install the **Remote - SSH**
extension.

### 3. Move a project (once per project, on Mac 1, at the project root)

Close the project's VS Code window first. Then copy the folder — it lands at
the **same absolute path** on Mac 2, so nothing has to be translated (`--at`
picks another place) :

```
bash ~/remote-sync.sh seed mac2
```

Copy the Docker volumes you want to keep — the script asks volume by volume,
and never overwrites one that already holds data on Mac 2 :

```
bash ~/remote-sync.sh volumes mac2
```

Then link every repository of the project to Mac 2 — this adds a `mac2`
remote to each one :

```
bash ~/remote-sync.sh pull mac2
```

### 4. Open it (Mac 1)

**Remote-SSH : Connect to Host… → mac2**, **File → Open Folder** on the
project's path, then **Dev Containers : Reopen in Container**. The first open
builds or pulls the image on Mac 2.

From now on Mac 2's copy is the one you work in ; Mac 1's copy is where
commits come back for review.

### 5. Bring the commits back (Mac 1, at the project root)

```
bash ~/remote-sync.sh pull mac2
```

No need to leave VS Code : in the Remote-SSH window, **Terminal : Create New
Integrated Terminal (Local)** (command palette) opens a terminal on Mac 1.

For every repository under the project — discovered on Mac 2, nothing to
list — it clones the ones Mac 1 lacks at the same relative path, fetches the
rest, fast-forwards your local branches when that is safe, creates the branches
the agent started there that are not on GitHub yet, and says what is
uncommitted on Mac 2. No merge : Mac 1's copy is for review, so Mac 2's commits
always land on top. Review in your Git client and push — it goes to GitHub
(`origin`), a new branch included.

### 6. You amended or dropped a commit before pushing

Mac 2 still has the old commit, and it cannot fetch the new one from GitHub —
the container has no credentials, by design. After pushing from Mac 1 :

```
bash ~/remote-sync.sh push-back mac2
```

It sends your branches to Mac 2 as `mac1/<branch>` without touching its files,
and prints, for each branch that differs, the commits Mac 2 would drop and the
command that realigns it — for the checked-out branch :

```
git reset --keep mac1/main
```

Run it in the **container** (or ask the agent to). `--keep` refuses rather than
overwrite uncommitted work. If Mac 2 made new commits since your last `pull`,
`pull` first : they would be in the « would drop » list.

### 7. Back to local, when the remote setup breaks (Mac 1)

As long as `ssh mac2` answers :

```
bash ~/remote-sync.sh pull mac2 --wip
```

Commits come back as in step 5 ; uncommitted changes to tracked files come back
too, as `mac2/wip`, and untracked files are listed by name (copy the ones you
need). In each repository that has one :

```
git stash apply mac2/wip
```

Then open the project on Mac 1 as before — **Reopen in Container** locally.
Mac 2's files are not touched ; it only gains a `refs/wip/remote-sync` ref.

No Mac 1 copy at all ? `pull` into an empty folder rebuilds the project,
every repository at its place : `bash ~/remote-sync.sh pull mac2 --at
/path/on/mac2 ~/projects/name`.

---

## Check it worked

- `ssh mac2 git --version` prints a version.
- In the Remote-SSH window, the container's terminal shows your project at
  `/workspace` ; the **Ports** panel lists the forwarded ports, and opening one
  in Mac 1's browser reaches the container.
- After the agent commits on Mac 2, `pull` prints `main +1` for that
  repository and your Git client on Mac 1 shows the commit, ahead of GitHub.
