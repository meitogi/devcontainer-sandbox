#!/usr/bin/env bash
# swiftbar-agent-browser.5s.sh — the agent browser in the menu bar (SwiftBar or
# xbar, refreshed every 5 s). `host-agent.sh install` copies it into SwiftBar's
# plugin folder with this project's label on the LABEL line below: like the
# supervisor, it never runs from the kit.
#
#   ○ circle         agent loaded, Chromium off
#   ● circle.fill    Chromium running for the container
#   ⚠ triangle       a Chromium on the agent profile the supervisor did not start
#   ⊘ circle.slash   agent not loaded (launchd)
#
# install draws the project's own icon over those (menubar-icon.mjs) and writes
# it in the ICON_ lines below, one template image per state ; empty, the SF
# Symbols above stay. NOTE_B64 is the instance's note (AGENT_BROWSER_<X>_NOTE),
# base64 so that nothing in it is ever read as shell ; shown under the name.
#
# Its paths come from the launchd plist install wrote. Bash 3.2 (the Mac's).
set -u
LABEL=io.meitogi.agent-browser.PROJECT
ICON_RUNNING=
ICON_IDLE=
ICON_UNLOADED=
ICON_STRAY=
NOTE_B64=
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
plist_env() { /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$1" "$PLIST" 2>/dev/null; }
CTL=$(plist_env AGENT_BROWSER_CTL)
PROFILE=$(plist_env AGENT_BROWSER_PROFILE)
LOGDIR=$(plist_env AGENT_BROWSER_LOGDIR)

# The pid holding the profile's SingletonLock, when it is alive and a Chromium.
lock_pid() {
	local p
	p=$(readlink "$PROFILE/SingletonLock" 2>/dev/null)
	p=${p##*-}
	[ -n "$p" ] && ps -p "$p" -o command= 2>/dev/null | grep -q -- "--user-data-dir=$PROFILE" && echo "$p"
}

case ${1:-} in
	off)
		[ -n "$CTL" ] && printf '%s down\n' "$(date +%s)000000000" >"$CTL/cmd"
		exit 0 ;;
	kill)
		p=$(lock_pid)
		[ -n "$p" ] && kill "$p"
		exit 0 ;;
	start)
		launchctl bootstrap "$DOMAIN" "$PLIST"
		exit 0 ;;
	stop)
		launchctl bootout "$DOMAIN/$LABEL"
		exit 0 ;;
esac

loaded=0
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && loaded=1
read -r _ word spid surl 2>/dev/null <"$CTL/state" || word=none
holder=$(lock_pid)
stray=''
if [ -n "$holder" ] && { [ "$word" != running ] || [ "$holder" != "$spid" ]; }; then
	stray=$holder
fi

# The project's name, atop the menu ; beside the icon too when it is an SF
# Symbol, since two circles alike say nothing about which agent is which. A
# drawn icon carries the project's letters and stands alone. A second instance
# of the same project reads <project>.b.
name=${LABEL#io.meitogi.agent-browser.}
# The status line: the state's template image when install drew one, else its
# SF Symbol.
icon() {
	if [ -n "$1" ]; then echo " | templateImage=$1"; else echo "$name | sfimage=$2"; fi
}
if [ -n "$stray" ]; then
	icon "$ICON_STRAY" exclamationmark.triangle
elif [ "$loaded" = 0 ]; then
	icon "$ICON_UNLOADED" circle.slash
elif [ "$word" = running ]; then
	icon "$ICON_RUNNING" circle.fill
else
	icon "$ICON_IDLE" circle
fi
echo "---"
echo "$name | size=11"
[ -n "$NOTE_B64" ] && echo "$(printf '%s' "$NOTE_B64" | base64 -D 2>/dev/null | tr -d '|') | size=11"
if [ "$loaded" = 0 ]; then
	echo "Agent not loaded — the container falls back to its sidecar"
	[ -f "$PLIST" ] && echo "Load the agent | bash='$0' param1=start terminal=false refresh=true"
else
	case $word in
		running) echo "Chromium running (pid $spid) | sfimage=circle.fill" && echo "$surl | size=11" ;;
		*) echo "Chromium off — idle until the container asks | sfimage=circle" ;;
	esac
	[ "$word" = running ] && echo "Turn Chromium off | bash='$0' param1=off terminal=false refresh=true"
	echo "Unload the agent (sidecar takes over) | bash='$0' param1=stop terminal=false refresh=true"
fi
if [ -n "$stray" ]; then
	echo "---"
	echo "A Chromium outside the agent holds its profile (pid $stray) | sfimage=exclamationmark.triangle"
	echo "Kill it | bash='$0' param1=kill terminal=false refresh=true"
fi
echo "---"
echo "Open the logs | bash=/usr/bin/open param1='$LOGDIR' terminal=false"
