# host-agent.ps1 — install and watch the host's agent browser on WINDOWS. The
# Mac's is host-agent.sh ; both run the same supervisor, host-supervisor.mjs.
# Run on the HOST (PowerShell, not a container), from the project root, out of
# the kit extracted from the image (see the agent-browser skill, « Windows »):
#
#   powershell -ExecutionPolicy Bypass -File <kit>\host-agent.ps1 <verb> [args]
#
#   install [i…]    a Task Scheduler task for the current user (\meitogi\agent-browser\<project>[.x]),
#                   at logon, restarted on failure, no time limit, no window ; and its
#                   notification-area icon (tray.ps1, a second task). a alone without a
#                   list ; --all = every instance the firewall opens
#   start [i…]      enable and run an installed instance again (install it when it is not) ; a by default
#   stop [i…]       stop and disable its task, then kill the supervisor and Chromium as a
#                   tree (a stopped task leaves its children) ; it stays off across logons
#                   until start. Every installed one by default
#   uninstall [i…]  stop it, unregister both tasks, remove the copy, the profile, the logs
#   list [--json]   every instance of this project, one line each — the task's state, pids,
#                   proxy port and whether it listens, heartbeat, logs — and the other
#                   projects' agent browsers with their proxy ports, to spot a clash ;
#                   --json: the same as one object (instances[], others[]), for tools
#   status [i…]     the task's state and last result, heartbeat age, what the supervisor
#                   last answered, its Chromium, whether the proxy listens, the kit hash
#   logs [i]        follow the supervisor's, Chromium's and the DevTools proxy's logs
#   run [i]         the supervisor in THIS window, foreground, Ctrl-C stops it. Prints a
#                   block to paste to the agent
#   run <i> --temp  a temporary instance: the same, and Ctrl-C also removes its profile
#                   and logs. Refused on an installed instance
#   instances       which instances install --all would bring up, their ports, which are
#                   installed (reads only)
#   install <i> --port <n> [--cdp-port <n>]
#                   that instance on these ports instead of the .env's
#   install-chromium  download the latest Chromium snapshot for this PC (ARM64 or x64)
#                   into %LOCALAPPDATA%\agent-browser\chromium\ — the supervisor looks
#                   there first ; prints the AGENT_BROWSER_CHROMIUM line (edits no file)
#
# install and start print five numbered steps — kit, chromium, firewall,
# scheduler, heartbeat — each ok, warn or FAILED with the cause and the command
# to run next. Instances, ports, labels and the .env keys are host-agent.sh's
# (its header) ; what differs here:
#   - the task runs a COPY of the kit in %LOCALAPPDATA%\agent-browser\<project>[.x]\agent\,
#     its settings in env.json beside that folder (what a plist's
#     EnvironmentVariables are on a Mac), its profile and logs beside it too ;
#   - the supervisor starts through `conhost.exe --headless`: node is a console
#     program and would open a window at every logon ;
#   - the task's own stop is TerminateProcess, which leaves Chromium behind:
#     stop and uninstall kill the tree, and the supervisor sweeps its profile at start.
# Windows PowerShell 5.1 (what Windows ships), no admin rights.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:HostDir = $PSScriptRoot
$script:TaskPath = '\meitogi\agent-browser\'
$script:Step = ''

# ── the pure parts (dot-sourced by test/host-agent.Tests.ps1) ────────────────

function Write-Line([string]$Text) { [Console]::Out.WriteLine($Text) }

# Windows PowerShell 5.1 turns what a native program writes to stderr into an
# error record once it is captured (2>&1) — fatal under 'Stop'. Native calls
# whose output is captured go through here: 'Continue' in this scope only,
# the output as text lines, $LASTEXITCODE as the program left it.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
	$ErrorActionPreference = 'Continue'
	& $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
}

function Stop-Agent([string]$Message) {
	if ($script:Step) { [Console]::Error.WriteLine("✗ $($script:Step) FAILED — $Message") }
	else { [Console]::Error.WriteLine("✗ $Message") }
	exit 2
}

function Open-Step([int]$N, [string]$Name) { $script:Step = "[$N/5 $Name]" }
function Close-StepOk([string]$Text) { Write-Line "$($script:Step) ok — $Text"; $script:Step = '' }
function Close-StepWarn([string]$Text) { Write-Line "$($script:Step) warn — $Text"; $script:Step = '' }

# .devcontainer/.env as data, never run: KEY=value, the last one wins, quotes stripped.
function ConvertFrom-DotEnv([string]$Text) {
	$values = @{}
	foreach ($line in ($Text -split "`r?`n")) {
		if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
			# The key first: the quote match below overwrites $Matches.
			$key = $Matches[1]
			$v = $Matches[2]
			if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $Matches[1] }
			$values[$key] = $v
		}
	}
	return $values
}

# One configuration value: the environment wins over the .env, then the default.
function Get-Conf([string]$Name, [string]$Default = '') {
	$v = [Environment]::GetEnvironmentVariable($Name)
	if (-not $v -and $script:DotEnv.ContainsKey($Name)) { $v = $script:DotEnv[$Name] }
	if ($v) { return $v }
	return $Default
}

function ConvertTo-ProjectName([string]$Name) {
	return ($Name.ToLowerInvariant() -replace '[^a-z0-9-]', '-')
}

# The project's whole configuration, read once (globals, as host-agent.sh).
function Read-Project([string]$Repo) {
	$script:Repo = $Repo
	$envFile = Join-Path $Repo '.devcontainer\.env'
	$script:EnvFile = $envFile
	$script:DotEnv = @{}
	if (Test-Path -LiteralPath $envFile -PathType Leaf) { $script:DotEnv = ConvertFrom-DotEnv ([IO.File]::ReadAllText($envFile)) }
	$script:Project = ConvertTo-ProjectName (Get-Conf 'DC_PROJECT' (Split-Path -Leaf $Repo))
	$script:Origins = Get-Conf 'AGENT_BROWSER_ORIGINS'
	$script:Reach = Get-Conf 'AGENT_BROWSER_REACH'
	$script:Size = Get-Conf 'AGENT_BROWSER_SIZE' '1280,800'
	$script:Audio = Get-Conf 'AGENT_BROWSER_AUDIO' 'off'
	$script:Window = Get-Conf 'AGENT_BROWSER_WINDOW' '0'
	$script:BaseProxyPort = [int](Get-Conf 'AGENT_BROWSER_PROXY_PORT' '9223')
	$script:BaseCdpPort = [int](Get-Conf 'AGENT_BROWSER_CDP_PORT' '9323')
	$script:ProxyBind = Get-Conf 'AGENT_BROWSER_PROXY_BIND' '127.0.0.1'
	$script:Cert = Get-Conf 'AGENT_BROWSER_CERT'
	if ($script:Cert -and -not [IO.Path]::IsPathRooted($script:Cert)) { $script:Cert = Join-Path $Repo $script:Cert }
	$script:Chromium = Get-Conf 'AGENT_BROWSER_CHROMIUM'
	$script:IdleS = Get-Conf 'AGENT_BROWSER_IDLE_S' '360'
	$letters = (($script:Project -replace '[^a-z0-9]', '') + '').ToUpperInvariant()
	$script:IconLetters = Get-Conf 'AGENT_BROWSER_ICON_LETTERS' $letters.Substring(0, [Math]::Min(2, $letters.Length))
	$script:PortsFile = Join-Path $Repo '.devcontainer\firewall\ports.txt'
}

# Does the project's firewall open host:<port> ?
function Test-Opens([int]$Port) {
	if (-not (Test-Path -LiteralPath $script:PortsFile -PathType Leaf)) { return $false }
	foreach ($line in [IO.File]::ReadAllLines($script:PortsFile)) {
		if ((($line -replace '#.*', '') -replace '\s', '') -eq "host:$Port") { return $true }
	}
	return $false
}

$script:Letters = [char[]]'abcdefghijklmnopqrstuvwxyz' | ForEach-Object { [string]$_ }

# Every letter whose proxy port the project's firewall opens ; a when none.
function Get-Discovered {
	$list = @($script:Letters | Where-Object { Test-Opens ($script:BaseProxyPort + [int][char]$_ - 97) })
	if ($list.Count -eq 0) { return @('a') }
	return $list
}

# The names, paths and ports of one instance. Installed, its ports are its env.json's.
function Get-AbInstance([string]$Letter) {
	if ($Letter -notmatch '^[a-z]$') { Stop-Agent "instance '$Letter' : one letter, a (the default) to z" }
	$n = [int][char]$Letter - 97
	$suffix = ''
	if ($Letter -ne 'a') { $suffix = ".$Letter" }
	# No LOCALAPPDATA: `instances` read from a container, where nothing is installed.
	$local = $env:LOCALAPPDATA
	if (-not $local) { $local = Join-Path $HOME '.local\share' }
	$app = Join-Path $local "agent-browser\$($script:Project)$suffix"
	$ctl = Join-Path $script:Repo '.devcontainer\tmp\agent-browser'
	if ($Letter -ne 'a') { $ctl = Join-Path $ctl $Letter }
	$i = [ordered]@{
		Inst = $Letter
		Label = "io.meitogi.agent-browser.$($script:Project)$suffix"
		Task = "$($script:Project)$suffix"
		TrayTask = "tray.$($script:Project)$suffix"
		App = $app
		Agent = Join-Path $app 'agent'
		Profile = Join-Path $app 'profile'
		LogDir = Join-Path $app 'logs'
		EnvJson = Join-Path $app 'env.json'
		Icons = Join-Path $app 'icons'
		Ctl = Join-Path $ctl 'host'
		DerivedProxyPort = $script:BaseProxyPort + $n
		DerivedCdpPort = $script:BaseCdpPort + $n
		ProxyPort = $script:BaseProxyPort + $n
		CdpPort = $script:BaseCdpPort + $n
		Installed = $false
	}
	if (Test-Path -LiteralPath $i.EnvJson -PathType Leaf) {
		$i.Installed = $true
		$saved = Get-Content -LiteralPath $i.EnvJson -Raw | ConvertFrom-Json
		if ($saved.AGENT_BROWSER_PROXY_PORT) { $i.ProxyPort = [int]$saved.AGENT_BROWSER_PROXY_PORT }
		if ($saved.AGENT_BROWSER_CDP_PORT) { $i.CdpPort = [int]$saved.AGENT_BROWSER_CDP_PORT }
	}
	return [pscustomobject]$i
}

# What the supervisor needs: the env.json the task passes (--env), or the
# process environment for run. Every value a string.
function Get-SupervisorEnv($I, [string]$Node, [string]$ChromiumBin) {
	$chromium = $script:Chromium
	if (-not $chromium) { $chromium = $ChromiumBin }
	return [ordered]@{
		AGENT_BROWSER_CTL = $I.Ctl
		AGENT_BROWSER_PROFILE = $I.Profile
		AGENT_BROWSER_LOGDIR = $I.LogDir
		AGENT_BROWSER_ORIGINS = $script:Origins
		AGENT_BROWSER_REACH = $script:Reach
		AGENT_BROWSER_SIZE = $script:Size
		AGENT_BROWSER_AUDIO = $script:Audio
		AGENT_BROWSER_WINDOW = $script:Window
		AGENT_BROWSER_PROXY_PORT = [string]$I.ProxyPort
		AGENT_BROWSER_CDP_PORT = [string]$I.CdpPort
		AGENT_BROWSER_PROXY_BIND = $script:ProxyBind
		AGENT_BROWSER_CERT = $script:Cert
		AGENT_BROWSER_CHROMIUM = [string]$chromium
		AGENT_BROWSER_IDLE_S = [string]$script:IdleS
		NODE = $Node
	}
}

# The task's program and arguments: conhost --headless, so node opens no window.
function Get-TaskCommand($I, [string]$Node) {
	$sup = Join-Path $I.Agent 'host-supervisor.mjs'
	return [pscustomobject]@{
		Execute = "$env:WINDIR\System32\conhost.exe"
		Arguments = "--headless `"$Node`" `"$sup`" --env `"$($I.EnvJson)`" --log"
	}
}

function Get-TrayCommand($I) {
	$tray = Join-Path $I.Agent 'tray.ps1'
	return [pscustomobject]@{
		Execute = "$env:WINDIR\System32\conhost.exe"
		Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tray`" -App `"$($I.App)`""
	}
}

# The kit's identity: every file in byte order of its ./relative/path,
# concatenated, SHA-256, 12 hex — host-agent.sh's and `agent-browser status`'s.
function Get-KitHash([string]$Dir) {
	$root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\', '/')
	$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
			'./' + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/')
		})
	[Array]::Sort($files, [StringComparer]::Ordinal)
	$sha = [Security.Cryptography.SHA256]::Create()
	foreach ($f in $files) {
		$bytes = [IO.File]::ReadAllBytes((Join-Path $root ($f.Substring(2))))
		[void]$sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
	}
	[void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
	return (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

# The snapshot folder for this PC's architecture. ARM64 first falls back to x64
# (Windows 11 on ARM runs it emulated) when the bucket has no ARM64 build.
function Get-SnapshotFolders([string]$Arch) {
	if ($Arch -eq 'Arm64') { return @('Win_Arm64', 'Win_x64') }
	return @('Win_x64')
}

# What to paste to the agent in the container.
function Get-Brief($I, [bool]$Temp) {
	$flag = ''
	if ($I.Inst -ne 'a') { $flag = " -i $($I.Inst)" }
	$t = ''
	$t2 = ''
	if ($Temp) { $t = ', temporary'; $t2 = ' (its profile is then deleted)' }
	return @"

──── paste this to the agent (Claude, or any LLM in the container) ────
An agent browser is running on the host for you: instance $($I.Inst)$t (project $($script:Project)).
It allows these origins only: $($script:Origins)
From the container:
  agent-browser$flag status                       # host side should answer
  agent-browser$flag up <url>                     # open a page (an allowed origin)
  CDP_INSTANCE=$($I.Inst) node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot --url <url> --out .tmp/shots/$($I.Inst).png
  eval "`$(agent-browser$flag env)"                 # CDP_HOST / CDP_PORT for any other CDP client
The human stops it with Ctrl-C$t2`: from then on these exit 3 — say so and stop, do not retry.
────────────────────────────────────────────────────────────────────────

"@
}

# One instance of `list`, as the row object list --json prints.
function New-ListRow($I, [bool]$Loaded, $SupervisorPid, [string]$Word, $ChromiumPid, [bool]$Listening, $HeartbeatAge, [string]$Note) {
	return [ordered]@{
		instance = $I.Inst
		label = $I.Label
		installed = [bool]$I.Installed
		loaded = $Loaded
		supervisor = $SupervisorPid
		chromium = [ordered]@{ state = $Word; pid = $ChromiumPid }
		proxy = [ordered]@{ port = [int]$I.ProxyPort; bind = $script:ProxyBind; listening = $Listening }
		heartbeat = $HeartbeatAge
		logs = $I.LogDir
		note = $Note
	}
}

function ConvertTo-ListJson([object[]]$Rows, [object[]]$Others) {
	$firewall = $null
	if (Test-Path -LiteralPath $script:PortsFile -PathType Leaf) { $firewall = '.devcontainer/firewall/ports.txt' }
	$o = [ordered]@{ project = $script:Project; firewall = $firewall; instances = @($Rows); others = @($Others) }
	return ConvertTo-Json -InputObject $o -Depth 6 -Compress
}

# The instance's note (AGENT_BROWSER_<X>_NOTE), one line, no « | ».
function Get-Note($I) {
	return ((Get-Conf "AGENT_BROWSER_$($I.Inst.ToUpperInvariant())_NOTE") -replace '[|\r\n]', '')
}

# ── the host side ────────────────────────────────────────────────────────────

# A control file's content, or nothing when it is missing or a link.
function Read-Plain([string]$Path) {
	try {
		$item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
		if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '' }
		return ([IO.File]::ReadAllText($Path)).Trim()
	}
	catch { return '' }
}

# The epoch in the heartbeat file, 0 when there is none.
function Get-Beat($I) {
	$b = Read-Plain (Join-Path $I.Ctl 'heartbeat')
	if ($b -match '^[0-9]+$') { return [long]$b }
	return 0
}

function Get-Epoch { return [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

# Does something listen on the proxy's port ? With the listening pid when known.
function Get-Listener([int]$Port) {
	try {
		$c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
		if ($c) { return [pscustomobject]@{ Listening = $true; Pid = [int]$c.OwningProcess } }
	}
	catch {
		try {
			$t = New-Object Net.Sockets.TcpClient
			$t.Connect('127.0.0.1', $Port)
			$t.Close()
			return [pscustomobject]@{ Listening = $true; Pid = $null }
		}
		catch {}
	}
	return [pscustomobject]@{ Listening = $false; Pid = $null }
}

function Get-AbTask([string]$Name) {
	return Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $Name -ErrorAction SilentlyContinue
}

# Processes whose command line carries <text> (case-blind, as Windows paths are).
function Get-ProcessByCommandLine([string]$Text) {
	$needle = $Text.ToLowerInvariant()
	return @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($needle) })
}

# The supervisor (by its env.json), then any Chromium on the profile, as trees:
# a stopped task leaves both behind.
function Stop-AbTree($I) {
	foreach ($p in (Get-ProcessByCommandLine $I.EnvJson) + (Get-ProcessByCommandLine "--user-data-dir=$($I.Profile)")) {
		if ($p.ProcessId -ne $PID) { Invoke-Native taskkill.exe @('/T', '/F', '/PID', $p.ProcessId) | Out-Null }
	}
}

function Test-Prereqs {
	$cmd = Get-Command node -ErrorAction SilentlyContinue
	if (-not $cmd) { Stop-Agent 'node not found — install Node.js 22 or later (nodejs.org, or winget install OpenJS.NodeJS.LTS)' }
	$script:Node = $cmd.Source
	# `node -v` parsed here: Windows PowerShell 5.1 strips the double quotes inside
	# a native program's arguments, so no `-p '…"…"…'`.
	$major = 0
	if ([string](& $script:Node -v | Select-Object -First 1) -match '^v(\d+)\.') { $major = [int]$Matches[1] }
	if ($major -lt 22) { Stop-Agent "node $(& $script:Node -v) is too old: the DevTools proxy needs 22+ (its built-in WebSocket)" }
	if (-not $script:Origins) { Stop-Agent "AGENT_BROWSER_ORIGINS is not set in $($script:EnvFile) — space-separated scheme://host[:port], e.g. http://localhost:5173" }
	$env:AGENT_BROWSER_ORIGINS = $script:Origins
	$env:AGENT_BROWSER_REACH = $script:Reach
	& $script:Node (Join-Path $script:HostDir 'cdp-proxy.mjs') pac | Out-Null
	if ($LASTEXITCODE -ne 0) { Stop-Agent 'AGENT_BROWSER_ORIGINS has an entry the proxy refuses (above)' }
	if ($script:Cert -and -not (Test-Path -LiteralPath $script:Cert -PathType Leaf)) { Stop-Agent "AGENT_BROWSER_CERT points at an unreadable file: $($script:Cert)" }
}

# Chromium, the supervisor's own search (host-supervisor.mjs find-chromium).
function Find-AbChromium($I) {
	$env:AGENT_BROWSER_CHROMIUM = $script:Chromium
	$found = @(& $script:Node (Join-Path $script:HostDir 'host-supervisor.mjs') find-chromium)
	$script:ChromiumBin = $found[0]
	if (-not $script:ChromiumBin) {
		$tried = ($found | Select-Object -Skip 1 | ForEach-Object { "    $_" }) -join "`n"
		Stop-Agent "Chromium not found. Looked in:`n$tried`n  → $PSCommandPath install-chromium (a Chromium snapshot, no admin rights) ; then install $($I.Inst)"
	}
}

function Write-Heartbeat($I, [long]$T0) {
	Open-Step 5 'heartbeat'
	for ($n = 0; $n -lt 30; $n++) {
		$b = Get-Beat $I
		if ($b -ge $T0) {
			$flag = ''
			if ($I.Inst -ne 'a') { $flag = " -i $($I.Inst)" }
			Close-StepOk "$((Get-Epoch) - $b)s old — the container routes agent-browser$flag here"
			return
		}
		if ($n % 4 -eq 3) { Write-Line "  … waiting for the first heartbeat ($([int](($n + 1) / 2))s / 15s)" }
		Start-Sleep -Milliseconds 500
	}
	Stop-Agent "no heartbeat in $($I.Ctl) within 15 s — the supervisor did not start: $PSCommandPath logs $($I.Inst)"
}

function Write-FirewallStep($I) {
	Open-Step 3 'firewall'
	if (Test-Opens $I.ProxyPort) { Close-StepOk "host:$($I.ProxyPort) in .devcontainer/firewall/ports.txt" }
	else { Close-StepWarn "host:$($I.ProxyPort) is not in .devcontainer/firewall/ports.txt — add it, then Rebuild Container (the host side works, the container cannot reach it yet)" }
}

function Register-AbTask([string]$Name, $Command, [string]$WorkDir, [bool]$Restart) {
	$user = "$env:USERDOMAIN\$env:USERNAME"
	$action = New-ScheduledTaskAction -Execute $Command.Execute -Argument $Command.Arguments -WorkingDirectory $WorkDir
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
	if ($Restart) {
		# The Task Scheduler's « restart on failure » covers a launch that fails,
		# not a program that exits (measured): the logon trigger repeats every
		# minute instead, and IgnoreNew keeps it to one instance. Disabled by
		# stop, it does not fire.
		$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition
	}
	$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
	$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
	if ($Restart) {
		$settings.RestartCount = 999
		$settings.RestartInterval = 'PT1M'
	}
	Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

# The tray icon's ICOs, drawn from the SVG by the host's Chromium ; not drawn,
# tray.ps1 falls back to the system's icons.
function Install-TrayIcons($I) {
	$svg = Join-Path $script:Repo '.devcontainer\agent-browser\menubar-icon.svg'
	if (-not (Test-Path -LiteralPath $svg)) { $svg = Join-Path $script:HostDir 'menubar-icon.svg' }
	$x = $I.Inst.ToUpperInvariant()
	$letters = Get-Conf "AGENT_BROWSER_${x}_ICON_LETTERS" $script:IconLetters
	$mark = @()
	if ($I.Inst -ne 'a') { $mark = @($I.Inst) }
	New-Item -ItemType Directory -Force -Path $I.Icons | Out-Null
	$out = Invoke-Native $script:Node (@((Join-Path $script:HostDir 'menubar-icon.mjs'), $svg, $letters, $script:ChromiumBin) + $mark + @('--tray', $I.Icons))
	if ($LASTEXITCODE -eq 0) { Write-Line "  tray: icon $letters$(if ($mark) { ", $($I.Inst) in the dot" }), from $svg" }
	else { Write-Line "  tray: icon not drawn ($(($out | Select-Object -Last 1))) — the system's icons instead" }
}

function Install-Instance($I) {
	Open-Step 1 'kit'
	Test-Prereqs
	# A reinstall over a running instance: its tasks stopped and everything that
	# runs from the copy killed (the tray holds it) before the copy is replaced.
	foreach ($t in $I.Task, $I.TrayTask) {
		if (Get-AbTask $t) { Stop-ScheduledTask -TaskPath $script:TaskPath -TaskName $t -ErrorAction SilentlyContinue }
	}
	Stop-AbHolders $I
	foreach ($d in $I.LogDir, $I.Ctl, $I.Profile) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
	Remove-AbFolder $I $I.Agent
	Copy-Item -LiteralPath $script:HostDir -Destination $I.Agent -Recurse
	if ($script:Cert) {
		Copy-Item -LiteralPath $script:Cert -Destination (Join-Path $I.App 'dev.crt') -Force
		$script:Cert = Join-Path $I.App 'dev.crt'
	}
	$hash = Get-KitHash $I.Agent
	$reach = ''
	if ($script:Reach) { $reach = " ; may also reach: $($script:Reach)" }
	Close-StepOk "node $(& $script:Node -v), kit $hash copied to $($I.Agent) — allowed origins: $($script:Origins)$reach"
	Open-Step 2 'chromium'
	Find-AbChromium $I
	$own = ''
	if ($script:Chromium) { $own = ' (AGENT_BROWSER_CHROMIUM)' }
	Close-StepOk "$($script:ChromiumBin)$own"
	Write-FirewallStep $I
	Open-Step 4 'scheduler'
	$envs = Get-SupervisorEnv $I $script:Node $script:ChromiumBin
	[IO.File]::WriteAllText($I.EnvJson, (ConvertTo-Json -InputObject $envs), (New-Object Text.UTF8Encoding $false))
	$t0 = Get-Epoch
	Stop-Instance $I -Quiet
	try {
		Register-AbTask $I.Task (Get-TaskCommand $I $script:Node) $I.Agent $true
		Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.Task
	}
	catch { Stop-Agent "the Task Scheduler refused $($script:TaskPath)$($I.Task): $($_.Exception.Message)" }
	$mode = 'headless'
	if ($script:Window -eq '1') { $mode = 'windowed' }
	Close-StepOk "$($script:TaskPath)$($I.Task) registered and started — proxy $($script:ProxyBind):$($I.ProxyPort), $mode $($script:Size), audio $($script:Audio)"
	Install-TrayIcons $I
	[IO.File]::WriteAllText((Join-Path $I.App 'tray.json'), (ConvertTo-Json -InputObject ([ordered]@{
					label = $I.Label; inst = $I.Inst; task = $I.Task; taskPath = $script:TaskPath; repo = $script:Repo
					ctl = $I.Ctl; profile = $I.Profile; logs = $I.LogDir; icons = $I.Icons; note = (Get-Note $I)
				})), (New-Object Text.UTF8Encoding $false))
	try {
		Register-AbTask $I.TrayTask (Get-TrayCommand $I) $I.Agent $false
		Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.TrayTask
		Write-Line "  tray: $($script:TaskPath)$($I.TrayTask)"
	}
	catch { Write-Line "  tray: not registered ($($_.Exception.Message)) — the browser works without it" }
	Write-Heartbeat $I $t0
	$flag = ''
	if ($I.Inst -ne 'a') { $flag = " -i $($I.Inst)" }
	Write-Line "  idle until the container asks: agent-browser$flag up — a new image: extract the kit again, re-run install"
}

function Start-Instance($I) {
	if (-not $I.Installed) {
		Write-Line "  $($I.Label) is not installed — installing it"
		Install-Instance $I
		return
	}
	Open-Step 1 'kit'
	if (-not (Test-Path -LiteralPath $I.Agent)) { Stop-Agent "the installed copy $($I.Agent) is missing — install $($I.Inst)" }
	$here = Get-KitHash $script:HostDir
	$there = Get-KitHash $I.Agent
	if ($here -eq $there) { Close-StepOk "installed copy $($I.Agent), kit $there" }
	else { Close-StepWarn "the installed copy (kit $there) differs from this kit ($here) — review, then install $($I.Inst)" }
	Open-Step 2 'chromium'
	$chromium = (Get-Content -LiteralPath $I.EnvJson -Raw | ConvertFrom-Json).AGENT_BROWSER_CHROMIUM
	if (-not $chromium) { Close-StepWarn 'env.json names no Chromium — the supervisor searches for one' }
	elseif (Test-Path -LiteralPath $chromium -PathType Leaf) { Close-StepOk $chromium }
	else { Stop-Agent "the installed Chromium is not there any more: $chromium — install-chromium, or install $($I.Inst)" }
	Write-FirewallStep $I
	Open-Step 4 'scheduler'
	$t0 = Get-Epoch
	$task = Get-AbTask $I.Task
	if (-not $task) { Stop-Agent "$($script:TaskPath)$($I.Task) is not registered — install $($I.Inst)" }
	if ($task.State -eq 'Running') {
		Close-StepOk "$($script:TaskPath)$($I.Task) already running"
		$t0 -= 5
	}
	else {
		Enable-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.Task | Out-Null
		Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.Task
		if (Get-AbTask $I.TrayTask) {
			Enable-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.TrayTask | Out-Null
			Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.TrayTask
		}
		Close-StepOk "$($script:TaskPath)$($I.Task) started"
	}
	Write-Heartbeat $I $t0
}

# Off without uninstalling: the task stopped and disabled (off across logons),
# then what it leaves behind killed. The tray stays, showing « stopped ».
function Stop-Instance($I, [switch]$Quiet) {
	$task = Get-AbTask $I.Task
	if (-not $Quiet -and -not $task) { Stop-Agent "instance $($I.Inst) is not installed ($($script:TaskPath)$($I.Task)) — nothing to stop" }
	if ($task) {
		Stop-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.Task -ErrorAction SilentlyContinue
		if (-not $Quiet) { Disable-ScheduledTask -TaskPath $script:TaskPath -TaskName $I.Task | Out-Null }
	}
	Stop-AbTree $I
	foreach ($f in 'heartbeat', 'port') {
		$p = Join-Path $I.Ctl $f
		if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $p -Force }
	}
	if (-not $Quiet) { Write-Line "✓ $($I.Label) stopped — Chromium and its proxy off ; the task and the tray icon stay. start $($I.Inst) brings it back" }
}

# Everything that names the instance folder: the supervisor and its conhost,
# Chromium (its profile), the tray — each also holds the folder as its working
# directory, and Windows refuses to delete or replace a folder in use.
function Stop-AbHolders($I) {
	foreach ($p in Get-ProcessByCommandLine $I.App) {
		if ($p.ProcessId -ne $PID) { Invoke-Native taskkill.exe @('/T', '/F', '/PID', $p.ProcessId) | Out-Null }
	}
}

# A killed process lets go of its handles a moment later: a few tries, then
# the holders named.
function Remove-AbFolder($I, [string]$Path) {
	for ($n = 1; Test-Path -LiteralPath $Path; $n++) {
		try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
		catch {
			if ($n -ge 10) {
				$holders = (@(Get-ProcessByCommandLine $I.App) | ForEach-Object { "$($_.Name) $($_.ProcessId)" }) -join ', '
				if (-not $holders) { $holders = 'a process that does not name it (an Explorer window or a shell opened in it?)' }
				Stop-Agent "could not remove ${Path}: $($_.Exception.Message) — held by $holders. Close it, then run this again"
			}
			Start-Sleep -Milliseconds 500
		}
	}
}

function Uninstall-Instance($I) {
	foreach ($t in $I.Task, $I.TrayTask) {
		if (Get-AbTask $t) {
			Stop-ScheduledTask -TaskPath $script:TaskPath -TaskName $t -ErrorAction SilentlyContinue
			Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $t -Confirm:$false
		}
	}
	Stop-AbHolders $I
	foreach ($f in 'heartbeat', 'port') { Remove-Item -LiteralPath (Join-Path $I.Ctl $f) -Force -ErrorAction SilentlyContinue }
	Remove-AbFolder $I $I.App
	Write-Line "✓ $($I.Label) unregistered, $($I.App) removed — the container's sidecar takes over (if the project has one)"
}

function Show-Status($I) {
	if ($I.Installed) {
		$chromium = (Get-Content -LiteralPath $I.EnvJson -Raw | ConvertFrom-Json).AGENT_BROWSER_CHROMIUM
		if (-not $chromium) { $chromium = 'none named in env.json — the supervisor searches' }
		Write-Line "  chromium: $chromium"
	}
	$task = Get-AbTask $I.Task
	if ($task) {
		$info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $I.Task
		Write-Line "  task state = $($task.State)"
		Write-Line "  task last result = 0x$('{0:x}' -f $info.LastTaskResult) at $($info.LastRunTime)"
	}
	else { Write-Line "  task: $($script:TaskPath)$($I.Task) not registered — install $($I.Inst)" }
	$l = Get-Listener $I.ProxyPort
	Write-Line "  proxy listening: $(if ($l.Listening) { 'yes' } else { 'no' }) ($($script:ProxyBind):$($I.ProxyPort))"
	$age = (Get-Epoch) - (Get-Beat $I)
	if ($age -le 5) { Write-Line "  heartbeat: ${age}s — the container sends its agent-browser commands here" }
	else { Write-Line '  heartbeat: none — the container falls back to its sidecar, if any' }
	$state = Read-Plain (Join-Path $I.Ctl 'state')
	if ($state) { $state = ($state -split ' ', 2)[1] } else { $state = 'no state yet' }
	Write-Line "  supervisor: $state"
	$here = Get-KitHash $script:HostDir
	if (Test-Path -LiteralPath $I.Agent) {
		$there = Get-KitHash $I.Agent
		Write-Line "  kit: $here here, $there installed"
		if ($here -ne $there) { Write-Line '  the installed copy differs from this kit — review, then: install' }
	}
	else { Write-Line "  kit: $here here" }
	if ($I.Installed -and $script:Origins) {
		$baked = (Get-Content -LiteralPath $I.EnvJson -Raw | ConvertFrom-Json).AGENT_BROWSER_ORIGINS
		if ($baked -ne $script:Origins) { Write-Line "  AGENT_BROWSER_ORIGINS changed in .env ($($script:Origins)) — the agent still allows: $baked — re-run install" }
	}
}

# The three logs, followed: new lines of each, prefixed with its name.
function Watch-Logs($I) {
	New-Item -ItemType Directory -Force -Path $I.LogDir | Out-Null
	$files = 'supervisor.log', 'cdp-proxy.log', 'chromium.log'
	$pos = @{}
	foreach ($f in $files) {
		$p = Join-Path $I.LogDir $f
		if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType File -Path $p | Out-Null }
		$lines = @(Get-Content -LiteralPath $p -Tail 20)
		foreach ($line in $lines) { Write-Line "[$f] $line" }
		$pos[$f] = (Get-Item -LiteralPath $p).Length
	}
	Write-Line "  following $($I.LogDir) — Ctrl-C stops"
	while ($true) {
		foreach ($f in $files) {
			$p = Join-Path $I.LogDir $f
			$len = (Get-Item -LiteralPath $p).Length
			if ($len -lt $pos[$f]) { $pos[$f] = 0 }
			if ($len -gt $pos[$f]) {
				$s = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
				try {
					[void]$s.Seek($pos[$f], 'Begin')
					$text = (New-Object IO.StreamReader $s).ReadToEnd()
				}
				finally { $s.Close() }
				foreach ($line in ($text -split "`r?`n")) { if ($line) { Write-Line "[$f] $line" } }
				$pos[$f] = $len
			}
		}
		Start-Sleep -Milliseconds 500
	}
}

function Invoke-Run($I, [bool]$Temp, $PortOpt, $CdpOpt) {
	Set-InstancePorts $I $PortOpt $CdpOpt
	Test-Prereqs
	Find-AbChromium $I
	if ($Temp -and $I.Installed) { Stop-Agent "instance $($I.Inst) is installed — --temp would delete its profile. Pick a letter that is not: list" }
	$task = Get-AbTask $I.Task
	if ($task -and $task.State -eq 'Running') { Stop-Agent "$($script:TaskPath)$($I.Task) is running — two supervisors on one channel. stop $($I.Inst) first, or use logs." }
	foreach ($d in $I.LogDir, $I.Ctl, $I.Profile) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
	$envs = Get-SupervisorEnv $I $script:Node $script:ChromiumBin
	foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $envs[$k], 'Process') }
	$t = ''
	if ($Temp) { $t = ', and removes its profile and logs' }
	Write-Line "→ supervisor in the foreground, polling $($I.Ctl) — Ctrl-C stops it (and the browser)$t"
	Write-Line "  origins: $($script:Origins) ; proxy $($script:ProxyBind):$($I.ProxyPort) ; logs in $($I.LogDir)"
	if (-not (Test-Opens $I.ProxyPort)) { Write-Line "  ⚠ host:$($I.ProxyPort) is not in .devcontainer/firewall/ports.txt — the container cannot reach it until it is (then Rebuild Container) ; or --port <a port it opens, not in use>" }
	Write-Line (Get-Brief $I $Temp)
	# node shares this console, so Ctrl-C reaches it (SIGINT) and it stops
	# Chromium itself ; the finally waits for that before deleting anything.
	$p = Start-Process -FilePath $script:Node -ArgumentList "`"$(Join-Path $script:HostDir 'host-supervisor.mjs')`"" -NoNewWindow -PassThru
	try {
		while (-not $p.HasExited) { Start-Sleep -Milliseconds 200 }
	}
	finally {
		if (-not $p.WaitForExit(15000)) { Invoke-Native taskkill.exe @('/T', '/F', '/PID', $p.Id) | Out-Null }
		if ($Temp) {
			Stop-AbTree $I
			Remove-Item -LiteralPath $I.App -Recurse -Force -ErrorAction SilentlyContinue
			Write-Line "✓ temporary instance $($I.Inst) gone — profile and logs removed"
		}
	}
}

# --port / --cdp-port, else the .env's, derived per letter. Says so when an
# installed instance moves.
function Set-InstancePorts($I, $PortOpt, $CdpOpt) {
	$was = $I.ProxyPort
	if ($PortOpt) { $I.ProxyPort = [int]$PortOpt } else { $I.ProxyPort = $I.DerivedProxyPort }
	if ($CdpOpt) { $I.CdpPort = [int]$CdpOpt } else { $I.CdpPort = $I.DerivedCdpPort }
	if ($I.Installed -and $was -ne $I.ProxyPort) {
		$keep = ''
		if (-not $PortOpt) { $keep = " — install $($I.Inst) --port $was keeps the old one" }
		Write-Line "  proxy port $($I.ProxyPort), was $was$keep"
	}
}

function Show-Instances {
	if (Test-Path -LiteralPath $script:PortsFile) { Write-Line "firewall: $($script:PortsFile)" } else { Write-Line "firewall: no $($script:PortsFile) — instance a only" }
	foreach ($l in Get-Discovered) {
		$i = Get-AbInstance $l
		$rel = $i.Ctl.Substring($script:Repo.Length + 1)
		$mark = ''
		if ($i.Installed) { $mark = '  installed' }
		Write-Line "  $l  $($i.Label)  proxy $($script:ProxyBind):$($i.ProxyPort)  devtools 127.0.0.1:$($i.CdpPort)  channel $rel$mark"
	}
}

function Show-List([bool]$Json) {
	$mine = @($script:Letters | Where-Object {
			$i = Get-AbInstance $_
			$i.Installed -or (Test-Opens $i.ProxyPort) -or $_ -eq 'a'
		})
	$rows = @()
	$ports = @{}
	if (-not $Json) {
		$fw = 'no .devcontainer/firewall/ports.txt'
		if (Test-Path -LiteralPath $script:PortsFile) { $fw = '.devcontainer/firewall/ports.txt' }
		Write-Line "$($script:Project) — firewall: $fw"
	}
	foreach ($l in $mine) {
		$i = Get-AbInstance $l
		$ports[[string]$i.ProxyPort] = $l
		$task = Get-AbTask $i.Task
		$loaded = [bool]($task -and $task.State -eq 'Running')
		$spid = $null
		if ($loaded) {
			$sup = @(Get-ProcessByCommandLine $i.EnvJson | Where-Object { $_.Name -eq 'node.exe' }) | Select-Object -First 1
			if ($sup) { $spid = [int]$sup.ProcessId }
		}
		$word = 'stopped'
		$cpid = $null
		$state = Read-Plain (Join-Path $i.Ctl 'state')
		if ($loaded -and $state) {
			$f = $state -split ' '
			$word = $f[1]
			if ($f.Count -gt 2 -and $f[2] -match '^[0-9]+$') { $cpid = [int]$f[2] }
		}
		$b = Get-Beat $i
		$age = $null
		if ($b -gt 0) { $age = [int]((Get-Epoch) - $b) }
		$listening = (Get-Listener $i.ProxyPort).Listening
		$note = Get-Note $i
		if ($Json) {
			$rows += , (New-ListRow $i $loaded $spid $word $cpid $listening $age $note)
			continue
		}
		$setup = 'not installed'
		$load = '-'
		if ($i.Installed -and $loaded) { $setup = 'installed'; $load = 'loaded' }
		elseif ($i.Installed) { $setup = 'installed'; $load = 'stopped' }
		$ageText = 'none'
		if ($null -ne $age) { $ageText = "${age}s" }
		$listenText = 'closed'
		if ($listening) { $listenText = 'listening' }
		Write-Line ("  {0}  {1}  {2}, {3}  supervisor {4}  chromium {5} {6}  proxy {7} {8}  heartbeat {9}  logs {10}" -f $l, $i.Label, $setup, $load, $(if ($spid) { $spid } else { '-' }), $word, $(if ($cpid) { $cpid } else { '-' }), $i.ProxyPort, $listenText, $ageText, $i.LogDir)
		if ($note) { Write-Line "     $note" }
	}
	$others = @()
	if (-not $Json) { Write-Line 'other projects:' }
	$tasks = @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue | Where-Object {
			$_.TaskName -notlike 'tray.*' -and $_.TaskName -ne $script:Project -and $_.TaskName -notmatch "^$([regex]::Escape($script:Project))\.[a-z]$"
		})
	foreach ($t in $tasks) {
		$port = $null
		$args0 = [string]$t.Actions[0].Arguments
		if ($args0 -match '--env "([^"]+)"' -and (Test-Path -LiteralPath $Matches[1])) {
			$p = (Get-Content -LiteralPath $Matches[1] -Raw | ConvertFrom-Json).AGENT_BROWSER_PROXY_PORT
			if ($p -match '^[0-9]+$') { $port = [int]$p }
		}
		$clash = $null
		if ($null -ne $port -and $ports.ContainsKey([string]$port)) { $clash = $ports[[string]$port] }
		$job = "io.meitogi.agent-browser.$($t.TaskName)"
		if ($Json) { $others += , [ordered]@{ job = $job; port = $port; clash = $clash } }
		else {
			$c = ''
			if ($clash) { $c = "  ← the same port as instance $clash here" }
			$pt = '?'
			if ($null -ne $port) { $pt = $port }
			Write-Line "  $job  proxy $pt$c"
		}
	}
	if ($Json) { Write-Line (ConvertTo-ListJson $rows $others) }
	elseif ($tasks.Count -eq 0) { Write-Line '  none registered' }
}

# A Chromium snapshot for this PC, out of the project: the AGENT_BROWSER_CHROMIUM
# line is printed, never written.
function Install-Chromium {
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	$ProgressPreference = 'SilentlyContinue'
	$arch = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
	$base = 'https://commondatastorage.googleapis.com/chromium-browser-snapshots'
	$root = Join-Path $env:LOCALAPPDATA 'agent-browser\chromium'
	$rev = ''
	$folder = ''
	foreach ($f in Get-SnapshotFolders $arch) {
		try {
			$rev = ([string](Invoke-WebRequest -UseBasicParsing -Uri "$base/$f/LAST_CHANGE").Content).Trim()
			$folder = $f
			break
		}
		catch { Write-Line "  no $f snapshot ($($_.Exception.Message)) — trying the next" }
	}
	if ($rev -notmatch '^[0-9]+$') { Stop-Agent "no snapshot revision from $base (network?) — retry, or install Chrome / use Edge" }
	if ($folder -ne 'Win_Arm64' -and $arch -eq 'Arm64') { Write-Line '  an x64 build on an ARM64 PC: Windows runs it emulated (slower)' }
	New-Item -ItemType Directory -Force -Path $root | Out-Null
	$tmp = Join-Path $root ".download.$PID"
	New-Item -ItemType Directory -Force -Path $tmp | Out-Null
	Write-Line "→ Chromium snapshot $rev ($folder) into $root"
	try {
		Invoke-WebRequest -UseBasicParsing -Uri "$base/$folder/$rev/chrome-win.zip" -OutFile (Join-Path $tmp 'chrome-win.zip')
		Expand-Archive -LiteralPath (Join-Path $tmp 'chrome-win.zip') -DestinationPath $tmp -Force
	}
	catch {
		Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
		Stop-Agent "download or unzip of $base/$folder/$rev/chrome-win.zip failed: $($_.Exception.Message) — retry, or install Chrome / use Edge"
	}
	$exe = Join-Path $tmp 'chrome-win\chrome.exe'
	if (-not (Test-Path -LiteralPath $exe)) {
		Remove-Item -LiteralPath $tmp -Recurse -Force
		Stop-Agent 'the zip holds no chrome-win\chrome.exe — install Chrome, or use Edge'
	}
	$dest = Join-Path $root 'chrome-win'
	if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
	Move-Item -LiteralPath (Join-Path $tmp 'chrome-win') -Destination $dest
	Remove-Item -LiteralPath $tmp -Recurse -Force
	Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File
	[IO.File]::WriteAllText((Join-Path $root 'REVISION'), "$rev $folder`n")
	Write-Line "✓ Chromium $rev ($folder) — $dest"
	Write-Line '  the supervisor looks there first ; to pin it anyway, add this line to .devcontainer/.env, then: install'
	Write-Line "  AGENT_BROWSER_CHROMIUM=`"$(Join-Path $dest 'chrome.exe')`""
}

function Get-InstalledLetters {
	return @($script:Letters | Where-Object { (Get-AbInstance $_).Installed })
}

function Invoke-Main([string[]]$Argv) {
	$verb = 'status'
	if ($Argv.Count -gt 0) { $verb = $Argv[0] }
	$rest = @($Argv | Select-Object -Skip 1)
	$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
	# The steps print ✓ ✗ → … : UTF-8, whatever the console's code page.
	try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
	if (-not $onWindows -and $verb -ne 'instances' -and -not $env:AGENT_BROWSER_HOST_TEST) {
		Stop-Agent 'host-agent.ps1 is the Windows host agent — on a Mac use host-agent.sh ; in a container only `instances` runs.'
	}
	$repo = (Get-Location).ProviderPath
	if (-not (Test-Path -LiteralPath (Join-Path $repo '.devcontainer\docker-compose.yml'))) { Stop-Agent "run this from the project root (no .devcontainer\docker-compose.yml here: $repo)." }
	Read-Project $repo
	$portOpt = $null
	$cdpOpt = $null
	$temp = $false
	$json = $false
	$letters = @()
	for ($k = 0; $k -lt $rest.Count; $k++) {
		$a = $rest[$k]
		switch -exact ($a) {
			'--temp' {
				if ($verb -ne 'run') { Stop-Agent '--temp goes with run: run c --temp' }
				$temp = $true
			}
			'--json' {
				if ($verb -ne 'list') { Stop-Agent '--json goes with list' }
				$json = $true
			}
			{ $_ -eq '--port' -or $_ -eq '--cdp-port' } {
				$v = ''
				if ($k + 1 -lt $rest.Count) { $v = $rest[$k + 1] }
				if ($v -notmatch '^[1-9][0-9]{3,4}$' -or [int]$v -gt 65535) { Stop-Agent "$a ${v}: a port, 1000 to 65535" }
				if ($verb -ne 'install' -and $verb -ne 'run') { Stop-Agent "$a goes with install or run (another verb reads the port install wrote)" }
				if ($a -eq '--port') { $portOpt = $v } else { $cdpOpt = $v }
				$k++
			}
			default { $letters += $a }
		}
	}
	if (($portOpt -or $cdpOpt) -and ($letters.Count -gt 1 -or $letters -contains '--all')) {
		Stop-Agent '--port / --cdp-port set the ports of ONE instance — e.g. install b --port 55440'
	}
	switch -exact ($verb) {
		'install' {
			$list = $letters
			if ($letters -contains '--all') { $list = Get-Discovered }
			elseif ($list.Count -eq 0) { $list = @('a') }
			foreach ($l in $list) {
				$i = Get-AbInstance $l
				Write-Line "== instance $l ($($i.Label))"
				Set-InstancePorts $i $portOpt $cdpOpt
				Install-Instance $i
			}
		}
		'start' {
			$list = $letters
			if ($list.Count -eq 0) { $list = @('a') }
			foreach ($l in $list) { $i = Get-AbInstance $l; Write-Line "== instance $l ($($i.Label))"; Start-Instance $i }
		}
		'stop' {
			$list = $letters
			if ($list.Count -eq 0) { $list = Get-InstalledLetters }
			if ($list.Count -eq 0) { Stop-Agent "nothing of $($script:Project) is installed — install" }
			foreach ($l in $list) { Stop-Instance (Get-AbInstance $l) }
		}
		'uninstall' {
			$list = $letters
			if ($list.Count -eq 0) { $list = Get-InstalledLetters }
			if ($list.Count -eq 0) { $list = @('a') }
			foreach ($l in $list) { Uninstall-Instance (Get-AbInstance $l) }
		}
		'status' {
			$list = $letters
			if ($list.Count -eq 0) { $list = Get-InstalledLetters }
			if ($list.Count -eq 0) { $list = @('a') }
			foreach ($l in $list) { $i = Get-AbInstance $l; Write-Line "== instance $l ($($i.Label))"; Show-Status $i }
		}
		'list' { Show-List $json }
		'logs' {
			$l = 'a'
			if ($letters.Count -gt 0) { $l = $letters[0] }
			Watch-Logs (Get-AbInstance $l)
		}
		'run' {
			if ($temp -and $letters.Count -ne 1) { Stop-Agent '--temp names its instance: run c --temp' }
			$l = 'a'
			if ($letters.Count -gt 0) { $l = $letters[0] }
			Invoke-Run (Get-AbInstance $l) $temp $portOpt $cdpOpt
		}
		'instances' { Show-Instances }
		'install-chromium' { Install-Chromium }
		default { Stop-Agent 'usage: host-agent.ps1 {install|start|stop|uninstall|status} [instance…] | install --all | install <i> --port <n> [--cdp-port <n>] | {logs|run} [instance] | run <i> --temp | list [--json] | instances | install-chromium' }
	}
}

# Dot-sourced (the Pester suite), the functions only.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Main $args }
