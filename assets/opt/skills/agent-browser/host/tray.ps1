# tray.ps1 — the agent browser in the Windows notification area, one icon per
# instance, refreshed every 5 s: the SwiftBar plugin's counterpart.
# `host-agent.ps1 install` registers it as a second task at logon
# (\meitogi\agent-browser\tray.<project>[.x]) and writes what it reads into
# <app>\tray.json ; like the supervisor, it runs from the installed copy.
#
#   running    Chromium up for the container
#   idle       the supervisor waits, Chromium off
#   stray      a Chromium on the agent profile the supervisor did not start
#   unloaded   the task is not running
#
# The icons are <app>\icons\<state>-<light|dark>.ico, drawn at install by
# menubar-icon.mjs --tray, picked by the taskbar's theme (SystemUsesLightTheme) ;
# missing, the system's own icons stand in.
#
#   powershell -WindowStyle Hidden -File tray.ps1 -App <%LOCALAPPDATA%\agent-browser\<project>[.x]>
#
# Windows PowerShell 5.1.
param([Parameter(Mandatory = $true)][string]$App)
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$cfg = Get-Content -LiteralPath (Join-Path $App 'tray.json') -Raw | ConvertFrom-Json
# One icon per instance, whoever starts a second one.
$mutex = New-Object Threading.Mutex($false, "Local\meitogi-agent-browser-tray-$($cfg.label)")
if (-not $mutex.WaitOne(0)) { exit 0 }
$agentPs1 = Join-Path $PSScriptRoot 'host-agent.ps1'
# Nothing reads a hidden tray's errors: they go to <logs>\tray.log, with each
# change of state and why.
function Write-TrayLog([string]$Text) {
	try { [IO.File]::AppendAllText((Join-Path $cfg.logs 'tray.log'), "$(Get-Date -Format s) [tray] $Text`r`n") } catch { $null = $_ }
}
# A menu action: its error logged, never thrown at WinForms.
function Invoke-Safely([string]$What, [scriptblock]$Action) {
	try { & $Action }
	catch { Write-TrayLog "$What failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
}
$name = $cfg.label -replace '^io\.meitogi\.agent-browser\.', ''

function Get-Theme {
	try {
		$v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' -ErrorAction Stop
		if ($v -eq 1) { return 'light' }
	}
	catch {}
	return 'dark'
}

# A plain file's text, never through a link the container left in the channel.
function Read-Plain([string]$Path) {
	try {
		$item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
		if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return '' }
		return ([IO.File]::ReadAllText($Path)).Trim()
	}
	catch { return '' }
}

# The Chromium on the agent profile, whoever started it.
function Get-ProfileHolder {
	$needle = "--user-data-dir=$($cfg.profile)".ToLowerInvariant()
	$p = Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe' OR Name='chromium.exe'" |
		Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($needle) -and $_.CommandLine -notmatch '--type=' } |
		Select-Object -First 1
	if ($p) { return [int]$p.ProcessId }
	return $null
}

$script:icons = @{}
function Get-StateIcon([string]$State) {
	$key = "$State-$(Get-Theme)"
	if (-not $script:icons.ContainsKey($key)) {
		$file = Join-Path $cfg.icons "$key.ico"
		if (Test-Path -LiteralPath $file) { $script:icons[$key] = New-Object Drawing.Icon($file, 16, 16) }
		else {
			# Not drawn: a neutral icon, the warning for a stray Chromium only — the
			# tooltip and the menu say the state.
			Write-TrayLog "no icon $file — the system's"
			$script:icons[$key] = [Drawing.SystemIcons]::Application
			if ($State -eq 'stray') { $script:icons[$key] = [Drawing.SystemIcons]::Warning }
		}
	}
	return $script:icons[$key]
}

function Invoke-HostAgent([string]$Verb) {
	Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -WorkingDirectory $cfg.repo -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$agentPs1`"", $Verb, $cfg.inst)
}

$tray = New-Object Windows.Forms.NotifyIcon
$menu = New-Object Windows.Forms.ContextMenuStrip
$head = $menu.Items.Add($name)
$head.Enabled = $false
if ($cfg.note) {
	$noteItem = $menu.Items.Add($cfg.note)
	$noteItem.Enabled = $false
}
$stateItem = $menu.Items.Add('…')
$stateItem.Enabled = $false
[void]$menu.Items.Add('-')
$offItem = $menu.Items.Add('Turn Chromium off')
$offItem.add_Click({
		Invoke-Safely 'Turn Chromium off' {
			# The container's own verb, written like it: temp file renamed into place.
			$tmp = Join-Path $cfg.ctl ".tray.$PID"
			[IO.File]::WriteAllText($tmp, "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())000000000 down`n")
			Move-Item -LiteralPath $tmp -Destination (Join-Path $cfg.ctl 'cmd') -Force
			Write-TrayLog 'Turn Chromium off: down written'
		}
	})
$killItem = $menu.Items.Add('Kill the stray Chromium')
$killItem.add_Click({
		Invoke-Safely 'Kill the stray Chromium' {
			$p = Get-ProfileHolder
			if ($p) { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $p -WindowStyle Hidden -Wait }
			Write-TrayLog "Kill the stray Chromium: $p"
		}
	})
$stopItem = $menu.Items.Add('Stop the agent browser')
$stopItem.add_Click({ Invoke-Safely 'Stop the agent browser' { Invoke-HostAgent 'stop' ; Write-TrayLog 'stop launched' } })
$startItem = $menu.Items.Add('Start the agent browser')
$startItem.add_Click({ Invoke-Safely 'Start the agent browser' { Invoke-HostAgent 'start' ; Write-TrayLog 'start launched' } })
[void]$menu.Items.Add('-')
$logsItem = $menu.Items.Add('Open the logs folder')
$logsItem.add_Click({ Invoke-Safely 'Open the logs folder' { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($cfg.logs)`"" } })
$tray.ContextMenuStrip = $menu

function Update-Tray {
	$task = Get-ScheduledTask -TaskPath $cfg.taskPath -TaskName $cfg.task -ErrorAction SilentlyContinue
	$loaded = [bool]($task -and $task.State -eq 'Running')
	$f = (Read-Plain (Join-Path $cfg.ctl 'state')) -split ' '
	$word = 'none'
	$spid = ''
	$url = ''
	if ($f.Count -ge 2) { $word = $f[1] }
	if ($f.Count -ge 3) { $spid = $f[2] }
	if ($f.Count -ge 4) { $url = $f[3] }
	$holder = Get-ProfileHolder
	$state = 'idle'
	$text = 'idle — Chromium off until the container asks'
	if ($holder -and ($word -ne 'running' -or -not $loaded -or [string]$holder -ne $spid)) {
		$state = 'stray'
		$text = "a Chromium ($holder) on the agent profile the supervisor did not start"
	}
	elseif (-not $loaded) {
		$state = 'unloaded'
		$text = 'stopped — the task is not running'
	}
	elseif ($word -eq 'running') {
		$state = 'running'
		$text = "Chromium $spid on $url"
	}
	$why = "task $(if ($loaded) { 'running' } else { 'not running' }), state '$word' pid '$spid', profile held by '$holder'"
	if ($state -ne $script:lastState -or $why -ne $script:lastWhy) { Write-TrayLog "$state — $why" }
	$script:lastState = $state
	$script:lastWhy = $why
	$tray.Icon = Get-StateIcon $state
	$tip = "agent browser $($name): $state"
	if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
	$tray.Text = $tip
	$stateItem.Text = $text
	$offItem.Visible = $state -eq 'running'
	$killItem.Visible = $state -eq 'stray'
	$stopItem.Visible = $loaded
	$startItem.Visible = -not $loaded
}

$script:lastState = ''
$script:lastWhy = ''
Write-TrayLog "started for $($cfg.label), channel $($cfg.ctl)"
Invoke-Safely 'the first refresh' { Update-Tray }
$tray.Visible = $true
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Invoke-Safely 'a refresh' { Update-Tray } })
$timer.Start()
try { [Windows.Forms.Application]::Run() }
finally {
	$tray.Visible = $false
	$tray.Dispose()
	$mutex.ReleaseMutex()
}
