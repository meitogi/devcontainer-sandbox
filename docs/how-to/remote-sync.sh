#!/usr/bin/env bash
# remote-sync.sh — keeps the Mac you sit at (Mac 1 : VS Code window, Fork,
# GitHub credentials) in step with the Mac that holds a project and runs its
# devcontainer (Mac 2), over ssh. Runs on Mac 1, from any directory.
# Guide : develop-from-another-mac.md, next to this file.
#
# USAGE
#   bash remote-sync.sh seed      HOST [--at PATH] [PROJECT_DIR]
#   bash remote-sync.sh volumes   HOST [PROJECT_DIR]
#   bash remote-sync.sh pull      HOST [--at PATH] [--wip] [PROJECT_DIR ...]
#   bash remote-sync.sh push-back HOST [--at PATH] [PROJECT_DIR ...]
#
#   HOST is what you type after `ssh` to reach Mac 2 (an alias such as mac2,
#   or user@name.local). PROJECT_DIR is the project on Mac 1, `.` by default.
#   On Mac 2 the project sits at the SAME absolute path, unless --at says
#   where (one PROJECT_DIR only).
#
# COMMANDS
#   seed       First move : copies the project folder, as it is, to Mac 2.
#              Refuses if the folder already exists there and is not empty.
#   volumes    Copies the project's named Docker volumes (Claude login and
#              history, databases…) to Mac 2's Docker. Close the VS Code
#              window first : it refuses while a container uses them. Asks
#              volume by volume (skip a dind or cache one, it can weigh tens of
#              GB) ; never overwrites a volume that already holds data on Mac 2.
#   pull       Finds every git repository under the project on Mac 2, clones
#              the ones Mac 1 lacks at the same relative path, fetches the rest
#              into a remote named after HOST, fast-forwards your local
#              branches when that is safe, and lists what is not pushed to
#              GitHub yet and what is not committed on Mac 2.
#              --wip : also brings back uncommitted changes to tracked files, as
#              <remote>/wip (`git stash apply <remote>/wip`), and lists the
#              untracked files. Mac 2's files are not touched ; it gains one
#              ref, refs/wip/remote-sync. For when you work locally again.
#   push-back  After you amended or dropped a commit in Fork and pushed : sends
#              your branches to Mac 2 as mac1/<branch>, without touching its
#              checked-out files, and prints the one command that realigns
#              each branch there.
#
# Worktrees made inside a container (a `.git` FILE pointing to /workspace/…)
# are skipped : git cannot open them from the host, and their commits are in
# the parent repository anyway.
#
# NEEDS : git and ssh on Mac 1 (tar for seed, docker for volumes) ; Remote
# Login on Mac 2 with git (xcode-select --install) and, for volumes, Docker.
# REMOTE_SYNC_SSH replaces the ssh command (tests ; or "ssh -p 2222").

main() {
  set -o pipefail
  cmd="${1:-}"
  case "$cmd" in
    seed|volumes|pull|push-back) ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  host="${2:-}"
  [ -n "$host" ] || { echo "remote-sync: HOST missing — what you type after ssh to reach Mac 2" >&2; return 2; }
  shift 2
  at=""; wip=0; ndirs=0; dirs=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) [ -n "${2:-}" ] || { echo "remote-sync: --at needs a path on $host" >&2; return 2; }; at="$2"; shift 2 ;;
      --wip) wip=1; shift ;;
      -*) echo "remote-sync: unknown option $1" >&2; return 2 ;;
      *) dirs="$dirs$1$NL"; ndirs=$((ndirs + 1)); shift ;;
    esac
  done
  [ "$ndirs" -gt 0 ] || { dirs=".$NL"; ndirs=1; }
  [ -z "$at" ] || [ "$ndirs" -eq 1 ] || { echo "remote-sync: --at goes with one project folder only" >&2; return 2; }
  [ "$wip" -eq 0 ] || [ "$cmd" = pull ] || { echo "remote-sync: --wip goes with pull" >&2; return 2; }

  need git
  need "${SSH%% *}"
  [ "$cmd" != seed ] || need tar
  [ "$cmd" != volumes ] || need docker
  [ -z "$MISSING" ] || { echo "remote-sync: missing on this Mac :$MISSING" >&2; return 2; }
  [ -z "${REMOTE_SYNC_SSH:-}" ] || export GIT_SSH_COMMAND="$SSH"
  export GIT_TERMINAL_PROMPT=0

  if ! $SSH "$host" true </dev/null; then
    echo "remote-sync: \`$SSH $host\` does not answer. On Mac 2 : System Settings > General >" >&2
    echo "  Sharing > Remote Login on ; then check \`ssh $host\` alone from this Terminal." >&2
    return 1
  fi
  h="${host##*@}"
  case "$h" in *[!0-9.]*) h="${h%%.*}" ;; esac
  name="$(printf '%s' "$h" | sed 's/[^A-Za-z0-9_-]/-/g')"
  rc=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # pull may start from nothing : that is the local fallback on a fresh Mac 1
    made=""
    if [ "$cmd" = pull ] && [ ! -e "$d" ]; then mkdir -p "$d" && made=1; fi
    [ -d "$d" ] || { echo "remote-sync: not a folder : $d" >&2; rc=2; continue; }
    local_abs="$(cd "$d" && pwd -P)"
    remote_root="${at:-$local_abs}"
    echo "== $local_abs  <->  $host:$remote_root"
    "cmd_${cmd//-/_}" </dev/null || rc=$?
    [ -z "$made" ] || rmdir "$d" 2>/dev/null || true
  done <<EOF
$dirs
EOF
  return $rc
}

NL='
'
SEP="$(printf '\037')"
SSH="${REMOTE_SYNC_SSH:-ssh}"
MISSING=""
need() { command -v "$1" >/dev/null 2>&1 || MISSING="$MISSING $1"; }
usage() { sed -n '2,/^$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# A Mac 2 path for its shell : ~/… expands there, everything else stays literal.
rq() { case "$1" in "~") printf '"$HOME"' ;; "~/"*) printf '"$HOME"/%s' "$(sq "${1#\~/}")" ;; *) sq "$1" ;; esac; }
rsh() { $SSH "$host" "$@"; }
# Mac 2's non-interactive ssh PATH is /usr/bin:/bin:/usr/sbin:/sbin — no Docker.
RPATH='PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin";'

# ------------------------------------------------------------------- seed
cmd_seed() {
  t="$(rq "$remote_root")"
  if rsh "[ -e $t ] && [ -n \"\$(ls -A $t 2>/dev/null)\" ]" </dev/null; then
    echo "   $host:$remote_root exists and is not empty : nothing copied." >&2
    echo "   Already seeded ? Then use pull. Otherwise pick an empty place with --at." >&2
    return 1
  fi
  echo "   copying $(du -sh "$local_abs" 2>/dev/null | cut -f1) — no progress bar, this is not a hang"
  if ! tar -C "$local_abs" -cf - . | rsh "mkdir -p $t && tar -C $t -xf -"; then
    echo "   copy failed (disk full on $host, or the parent folder is not writable there)" >&2
    return 1
  fi
  echo "   done. Next : volumes (optional), then pull once, then open the folder on $host."
}

# ---------------------------------------------------------------- volumes
cmd_volumes() {
  img="alpine:3.22"
  ids="$(docker ps -aq --filter "label=devcontainer.local_folder=$local_abs")"
  [ -n "$ids" ] || { echo "   no devcontainer on this Mac for this folder (never opened here ?) : nothing to copy"; return 0; }
  projects=""
  for i in $ids; do
    p="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$i")"
    [ -z "$p" ] || projects="$projects $p"
  done
  for p in $projects; do ids="$ids $(docker ps -aq --filter "label=com.docker.compose.project=$p")"; done
  list=""
  for i in $ids; do
    list="$list$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' "$i")$NL"
  done
  list="$(printf '%s' "$list" | grep -vE '^[0-9a-f]{64} ' | grep . | sort -u)"
  [ -n "$list" ] || { echo "   no named volume : nothing to copy"; return 0; }
  busy=""
  for v in $(printf '%s\n' "$list" | cut -d' ' -f1 | sort -u); do
    [ -z "$(docker ps -q --filter "volume=$v")" ] || busy="$busy $v"
  done
  if [ -n "$busy" ]; then
    echo "   in use by a running container :$busy" >&2
    echo "   Close the VS Code window of this project, stop its containers in Docker Desktop, run again." >&2
    return 1
  fi
  if ! rsh "$RPATH docker image inspect $img >/dev/null 2>&1 || docker pull -q $img >/dev/null" </dev/null; then
    echo "   Docker on $host does not answer, or cannot pull $img." >&2
    echo "   On Mac 2 : start Docker Desktop, then in its Terminal : docker pull $img" >&2
    return 1
  fi
  echo "   one question per volume — a dind or cache volume can weigh tens of GB, skip it"
  for v in $(printf '%s\n' "$list" | cut -d' ' -f1 | sort -u); do
    at_="$(printf '%s\n' "$list" | awk -v n="$v" '$1==n {print $2}' | sort -u | tr '\n' ' ')"
    printf '   copy %s (mounted at %s) to %s ? [y/N] ' "$v" "${at_% }" "$host"
    ans=""
    if [ -n "${REMOTE_SYNC_YES:-}" ]; then ans=y; echo y; else read -r ans </dev/tty || ans=""; fi
    case "$ans" in y|Y|yes|o|oui) ;; *) echo "   $v : skipped"; continue ;; esac
    q="$(sq "$v")"
    if rsh "$RPATH docker volume inspect $q >/dev/null 2>&1 && [ -n \"\$(docker run --rm -v $q:/v $img ls -A /v)\" ]" </dev/null; then
      echo "   $v : already holds data on $host, kept"
      continue
    fi
    if docker run --rm -v "$v":/v:ro "$img" tar -C /v -cf - . | rsh "$RPATH docker run --rm -i -v $q:/v $img tar -C /v -xf -"; then
      echo "   $v : copied"
    else
      rsh "$RPATH docker volume rm -f $q >/dev/null 2>&1" </dev/null
      echo "   $v : FAILED — nothing left on $host, run again" >&2; return 1
    fi
  done
}

# ------------------------------------------------------------------ remote
# Runs on Mac 2 : one line per repository, fields separated by \037.
REMOTE_LIST='
main() {
  root="$1"; wip="$2"; S="$(printf "\037")"
  case "$root" in "~") root="$HOME" ;; "~/"*) root="$HOME/${root#\~/}" ;; esac
  command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1 || { echo "ERR${S}git"; return 0; }
  [ -d "$root" ] || { echo "ERR${S}nodir"; return 0; }
  cd "$root" || return 0
  echo "ROOT${S}$(pwd -P)"
  find . \( -name node_modules -o -name .Trash \) -prune -o -name .git -print -prune 2>/dev/null | LC_ALL=C sort |
  while IFS= read -r g; do
    d="${g%/.git}"; rel="${d#./}"
    if [ ! -d "$g" ]; then echo "SKIP${S}$rel"; continue; fi
    br="$(git -C "$d" symbolic-ref -q --short HEAD)"
    st="$(git --no-optional-locks -C "$d" status --porcelain 2>/dev/null)"
    mod="$(printf "%s\n" "$st" | grep -c "^[^?]")"
    unt="$(printf "%s\n" "$st" | grep -c "^??")"
    origin="$(git -C "$d" remote get-url origin 2>/dev/null)"
    w=""
    if [ "$wip" = 1 ]; then
      [ "$mod" -eq 0 ] || w="$(git -C "$d" stash create 2>/dev/null)"
      if [ -n "$w" ]; then git -C "$d" update-ref refs/wip/remote-sync "$w"
      else git -C "$d" update-ref -d refs/wip/remote-sync 2>/dev/null; fi
      git -c core.quotepath=off -C "$d" ls-files --others --exclude-standard | while IFS= read -r f; do echo "UNT${S}$rel${S}$f"; done
    fi
    echo "REPO${S}$rel${S}$br${S}$mod${S}$unt${S}$w${S}$origin"
  done
}
main "$@" </dev/null
'

remote_list() {
  rsh "bash -s -- $(sq "$remote_root") $1" <<EOF
$REMOTE_LIST
EOF
}

# -------------------------------------------------------------------- pull
cmd_pull() {
  out="$(remote_list "$wip")" || { echo "   listing the repositories on $host failed" >&2; return 1; }
  case "$out" in
    "ERR${SEP}git"*) echo "   git does not run on $host : in its Terminal, xcode-select --install" >&2; return 1 ;;
    "ERR${SEP}nodir"*) echo "   $host:$remote_root does not exist (seed first, or --at the right path)" >&2; return 1 ;;
  esac
  rroot="$(printf '%s\n' "$out" | sed -n "s/^ROOT$SEP//p")"
  skipped=0; quiet=0; repos=0; noremote=0; failed=0
  while IFS="$SEP" read -r kind rel br mod unt w origin; do
    case "$kind" in
      SKIP) skipped=$((skipped + 1)); continue ;;
      UNT) continue ;;
      REPO) ;;
      *) continue ;;
    esac
    repos=$((repos + 1))
    if [ "$rel" = . ]; then L="$local_abs"; url="$host:$rroot"; else L="$local_abs/$rel"; url="$host:$rroot/$rel"; fi
    notes=""
    if [ ! -e "$L/.git" ]; then
      if [ -d "$L" ] && [ -n "$(ls -A "$L" 2>/dev/null)" ]; then
        echo "   $rel : a folder that is not a git repository is in the way, skipped" >&2; continue
      fi
      if ! e="$(git clone -q -o "$name" "$url" "$L" 2>&1)"; then
        echo "   $rel : clone FAILED from $url — $(printf '%s\n' "$e" | head -1)" >&2; failed=$((failed + 1)); continue
      fi
      notes=" cloned"
      if [ -n "$origin" ]; then
        # Pushes go to GitHub, never back to Mac 2 : the clone made $name the upstream.
        git -C "$L" remote add origin "$origin"
        git -C "$L" config remote.pushDefault origin
        if git -C "$L" fetch -q origin 2>/dev/null; then
          b="$(git -C "$L" symbolic-ref -q --short HEAD)"
          if [ -n "$b" ] && git -C "$L" show-ref -q --verify "refs/remotes/origin/$b"; then
            git -C "$L" branch -q --set-upstream-to="origin/$b" "$b"
          elif [ -n "$b" ]; then
            git -C "$L" branch -q --unset-upstream "$b" 2>/dev/null
          fi
        else
          notes="$notes (origin not fetched)"
        fi
      fi
    else
      cur="$(git -C "$L" remote get-url "$name" 2>/dev/null)"
      if [ -z "$cur" ]; then git -C "$L" remote add "$name" "$url"
      elif [ "$cur" != "$url" ]; then git -C "$L" remote set-url "$name" "$url"; fi
      if ! e="$(git -C "$L" fetch -q --prune "$name" 2>&1)"; then
        echo "   $rel : fetch FAILED from $url — $(printf '%s\n' "$e" | head -1)" >&2; failed=$((failed + 1)); continue
      fi
    fi
    if [ -n "$w" ]; then
      git -C "$L" fetch -q "$name" "+refs/wip/remote-sync:refs/remotes/$name/wip" 2>/dev/null &&
        notes="$notes ; uncommitted changes as $name/wip (git stash apply $name/wip)"
    else
      git -C "$L" update-ref -d "refs/remotes/$name/wip" 2>/dev/null
    fi
    notes="$notes$(fast_forward "$L")"
    has_origin=0; git -C "$L" remote get-url origin >/dev/null 2>&1 && has_origin=1
    if [ "$has_origin" -eq 1 ]; then
      n="$(git -C "$L" rev-list --count --branches --not --remotes=origin 2>/dev/null)"
      # Our view of GitHub may be stale (Mac 2 may have pushed) : refresh before saying so.
      if [ "${n:-0}" -gt 0 ] && git -C "$L" fetch -q origin 2>/dev/null; then
        n="$(git -C "$L" rev-list --count --branches --not --remotes=origin 2>/dev/null)"
      fi
      [ "${n:-0}" -eq 0 ] || notes="$notes ; $n commit(s) not on GitHub yet"
    else
      noremote=$((noremote + 1))
    fi
    [ "$mod" -eq 0 ] && [ "$unt" -eq 0 ] || notes="$notes ; on $host : $mod modified, $unt untracked"
    if [ "$wip" -eq 1 ] && [ "$unt" -gt 0 ]; then
      notes="$notes$NL$(printf '%s\n' "$out" | awk -F"$SEP" -v r="$rel" '$1=="UNT" && $2==r {n++; if (n<=20) print "       untracked : " $3} END {if (n>20) print "       … and " n-20 " more"}')"
    fi
    [ -n "$notes" ] || { quiet=$((quiet + 1)); continue; }
    echo "   $rel :${notes# ;}"
  done <<EOF
$out
EOF
  [ "$repos" -gt 0 ] || echo "   no git repository under $host:$rroot"
  echo "   $repos repositories ($quiet with nothing to report, $noremote without a GitHub remote) ; $skipped .git file(s) skipped (container worktrees, submodules)"
  [ "$failed" -eq 0 ] || { echo "   $failed repository(ies) FAILED, see above" >&2; return 1; }
}

# Fast-forwards each local branch that Mac 2 moved ahead of, when that is safe.
fast_forward() {
  L="$1"; s=""
  cur="$(git -C "$L" symbolic-ref -q --short HEAD)"
  busy="$(git -C "$L" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p')"
  for rb in $(git -C "$L" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$name/"); do
    case "$rb" in HEAD|wip) continue ;; esac
    r="refs/remotes/$name/$rb"
    if ! git -C "$L" show-ref -q --verify "refs/heads/$rb"; then
      s="$s ; new branch on $host : $rb"; continue
    fi
    lh="$(git -C "$L" rev-parse "refs/heads/$rb")"; rh="$(git -C "$L" rev-parse "$r")"
    [ "$lh" != "$rh" ] || continue
    if git -C "$L" merge-base --is-ancestor "$lh" "$rh"; then
      n="$(git -C "$L" rev-list --count "$lh..$rh")"
      if [ "$rb" != "$cur" ] && printf '%s\n' "$busy" | grep -qxF "$rb"; then
        s="$s ; $rb : $n new on $host, NOT fast-forwarded (checked out in another worktree)"; continue
      fi
      if [ "$cur" = "$rb" ]; then
        if [ -n "$(git -C "$L" status --porcelain --untracked-files=no)" ]; then
          s="$s ; $rb : $n new on $host, NOT fast-forwarded (local changes here)"; continue
        fi
        if ! e="$(git -C "$L" merge -q --ff-only "$r" 2>&1)"; then
          s="$s ; $rb : NOT fast-forwarded — $(printf '%s\n' "$e" | sed -n '1s/^error: //p')"; continue
        fi
      else
        git -C "$L" update-ref "refs/heads/$rb" "$rh" "$lh"
      fi
      s="$s ; $rb +$n"
    elif git -C "$L" merge-base --is-ancestor "$rh" "$lh"; then
      s="$s ; $rb : $(git -C "$L" rev-list --count "$rh..$lh") commit(s) here that $host lacks (push-back ?)"
    else
      s="$s ; $rb : DIVERGED from $host — amended in Fork ? then push-back"
    fi
  done
  printf '%s' "$s"
}

# --------------------------------------------------------------- push-back
cmd_push_back() {
  out="$(remote_list 0)" || { echo "   listing the repositories on $host failed" >&2; return 1; }
  rroot="$(printf '%s\n' "$out" | sed -n "s/^ROOT$SEP//p")"
  [ -n "$rroot" ] || { echo "   $host:$remote_root does not exist, or git does not run there" >&2; return 1; }
  hints=""; failed=0
  while IFS="$SEP" read -r kind rel br rest; do
    [ "$kind" = REPO ] || continue
    if [ "$rel" = . ]; then L="$local_abs"; else L="$local_abs/$rel"; fi
    git -C "$L" remote get-url "$name" >/dev/null 2>&1 || continue
    git -C "$L" fetch -q --prune "$name" 2>/dev/null || { echo "   $rel : fetch FAILED" >&2; failed=$((failed + 1)); continue; }
    specs=""; diff=""
    for rb in $(git -C "$L" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$name/"); do
      case "$rb" in HEAD|wip) continue ;; esac
      git -C "$L" show-ref -q --verify "refs/heads/$rb" || continue
      specs="$specs +refs/heads/$rb:refs/remotes/mac1/$rb"
      if [ "$(git -C "$L" rev-parse "refs/heads/$rb")" != "$(git -C "$L" rev-parse "refs/remotes/$name/$rb")" ]; then
        diff="$diff $rb"
      fi
    done
    [ -n "$specs" ] || continue
    # shellcheck disable=SC2086
    if ! git -C "$L" push -q "$name" $specs 2>/dev/null; then
      echo "   $rel : push to $host FAILED" >&2; failed=$((failed + 1)); continue
    fi
    for rb in $diff; do
      gone="$(git -C "$L" log --format='       - %h %s' "refs/heads/$rb..refs/remotes/$name/$rb" | head -10)"
      if [ "$rb" = "$br" ]; then
        realign="git -C $(sq "$rel") reset --keep mac1/$rb"
      else
        realign="git -C $(sq "$rel") branch -f $rb mac1/$rb"
      fi
      hints="$hints   $rel, $rb — in the container : $realign$NL"
      [ -z "$gone" ] || hints="$hints     drops these commits from $host's $rb (check they are the ones you amended ; one you never pulled ? then pull first, do not reset) :$NL$gone$NL"
    done
    echo "   $rel : sent as mac1/*"
  done <<EOF
$out
EOF
  if [ -n "$hints" ]; then
    echo "   To realign Mac 2 (or ask Claude there to run it) :"
    printf '%s' "$hints"
  else
    echo "   Mac 2 already matches your branches : nothing to realign."
  fi
  [ "$failed" -eq 0 ] || return 1
}

main "$@"
