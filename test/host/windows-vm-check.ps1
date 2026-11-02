# windows-vm-check.ps1 — the Windows host agent on a real Windows: the Task
# Scheduler, the node supervisor, the proxy in front of Edge and of a Chromium
# snapshot, a real capture through it, the tray icon, run --temp and Ctrl-C.
# Docker is not needed: the container is played by play-container.mjs.
#
# HOW TO RUN IT — in the Windows VM, in a normal (NOT elevated) PowerShell
# window, with the sandbox repository shared from the Mac (UTM shared folder,
# drive Z: once the guest tools are installed):
#
#   powershell -ExecutionPolicy Bypass -File Z:\test\host\windows-vm-check.ps1
#
# What it does, in order (5 to 10 minutes, mostly downloads):
#   0. checks: Windows, PowerShell 5.1, not elevated, node 22+ — installs the
#      current Node LTS for this user only when missing (a zip, no admin) ;
#      copies what it needs from Z: to %LOCALAPPDATA%\ab-vm-check
#   1. parses host-agent.ps1 / tray.ps1 with Windows PowerShell 5.1 ; runs
#      PSScriptAnalyzer (installed for this user if missing)
#   2. Pester 6.2.0 (installed for this user if missing) on test\host-agent.Tests.ps1:
#      the pure part, then the real Task Scheduler part (instance y of a
#      fixture project « abcheck »)
#   3. which Chromium the supervisor finds (Edge expected) ; install-chromium
#      (a real download, ARM64 snapshot or the x64 fallback)
#   4. install z on Edge: a test page, the container played, then a real
#      capture with visual-loop's cdp.mjs through the proxy. Two questions
#      to you: did a console window flash, did a firewall dialog appear
#   5. the tray icon: two questions to you (you may save a screenshot)
#   6. the supervisor killed by hand: does the Task Scheduler restart it ?
#   7. the same drive and capture on the Chromium snapshot
#   8. run c --temp in a NEW window: you press Ctrl-C there when asked
#   9. uninstall z, the fixture removed
#
# Every wait prints where it is and gives up with a reason. The log goes to
# Z:\test\results\windows-vm-check.log (with the user name, the machine name and
# the profile folder replaced) and the captures beside it: that is what the Mac
# reads back. Nothing is installed system-wide ; what this script installed for
# the user (node, Pester, PSScriptAnalyzer, the Chromium snapshot) stays, and
# the summary lists it.
#
# Windows PowerShell 5.1.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}

$Share = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$Results = Join-Path $Share 'test\results'
$Work = Join-Path $env:LOCALAPPDATA 'ab-vm-check'
$Repo = Join-Path $Work 'repo'
$Kit = Join-Path $Repo 'assets\opt\skills\agent-browser\host'
$Fixture = Join-Path $Work 'abcheck'
$LocalLog = Join-Path $Work 'windows-vm-check.log'
$script:LastSync = [DateTime]::MinValue
$PagePort = 19580
$script:Pass = 0
$script:Fail = 0
$script:Notes = @()
$script:Installed = @()

# ── output: the console, and the log anonymized ──────────────────────────────

# Windows PowerShell 5.1 turns what a native program writes to stderr into an
# error record once it is captured (2>&1) — fatal under 'Stop'. Native calls
# whose output is captured go through here: 'Continue' in this scope only,
# the output as text lines, $LASTEXITCODE as the program left it.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
	$ErrorActionPreference = 'Continue'
	& $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
}

# A break in this script itself still ends with the summary and the log on the share.
trap {
	Ko "the check itself stopped: $($_.Exception.Message) (windows-vm-check.ps1 line $($_.InvocationInfo.ScriptLineNumber))"
	Finish
}

function Hide-Names([string]$Text) {
	$t = $Text
	if ($env:USERPROFILE) { $t = $t.Replace($env:USERPROFILE, '~') }
	foreach ($n in $env:USERNAME, $env:COMPUTERNAME, $env:USERDOMAIN) {
		if ($n -and $n.Length -ge 3) { $t = [regex]::Replace($t, "\b$([regex]::Escape($n))\b", '<name>', 'IgnoreCase') }
	}
	return $t
}
# The log reaches the share as a whole-file copy every 2 s at most (and before
# each question), so the Mac follows the run live: UTM's WebDAV share keeps
# line-by-line appends in the Windows client's cache, a copy goes through.
function Say([string]$Text) {
	Write-Host $Text
	[IO.File]::AppendAllText($LocalLog, (Hide-Names $Text) + "`r`n")
	if (((Get-Date) - $script:LastSync).TotalSeconds -ge 2) { Save-Log }
}
function Ok([string]$Text) { $script:Pass++; Say "  ✔ $Text" }
function Ko([string]$Text) { $script:Fail++; Say "  ✘ $Text" }
function Section([string]$Text) { Say ''; Say "== $Text" }
function Save-Log {
	$script:LastSync = Get-Date
	try {
		New-Item -ItemType Directory -Force -Path $Results | Out-Null
		Copy-Item -LiteralPath $LocalLog -Destination (Join-Path $Results 'windows-vm-check.log') -Force
	}
	catch { Write-Host "  (could not copy the log to $Results : $($_.Exception.Message) — it is in $LocalLog)" }
}
# Wait-Until <seconds> <what> { test } : true when the test passes in time, a
# line every 2 s saying what it waits for.
function Wait-Until([int]$Seconds, [string]$What, [scriptblock]$Test) {
	$t0 = Get-Date
	$last = 0
	while ($true) {
		try { if (& $Test) { return $true } } catch {}
		$el = [int]((Get-Date) - $t0).TotalSeconds
		if ($el -ge $Seconds) { Say "  … gave up waiting for $What after ${Seconds}s"; return $false }
		if ($el - $last -ge 2) { $last = $el; Say "  … waiting for $What (${el}s / ${Seconds}s)" }
		Start-Sleep -Milliseconds 500
	}
}
# A yes/no question to the human, recorded.
function Ask([string]$Question) {
	Say "  ? (waiting for your answer) $Question"
	Save-Log
	while ($true) {
		$a = (Read-Host "  ? $Question [y/n]").Trim().ToLowerInvariant()
		if ($a -eq 'y' -or $a -eq 'n') { Say "  ? $Question → $a"; return $a -eq 'y' }
	}
}
function Finish {
	Section 'summary'
	foreach ($n in $script:Notes) { Say "  · $n" }
	if ($script:Installed.Count) { Say "  installed for this user by this check (kept): $($script:Installed -join ', ')" }
	$verdict = 'PASS'
	if ($script:Fail -gt 0) { $verdict = 'FAIL' }
	Say "windows-vm-check: $($script:Pass) pass / $($script:Fail) fail — $verdict"
	Save-Log
	Say "log: $Results\windows-vm-check.log"
	exit ([int]($script:Fail -gt 0))
}

# host-agent.ps1 in a child shell from the fixture project: output and exit code.
function Invoke-Agent([string[]]$Arguments) {
	Push-Location $Fixture
	try {
		$out = Invoke-Native powershell.exe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Kit 'host-agent.ps1')) + $Arguments) | Out-String
		return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
	}
	finally { Pop-Location }
}
function Show-Indented([string]$Text) { foreach ($l in ($Text -split "`r?`n")) { if ($l) { Say "    $l" } } }
function Get-OnProfile([string]$ProfileDir) {
	$needle = "--user-data-dir=$ProfileDir".ToLowerInvariant()
	return @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($needle) })
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Set-Content -LiteralPath $LocalLog -Value '' -Encoding UTF8
Say "windows-vm-check — started $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ── 0. preflight ─────────────────────────────────────────────────────────────
Section '0. preflight'
# What an interrupted earlier run left: its test-page server (a stale page on
# the port), its abcheck instances (their tasks, tray and supervisor).
$left = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('play-container.mjs') })
foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
$tasks = @(Get-ScheduledTask -TaskPath '\meitogi\agent-browser\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(tray\.)?abcheck\.' })
foreach ($t in $tasks) { Stop-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue ; Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false }
foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('\agent-browser\abcheck.') -and $_.ProcessId -ne $PID })) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
if ($left.Count -or $tasks.Count) { Say "  cleaned up an earlier run: $($left.Count) page server(s), $($tasks.Count) task(s)" }
$os = Get-CimInstance Win32_OperatingSystem
Say "  $($os.Caption) $($os.Version) build $($os.BuildNumber), $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture), PowerShell $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -ne 5) { Ko "this is PowerShell $($PSVersionTable.PSVersion) — run it with powershell.exe (Windows PowerShell 5.1), the one Windows ships" ; Finish }
Ok 'Windows PowerShell 5.1'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($admin) { Ko 'this window is elevated (Run as administrator) — open a normal PowerShell window: the agent must work without admin rights' ; Finish }
Ok 'not elevated'

$node = Get-Command node -ErrorAction SilentlyContinue
$major = 0
# `node -v` parsed here: 5.1 strips double quotes inside a native program's arguments.
if ($node -and [string](& $node.Source -v | Select-Object -First 1) -match '^v(\d+)\.') { $major = [int]$Matches[1] }
if ($major -lt 22) {
	Say '  node 22+ not found — installing the current Node LTS for this user (a zip, no admin)'
	$index = Invoke-RestMethod -UseBasicParsing 'https://nodejs.org/dist/index.json'
	$lts = $index | Where-Object { $_.lts } | Select-Object -First 1
	$arch = 'x64'
	if ([string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { $arch = 'arm64' }
	$name = "node-$($lts.version)-win-$arch"
	$zip = Join-Path $Work "$name.zip"
	Say "  downloading $name.zip (about 30 MB)…"
	Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$($lts.version)/$name.zip" -OutFile $zip
	$sums = (Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$($lts.version)/SHASUMS256.txt").Content
	$want = ($sums -split "`n" | Where-Object { $_ -match "  $name\.zip$" }) -replace '\s.*$', ''
	if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $want) { Ko "the node zip does not match SHASUMS256.txt" ; Finish }
	$dest = Join-Path $env:LOCALAPPDATA 'Programs'
	New-Item -ItemType Directory -Force -Path $dest | Out-Null
	Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
	$nodeDir = Join-Path $dest $name
	$env:PATH = "$nodeDir;$env:PATH"
	$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
	if (-not $userPath -or $userPath -notlike "*$nodeDir*") { [Environment]::SetEnvironmentVariable('PATH', "$nodeDir;$userPath", 'User') }
	$script:Installed += "node $($lts.version) ($nodeDir, on your user PATH)"
	$node = Get-Command node
}
Ok "node $(& $node.Source -v) at $($node.Source)"

Say "  copying what the check needs from $Share to $Repo…"
if (Test-Path -LiteralPath $Repo) { Remove-Item -LiteralPath $Repo -Recurse -Force }
foreach ($rel in 'assets\opt\skills\agent-browser', 'assets\opt\skills\visual-loop', 'test\host') {
	New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $Repo $rel)) | Out-Null
	Copy-Item -LiteralPath (Join-Path $Share $rel) -Destination (Join-Path $Repo $rel) -Recurse
}
foreach ($rel in 'test\host-agent.Tests.ps1', 'test\PSScriptAnalyzerSettings.psd1') { Copy-Item -LiteralPath (Join-Path $Share $rel) -Destination (Join-Path $Repo $rel) }
Ok 'kit copied to local disk'
Save-Log

# ── 1. parse and lint on 5.1 ─────────────────────────────────────────────────
Section '1. parse and lint (Windows PowerShell 5.1)'
foreach ($f in 'host-agent.ps1', 'tray.ps1') {
	$errs = $null
	$tokens = $null
	[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Kit $f), [ref]$tokens, [ref]$errs)
	if ($errs.Count -eq 0) { Ok "$f parses" } else { Ko "$f : $($errs.Count) parse errors — $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))" }
}
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge '2.8.5.201' })) {
	Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
	$script:Installed += 'the NuGet package provider'
}
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
	Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -Repository PSGallery
	$script:Installed += 'PSScriptAnalyzer'
}
$findings = foreach ($f in 'host-agent.ps1', 'tray.ps1') { Invoke-ScriptAnalyzer -Path (Join-Path $Kit $f) -Settings (Join-Path $Repo 'test\PSScriptAnalyzerSettings.psd1') }
$other = @($findings | Where-Object { $_.RuleName -ne 'PSAvoidUsingEmptyCatchBlock' })
foreach ($x in $other) { Say "    $($x.RuleName) $(Split-Path -Leaf $x.ScriptPath):$($x.Line) $($x.Message)" }
if ($other.Count -eq 0) { Ok "PSScriptAnalyzer: nothing but the $(@($findings).Count) deliberate empty catches" } else { Ko "PSScriptAnalyzer: $($other.Count) findings (above)" }
Save-Log

# ── 2. Pester ────────────────────────────────────────────────────────────────
Section '2. Pester 6.2.0 — test\host-agent.Tests.ps1'
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq '6.2.0' })) {
	Say '  installing Pester 6.2.0 for this user (the bundled 3.4 is too old)…'
	Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force -SkipPublisherCheck -Repository PSGallery
	$script:Installed += 'Pester 6.2.0'
}
# Line by line as Pester prints them, not one block at the end: the live log follows.
$pesterLines = New-Object Collections.Generic.List[string]
Invoke-Native powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "Import-Module Pester -RequiredVersion 6.2.0; `$r = Invoke-Pester -Path '$(Join-Path $Repo 'test\host-agent.Tests.ps1')' -Output Detailed -PassThru; 'PESTER passed=' + `$r.PassedCount + ' failed=' + `$r.FailedCount + ' skipped=' + `$r.SkippedCount") | ForEach-Object {
	$pesterLines.Add($_)
	if ($_ -notmatch '^\s*(à|at) .*Pester\.psm1') { Say "    $_" }
}
$pester = $pesterLines -join "`n"
if ($pester -match 'PESTER passed=(\d+) failed=(\d+) skipped=(\d+)') {
	if ([int]$Matches[2] -eq 0 -and [int]$Matches[3] -eq 0) { Ok "Pester: $($Matches[1]) passed, none failed, none skipped" }
	else { Ko "Pester: $($Matches[1]) passed, $($Matches[2]) failed, $($Matches[3]) skipped (above)" }
}
else { Ko 'Pester did not report (above)' }
Save-Log

# ── 3. Chromium ──────────────────────────────────────────────────────────────
Section '3. Chromium: found, then install-chromium'
New-Item -ItemType Directory -Force -Path (Join-Path $Fixture '.devcontainer\firewall') | Out-Null
Set-Content -LiteralPath (Join-Path $Fixture '.devcontainer\docker-compose.yml') -Value ''
[IO.File]::WriteAllText((Join-Path $Fixture '.devcontainer\.env'), "DC_PROJECT=abcheck`nAGENT_BROWSER_ORIGINS=http://localhost:$PagePort`nAGENT_BROWSER_PROXY_PORT=19500`nAGENT_BROWSER_CDP_PORT=19600`nAGENT_BROWSER_Z_NOTE=windows-vm-check, removed at the end`n")
[IO.File]::WriteAllText((Join-Path $Fixture '.devcontainer\firewall\ports.txt'), "host:19525`n")
$found = @(& node (Join-Path $Kit 'host-supervisor.mjs') find-chromium)
if ($found[0]) { Ok "the supervisor finds $($found[0])" } else { Ko 'no Chromium found (Edge should always be there):' ; Show-Indented ($found -join "`n") }
# Edge itself for step 4, whatever the search prefers (a snapshot left by an
# earlier run comes first).
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($edge) { Ok "Edge: $edge" } else { Ko 'no Edge in Program Files' ; $edge = $found[0] }
$r = Invoke-Agent @('install-chromium')
Show-Indented $r.Out
$snap = Join-Path $env:LOCALAPPDATA 'agent-browser\chromium\chrome-win\chrome.exe'
if ($r.Code -eq 0 -and (Test-Path -LiteralPath $snap)) {
	$rev = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'agent-browser\chromium\REVISION') -Raw
	Ok "install-chromium: $($rev.Trim())"
	$script:Notes += "install-chromium took $($rev.Trim())"
	$script:Installed += "the Chromium snapshot ($(Split-Path (Split-Path $snap)))"
}
else { Ko "install-chromium: exit $($r.Code) (above)" }
$first = @(& node (Join-Path $Kit 'host-supervisor.mjs') find-chromium)[0]
if ($first -eq $snap) { Ok 'after install-chromium, the supervisor picks the snapshot first' } else { Ko "the supervisor still picks $first" }
Save-Log

# ── 4. install z on Edge, drive it, capture ──────────────────────────────────
Section "4. install z on $edge — the container played, a capture through the proxy"
$page = Start-Process -FilePath (Get-Command node).Source -ArgumentList "`"$(Join-Path $Repo 'test\host\play-container.mjs')`" serve $PagePort" -WindowStyle Hidden -PassThru
# Its own page, with the #app root cdp.mjs waits for — not one a stale server serves.
if (Wait-Until 10 'the test page' { (Invoke-WebRequest -UseBasicParsing "http://localhost:$PagePort/").Content -match 'id="app"' }) { Ok "test page on http://localhost:$PagePort/" } else { Ko "the test page did not come up (port $PagePort taken by something else?)" ; Finish }
$env:AGENT_BROWSER_CHROMIUM = $edge
Say '  watch the screen during the install: does a console window flash?'
$r = Invoke-Agent @('install', 'z')
Remove-Item Env:\AGENT_BROWSER_CHROMIUM
Show-Indented $r.Out
if ($r.Code -eq 0 -and ([regex]::Matches($r.Out, '(?m)^\[[1-5]/5 [a-z]+\] (ok|warn) — ')).Count -eq 5) { Ok 'install z: five steps' } else { Ko "install z: exit $($r.Code) (above)" }
$z = Join-Path $env:LOCALAPPDATA 'agent-browser\abcheck.z'
$ctl = Join-Path $Fixture '.devcontainer\tmp\agent-browser\z\host'
if (Ask 'Did a console (black) window appear, even briefly, during the install?') { $script:Notes += 'a console window flashed at install (conhost --headless did not hide it)' ; Ko 'a console window flashed' } else { Ok 'no console window' }

# The tray's icons drawn by each browser on its own: how long, which exit, how many.
foreach ($b in @($edge, $snap) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
	$dir = Join-Path $Work "icons-$([IO.Path]::GetFileNameWithoutExtension($b))"
	if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
	New-Item -ItemType Directory -Force -Path $dir | Out-Null
	$t0 = Get-Date
	$out = Invoke-Native node @((Join-Path $Kit 'menubar-icon.mjs'), (Join-Path $Kit 'menubar-icon.svg'), 'AB', $b, 'z', '--tray', $dir) | Out-String
	$secs = [int]((Get-Date) - $t0).TotalSeconds
	$n = @(Get-ChildItem -LiteralPath $dir -Filter '*.ico').Count
	if ($LASTEXITCODE -eq 0 -and $n -eq 8) { Ok "tray icons drawn by $(Split-Path -Leaf $b) in ${secs}s: 8 ICOs" }
	else { Ko "tray icons by $(Split-Path -Leaf $b): exit $LASTEXITCODE after ${secs}s, $n ICOs" ; Show-Indented $out }
}

function Test-Drive([string]$Label) {
	$out = Invoke-Native node @((Join-Path $Repo 'test\host\play-container.mjs'), 'drive', $ctl, "http://localhost:$PagePort/", '--timeout', '30') | Out-String
	Show-Indented $out
	if ($LASTEXITCODE -eq 0) { Ok "$Label : up, proxy, page, down" } else { Ko "$Label : the drive failed (above)" ; Show-Indented ((Get-Content -LiteralPath (Join-Path $z 'logs\supervisor.log') -Tail 15) -join "`n") }
	# up again for the capture
	$nonce = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	[IO.File]::WriteAllText((Join-Path $ctl 'cmd'), "$nonce up http://localhost:$PagePort/`n")
	[void](Wait-Until 30 'state running' { (Get-Content -LiteralPath (Join-Path $ctl 'state') -Raw) -like "$nonce running *" })
	$port = (Get-Content -LiteralPath (Join-Path $ctl 'port') -Raw).Trim()
	# Written on the local disk, then copied to the share (WebDAV).
	$png = Join-Path $Work "windows-vm-check-$Label.png"
	$env:CDP_HOST = '127.0.0.1'
	$env:CDP_PORT = $port
	$env:CDP_LOCK_DIR = Join-Path $Work 'locks'
	$shot = Invoke-Native node @((Join-Path $Repo 'assets\opt\skills\visual-loop\scripts\cdp.mjs'), 'shot', '--url', "http://localhost:$PagePort/", '--out', $png) | Out-String
	Remove-Item Env:\CDP_HOST, Env:\CDP_PORT
	Show-Indented $shot
	if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 1000) {
		Ok "$Label : cdp.mjs shot through the proxy → $(Split-Path -Leaf $png) ($((Get-Item -LiteralPath $png).Length) bytes)"
		New-Item -ItemType Directory -Force -Path $Results | Out-Null
		Copy-Item -LiteralPath $png -Destination $Results -Force
	}
	else { Ko "$Label : cdp.mjs shot failed (exit $LASTEXITCODE, above)" }
}
Test-Drive 'edge'
if (Ask 'Did a Windows Defender Firewall dialog appear at any point so far?') { $script:Notes += 'a firewall dialog appeared' ; Ko 'a firewall dialog appeared (loopback should not prompt)' } else { Ok 'no firewall dialog' }
Save-Log

# ── 5. the tray ──────────────────────────────────────────────────────────────
Section '5. the tray icon'
Say '  Chromium is running for instance z now. Look at the notification area, bottom right'
Say '  (click ^ if the icon is hidden): a globe with « AB » in a tag and z in the dot.'
if (Ask 'Do you see that icon?') { Ok 'tray icon visible' } else { Ko 'no tray icon' }
if (Ask 'Right-click it: does the menu show « abcheck.z », its note, « Chromium <pid> on http://localhost:19580/ » and « Turn Chromium off »?') { Ok 'tray menu shows the running state' } else { Ko 'the tray menu is not as described' }
Say "  optional: a screenshot (Win+Shift+S) saved as $Results\windows-vm-check-tray.png"
if (Ask 'Click « Turn Chromium off » in that menu, wait 5 s: does the icon lose its filled dot (idle)?') { Ok 'tray: Turn Chromium off works, the icon follows' } else { Ko 'tray: off did not show idle' }
Say '  the tray''s own log (states it computed, errors):'
Show-Indented ((Get-Content -LiteralPath (Join-Path $z 'logs\tray.log') -ErrorAction SilentlyContinue) -join "`n")
Save-Log

# ── 6. restart on failure ────────────────────────────────────────────────────
Section '6. the supervisor killed by hand: does the Task Scheduler restart it?'
$envJson = Join-Path $z 'env.json'
$sup = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($envJson) })
if ($sup.Count) {
	Stop-Process -Id $sup[0].ProcessId -Force
	Say "  killed node $($sup[0].ProcessId) ; the task restarts a failed run after 1 min"
	$back = Wait-Until 100 'a new supervisor (heartbeat)' { [long](Get-Content -LiteralPath (Join-Path $ctl 'heartbeat') -Raw) -ge ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3) -and @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($envJson) }).Count -gt 0 }
	$info = Get-ScheduledTaskInfo -TaskPath '\meitogi\agent-browser\' -TaskName 'abcheck.z'
	Say "  task last result 0x$('{0:x}' -f $info.LastTaskResult), state $((Get-ScheduledTask -TaskPath '\meitogi\agent-browser\' -TaskName 'abcheck.z').State)"
	if ($back) { Ok 'restarted by the Task Scheduler' } else { Ko 'not restarted within 100 s' ; $script:Notes += 'the task did not restart a killed supervisor — conhost --headless may not pass the exit code on' ; [void](Invoke-Agent @('start', 'z')) }
}
else { Ko 'no supervisor process found for z' }
Save-Log

# ── 7. the Chromium snapshot ─────────────────────────────────────────────────
Section '7. the same on the Chromium snapshot'
if (Test-Path -LiteralPath $snap) {
	$r = Invoke-Agent @('install', 'z')
	if ($r.Code -eq 0 -and $r.Out -match [regex]::Escape($snap)) { Ok 'install z again: the snapshot' } else { Ko "install z on the snapshot: exit $($r.Code)" ; Show-Indented $r.Out }
	Test-Drive 'chromium'
}
else { Ko 'no snapshot (step 3 failed)' }
Save-Log

# ── 8. run c --temp, Ctrl-C by the human ─────────────────────────────────────
Section '8. run c --temp in a new window, then Ctrl-C there'
$c = Join-Path $env:LOCALAPPDATA 'agent-browser\abcheck.c'
$ctlC = Join-Path $Fixture '.devcontainer\tmp\agent-browser\c\host'
$runCmd = "Set-Location '$Fixture'; `$Host.UI.RawUI.WindowTitle = 'agent-browser run c --temp'; & '$(Join-Path $Kit 'host-agent.ps1')' run c --temp --port 19592 --cdp-port 19692"
$win = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $runCmd -PassThru
if (Wait-Until 30 "c's heartbeat" { [long](Get-Content -LiteralPath (Join-Path $ctlC 'heartbeat') -Raw) -ge ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3) }) { Ok 'run c --temp beats' } else { Ko 'no heartbeat from run c' }
$out = Invoke-Native node @((Join-Path $Repo 'test\host\play-container.mjs'), 'drive', $ctlC, "http://localhost:$PagePort/", '--timeout', '30') | Out-String
Show-Indented $out
if ($LASTEXITCODE -eq 0) { Ok 'c : up, proxy, page, down' } else { Ko 'c : the drive failed (above)' }
$nonce = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
[IO.File]::WriteAllText((Join-Path $ctlC 'cmd'), "$nonce up http://localhost:$PagePort/`n")
[void](Wait-Until 30 'c running' { (Get-Content -LiteralPath (Join-Path $ctlC 'state') -Raw) -like "$nonce running *" })
Say '  NOW: click the window titled « agent-browser run c --temp » and press Ctrl-C there (Chromium is running in it).'
$gone = Wait-Until 120 'Ctrl-C in that window, then c cleaned up' { $win.HasExited -or ((-not (Test-Path -LiteralPath $c)) -and (Get-OnProfile (Join-Path $c 'profile')).Count -eq 0) }
[void](Wait-Until 15 'the run to finish its cleanup' { -not (Test-Path -LiteralPath $c) })
if ($gone -and -not (Test-Path -LiteralPath $c)) { Ok "Ctrl-C: c's profile and logs removed" } else { Ko "Ctrl-C: $c still there" }
if ((Get-OnProfile (Join-Path $c 'profile')).Count -eq 0) { Ok 'Ctrl-C: no Chromium left on c' } else { Ko 'a Chromium is still on c' }
if (-not (Test-Path -LiteralPath (Join-Path $ctlC 'heartbeat'))) { Ok "Ctrl-C: c's heartbeat gone" } else { Ko "c's heartbeat is still there" }
Save-Log

# ── 9. clean up ──────────────────────────────────────────────────────────────
Section '9. uninstall z'
$r = Invoke-Agent @('uninstall', 'z')
Show-Indented $r.Out
if ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $z) -and -not (Get-ScheduledTask -TaskPath '\meitogi\agent-browser\' -TaskName 'abcheck.z' -ErrorAction SilentlyContinue)) { Ok 'uninstall z: tasks and folders gone' } else { Ko 'uninstall z left something (above)' }
if ($page -and -not $page.HasExited) { Stop-Process -Id $page.Id -Force }
Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
Finish
