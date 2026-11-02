# host-agent.Tests.ps1 — the Windows host agent (host-agent.ps1), Pester 6.
#
# The pure parts run anywhere PowerShell does (pwsh in the container, Windows
# PowerShell 5.1 in the VM): the .env as data, instances, ports, env.json, the
# task's command, the kit hash, list --json, the paste block, the argument
# grammar. The « Task Scheduler » part needs Windows, node 22+ and a Chromium
# (Edge is enough): it installs instance y of a fixture project for real, then
# start / stop / list / uninstall. It is skipped elsewhere.
#
#   Invoke-Pester -Path test/host-agent.Tests.ps1 -Output Detailed
#
# Windows PowerShell 5.1 or pwsh 7.4+.

BeforeAll {
	$script:Kit = (Resolve-Path (Join-Path $PSScriptRoot '..\assets\opt\skills\agent-browser\host')).ProviderPath
	$script:Ps1 = Join-Path $script:Kit 'host-agent.ps1'
	$script:Shell = (Get-Process -Id $PID).Path
	$script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
	. $script:Ps1

	# A project folder: docker-compose.yml, a .env and a ports.txt.
	function New-Fixture([string]$EnvText, [string]$Ports = $null) {
		$repo = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n').Substring(0, 8))
		New-Item -ItemType Directory -Force -Path (Join-Path $repo '.devcontainer\firewall') | Out-Null
		Set-Content -LiteralPath (Join-Path $repo '.devcontainer\docker-compose.yml') -Value ''
		[IO.File]::WriteAllText((Join-Path $repo '.devcontainer\.env'), $EnvText)
		if ($null -ne $Ports) { [IO.File]::WriteAllText((Join-Path $repo '.devcontainer\firewall\ports.txt'), $Ports) }
		return $repo
	}

	# host-agent.ps1 in a child shell, from <repo>: its output and exit code.
	function Invoke-Agent([string]$Repo, [string[]]$Arguments) {
		Push-Location $Repo
		try {
			$out = Invoke-Native $script:Shell (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Ps1) + $Arguments) | Out-String
			return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
		}
		finally { Pop-Location }
	}
}

Describe 'the .env, read as data' {
	It 'takes KEY=value, the last one wins, quotes stripped, comments and junk ignored' {
		$v = ConvertFrom-DotEnv "# comment`nA=1`n  B=`"two words`"`nC='x'`nA=3`r`nnot a line`n=x"
		$v['A'] | Should -Be '3'
		$v['B'] | Should -Be 'two words'
		$v['C'] | Should -Be 'x'
		$v.Count | Should -Be 3
	}
	It 'never runs it: a $(...) stays text' {
		(ConvertFrom-DotEnv 'X=$(Remove-Item C:\)')['X'] | Should -Be '$(Remove-Item C:\)'
	}
}

Describe 'instances' {
	BeforeAll {
		$script:SavedLocal = $env:LOCALAPPDATA
		$env:LOCALAPPDATA = Join-Path $TestDrive 'local'
		foreach ($k in 'DC_PROJECT', 'AGENT_BROWSER_PROXY_PORT', 'AGENT_BROWSER_CDP_PORT', 'AGENT_BROWSER_ORIGINS', 'AGENT_BROWSER_B_NOTE') { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
		$script:Repo = New-Fixture "DC_PROJECT=Demo App`nAGENT_BROWSER_PROXY_PORT=19500`nAGENT_BROWSER_CDP_PORT=19600`nAGENT_BROWSER_ORIGINS=http://localhost:5173`nAGENT_BROWSER_B_NOTE=`"sync suite | b`"" "host:19500`nhost:19501  # b`n# host:19503`n"
		Read-Project $script:Repo
	}
	AfterAll { $env:LOCALAPPDATA = $script:SavedLocal }

	It 'normalises the project name like host-agent.sh' {
		$script:Project | Should -Be 'demo-app'
	}
	It 'derives b: label, task, ports + 1, its own folders and channel' {
		$b = Get-AbInstance 'b'
		$b.Label | Should -Be 'io.meitogi.agent-browser.demo-app.b'
		$b.Task | Should -Be 'demo-app.b'
		$b.TrayTask | Should -Be 'tray.demo-app.b'
		$b.ProxyPort | Should -Be 19501
		$b.CdpPort | Should -Be 19601
		$b.App | Should -Be (Join-Path $env:LOCALAPPDATA 'agent-browser\demo-app.b')
		$b.EnvJson | Should -Be (Join-Path $b.App 'env.json')
		$b.Ctl | Should -Be (Join-Path $script:Repo '.devcontainer\tmp\agent-browser\b\host')
		(Get-AbInstance 'a').Ctl | Should -Be (Join-Path $script:Repo '.devcontainer\tmp\agent-browser\host')
		$b.Installed | Should -BeFalse
	}
	It 'reads the firewall: host:PORT lines, comments ignored' {
		Test-Opens 19501 | Should -BeTrue
		Test-Opens 19503 | Should -BeFalse
		(Get-Discovered) -join ' ' | Should -Be 'a b'
	}
	It 'installed, an instance has the ports of its env.json' {
		$c = Get-AbInstance 'c'
		New-Item -ItemType Directory -Force -Path $c.App | Out-Null
		'{"AGENT_BROWSER_PROXY_PORT":"19555","AGENT_BROWSER_CDP_PORT":"19655"}' | Set-Content -LiteralPath $c.EnvJson
		$c = Get-AbInstance 'c'
		$c.Installed | Should -BeTrue
		$c.ProxyPort | Should -Be 19555
		$c.DerivedProxyPort | Should -Be 19502
		Remove-Item -LiteralPath $c.App -Recurse
	}
	It 'the note: one line, no « | »' {
		Get-Note (Get-AbInstance 'b') | Should -Be 'sync suite  b'
	}
}

Describe 'what the task runs' {
	BeforeAll {
		$env:LOCALAPPDATA = Join-Path $TestDrive 'local'
		if (-not $env:WINDIR) { $env:WINDIR = 'C:\Windows' }
		Read-Project (New-Fixture "DC_PROJECT=demo`nAGENT_BROWSER_ORIGINS=http://localhost:5173`nAGENT_BROWSER_CHROMIUM=C:\c\chrome.exe")
		$script:I = Get-AbInstance 'a'
	}
	It 'env.json: every value a string the supervisor keeps, the Chromium of the .env first' {
		$e = Get-SupervisorEnv $script:I 'C:\n\node.exe' 'C:\found\msedge.exe'
		foreach ($k in $e.Keys) { $e[$k] | Should -BeOfType [string] }
		$e.AGENT_BROWSER_CHROMIUM | Should -Be 'C:\c\chrome.exe'
		$e.AGENT_BROWSER_PROXY_PORT | Should -Be '9223'
		$e.AGENT_BROWSER_CTL | Should -Be $script:I.Ctl
		$json = ConvertTo-Json -InputObject $e -Compress
		# An import takes a URL, not a C:\ path: file:///C:/… on Windows, file:///… elsewhere.
		$url = 'file:///' + (($script:Kit -replace '\\', '/').TrimStart('/')) + '/host-supervisor.mjs'
		$kept = node --input-type=module -e "import { readEnvFile } from '$url'; process.stdout.write(String(Object.keys(readEnvFile(process.argv[1])).length))" $json
		[int]$kept | Should -Be $e.Count
	}
	It 'the supervisor through conhost --headless, its env.json, its own log' {
		$c = Get-TaskCommand $script:I 'C:\Program Files\nodejs\node.exe'
		$c.Execute | Should -Be "$env:WINDIR\System32\conhost.exe"
		$c.Arguments | Should -BeLike '--headless "C:\Program Files\nodejs\node.exe" "*host-supervisor.mjs" --env "*" --log'
		$c.Arguments -match '--env "([^"]+)"' | Should -BeTrue
		$Matches[1] | Should -Be $script:I.EnvJson
	}
	It 'the tray through conhost --headless too, pointed at the instance folder' {
		(Get-TrayCommand $script:I).Arguments | Should -BeLike "--headless powershell.exe * -File `"*tray.ps1`" -App `"$($script:I.App)`""
	}
}

Describe 'the kit hash' {
	It 'is the hash host-agent.sh and agent-browser status print (byte order of ./paths)' {
		$d = Join-Path $TestDrive 'kit'
		New-Item -ItemType Directory -Force -Path (Join-Path $d 'a') | Out-Null
		[IO.File]::WriteAllText((Join-Path $d 'A.txt'), "A`n")
		[IO.File]::WriteAllText((Join-Path $d 'a\x.txt'), "x`n")
		[IO.File]::WriteAllText((Join-Path $d 'b.txt'), "b`n")
		Get-KitHash $d | Should -Be 'cfe327c0da67'
	}
}

Describe 'install-chromium' {
	It 'tries the ARM64 snapshot first on ARM64, x64 only on x64' {
		(Get-SnapshotFolders 'Arm64') -join ' ' | Should -Be 'Win_Arm64 Win_x64'
		(Get-SnapshotFolders 'X64') -join ' ' | Should -Be 'Win_x64'
	}
}

Describe 'list --json and the paste block' {
	BeforeAll {
		$env:LOCALAPPDATA = Join-Path $TestDrive 'local'
		Read-Project (New-Fixture "DC_PROJECT=demo`nAGENT_BROWSER_ORIGINS=http://localhost:5173" "host:9223`n")
	}
	It 'has the fields of host-agent.sh list --json: numbers, nulls, the clash' {
		$a = Get-AbInstance 'a'
		$a.Installed = $true
		$row = New-ListRow $a $true 4242 'running' 77 $false 1 ''
		$j = ConvertTo-ListJson @($row) @([ordered]@{ job = 'io.meitogi.agent-browser.other'; port = 9223; clash = 'a' }) | ConvertFrom-Json
		$j.project | Should -Be 'demo'
		$j.firewall | Should -Be '.devcontainer/firewall/ports.txt'
		$j.instances[0].instance | Should -Be 'a'
		$j.instances[0].supervisor | Should -Be 4242
		$j.instances[0].chromium.state | Should -Be 'running'
		$j.instances[0].chromium.pid | Should -Be 77
		$j.instances[0].proxy.port | Should -Be 9223
		$j.instances[0].proxy.listening | Should -BeFalse
		$j.instances[0].heartbeat | Should -Be 1
		$j.others[0].clash | Should -Be 'a'
		$none = ConvertTo-ListJson @(New-ListRow (Get-AbInstance 'b') $false $null 'stopped' $null $false $null 'n') @() | ConvertFrom-Json
		$none.instances[0].supervisor | Should -BeNullOrEmpty
		$none.instances[0].installed | Should -BeFalse
		@($none.others).Count | Should -Be 0
	}
	It 'the paste block names the instance, the origins, the commands and exit 3' {
		$t = Get-Brief (Get-AbInstance 'd') $true
		$t | Should -Match '──── paste this to the agent'
		$t | Should -Match 'instance d, temporary'
		$t | Should -Match 'agent-browser -i d up <url>'
		$t | Should -Match 'CDP_INSTANCE=d node /opt/devcontainer/base/skills/visual-loop/scripts/cdp.mjs shot'
		$t | Should -Match 'eval "\$\(agent-browser -i d env\)"'
		$t | Should -Match 'exit 3'
	}
}

Describe 'the argument grammar (host-agent.ps1 in a child shell)' {
	BeforeAll {
		$env:AGENT_BROWSER_HOST_TEST = '1'
		$script:Repo = New-Fixture "DC_PROJECT=demo`nAGENT_BROWSER_ORIGINS=http://localhost:5173" "host:9223`nhost:9224`n"
	}
	AfterAll { $env:AGENT_BROWSER_HOST_TEST = $null }
	It 'refuses --port with two instances, a bad port, --port on start, --temp off run' {
		foreach ($a in @(@('install', 'a', 'b', '--port', '19555'), @('install', 'c', '--port', '80'), @('install', 'c', '--port', '99999'), @('start', 'c', '--port', '19555'), @('install', 'c', '--temp'))) {
			$r = Invoke-Agent $script:Repo $a
			$r.Code | Should -Be 2 -Because ($a -join ' ')
		}
		(Invoke-Agent $script:Repo @('install', 'a', 'b', '--port', '19555')).Out | Should -Match 'ONE instance'
	}
	It 'refuses what is not a letter' {
		$r = Invoke-Agent $script:Repo @('status', '1')
		$r.Code | Should -Be 2
		$r.Out | Should -Match 'one letter'
	}
	It 'instances: a and b from the firewall, their ports and channels' {
		$r = Invoke-Agent $script:Repo @('instances')
		$r.Code | Should -Be 0
		$r.Out | Should -Match '  a  io\.meitogi\.agent-browser\.demo  proxy 127\.0\.0\.1:9223  devtools 127\.0\.0\.1:9323'
		$r.Out | Should -Match '  b  io\.meitogi\.agent-browser\.demo\.b  proxy 127\.0\.0\.1:9224'
	}
	It 'outside a project root, says where to run it' {
		Push-Location $TestDrive
		try { $out = Invoke-Native $script:Shell @('-NoProfile', '-File', $script:Ps1, 'status') | Out-String; $LASTEXITCODE | Should -Be 2 }
		finally { Pop-Location }
		$out | Should -Match 'run this from the project root'
	}
}

# ── the real thing: Windows, its Task Scheduler, node, a Chromium ────────────

Describe 'Task Scheduler (Windows only)' -Skip:(-not ([Environment]::OSVersion.Platform -eq 'Win32NT')) {
	BeforeAll {
		$script:Repo = New-Fixture "DC_PROJECT=abcheck`nAGENT_BROWSER_ORIGINS=http://localhost:19580`nAGENT_BROWSER_PROXY_PORT=19500`nAGENT_BROWSER_CDP_PORT=19600" "host:19590`n"
		Read-Project $script:Repo
		$script:Y = Get-AbInstance 'y'
		$script:TaskPath = '\meitogi\agent-browser\'
		Invoke-Agent $script:Repo @('uninstall', 'y') | Out-Null
		function Wait-Until([int]$Seconds, [string]$What, [scriptblock]$Test) {
			$t0 = Get-Date
			while (-not (& $Test)) {
				$el = [int]((Get-Date) - $t0).TotalSeconds
				if ($el -ge $Seconds) { return $false }
				Write-Host "      … waiting for $What (${el}s / ${Seconds}s)"
				Start-Sleep -Seconds 1
			}
			return $true
		}
		function Get-OnProfile { @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains("--user-data-dir=$($script:Y.Profile)".ToLowerInvariant()) }) }
	}
	AfterAll { Invoke-Agent $script:Repo @('uninstall', 'y') | Out-Null }

	It 'install y --port 19590: five steps, a task at logon for this user, no time limit, restarted' {
		$r = Invoke-Agent $script:Repo @('install', 'y', '--port', '19590', '--cdp-port', '19690')
		Write-Host $r.Out
		$r.Code | Should -Be 0
		([regex]::Matches($r.Out, '(?m)^\[[1-5]/5 (kit|chromium|firewall|scheduler|heartbeat)\] (ok|warn) — ')).Count | Should -Be 5
		$t = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y'
		$t.Principal.LogonType | Should -Be 'Interactive'
		$t.Principal.RunLevel | Should -Be 'Limited'
		$t.Triggers[0].CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
		$t.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
		$t.Settings.RestartCount | Should -BeGreaterThan 0
		$t.Actions[0].Execute | Should -BeLike '*\conhost.exe'
		$t.State | Should -Be 'Running'
		Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'tray.abcheck.y' | Should -Not -BeNullOrEmpty
		(Get-Content -LiteralPath $script:Y.EnvJson -Raw | ConvertFrom-Json).AGENT_BROWSER_PROXY_PORT | Should -Be '19590'
	}
	It 'beats, announces 19590, answers an up on the allowed origin, the proxy listens' {
		Wait-Until 10 'the heartbeat' { (Get-Beat $script:Y) -ge ((Get-Epoch) - 3) } | Should -BeTrue
		Read-Plain (Join-Path $script:Y.Ctl 'port') | Should -Be '19590'
		$nonce = [string](Get-Epoch) + '000'
		[IO.File]::WriteAllText((Join-Path $script:Y.Ctl 'cmd'), "$nonce up http://localhost:19580/`n")
		Wait-Until 30 'state running' { (Read-Plain (Join-Path $script:Y.Ctl 'state')) -like "$nonce running *" } | Should -BeTrue
		Wait-Until 10 'the proxy on 19590' { (Get-Listener 19590).Listening } | Should -BeTrue
		@(Get-OnProfile).Count | Should -BeGreaterThan 0
	}
	It 'list --json: y loaded, its supervisor pid, Chromium running, the proxy listening' {
		$r = Invoke-Agent $script:Repo @('list', '--json')
		$y = ($r.Out | ConvertFrom-Json).instances | Where-Object { $_.instance -eq 'y' }
		$y.loaded | Should -BeTrue
		$y.supervisor | Should -BeGreaterThan 0
		$y.chromium.state | Should -Be 'running'
		$y.proxy.listening | Should -BeTrue
	}
	It 'stop y: the task stopped and disabled, no supervisor, no Chromium left on the profile' {
		$r = Invoke-Agent $script:Repo @('stop', 'y')
		$r.Code | Should -Be 0
		(Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y').State | Should -Be 'Disabled'
		Wait-Until 10 'Chromium gone' { @(Get-OnProfile).Count -eq 0 } | Should -BeTrue
		@(Get-ProcessByCommandLine $script:Y.EnvJson).Count | Should -Be 0
		(Get-Listener 19590).Listening | Should -BeFalse
	}
	It 'start y: enabled, running, five steps, a heartbeat' {
		$r = Invoke-Agent $script:Repo @('start', 'y')
		Write-Host $r.Out
		$r.Code | Should -Be 0
		([regex]::Matches($r.Out, '(?m)^\[[1-5]/5 [a-z]+\] (ok|warn) — ')).Count | Should -Be 5
		(Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y').State | Should -Be 'Running'
	}
	It 'a supervisor killed hard (TerminateProcess): its Chromium found and killed at the next start' {
		$nonce = [string](Get-Epoch) + '000'
		[IO.File]::WriteAllText((Join-Path $script:Y.Ctl 'cmd'), "$nonce up http://localhost:19580/`n")
		Wait-Until 30 'state running' { (Read-Plain (Join-Path $script:Y.Ctl 'state')) -like "$nonce running *" } | Should -BeTrue
		$orphan = [int]((Read-Plain (Join-Path $script:Y.Ctl 'state')) -split ' ')[2]
		Stop-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y'
		foreach ($p in Get-ProcessByCommandLine $script:Y.EnvJson) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
		Get-Process -Id $orphan -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'TerminateProcess leaves Chromium behind — what the sweep is for'
		Start-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y'
		Wait-Until 20 'the orphan killed' { -not (Get-Process -Id $orphan -ErrorAction SilentlyContinue) } | Should -BeTrue
		Get-Content -LiteralPath (Join-Path $script:Y.LogDir 'supervisor.log') -Raw | Should -Match "killed Chromium $orphan on"
	}
	It 'uninstall y: both tasks, the copy, the profile, the logs gone' {
		$r = Invoke-Agent $script:Repo @('uninstall', 'y')
		$r.Code | Should -Be 0
		Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'abcheck.y' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
		Get-ScheduledTask -TaskPath $script:TaskPath -TaskName 'tray.abcheck.y' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
		Test-Path -LiteralPath $script:Y.App | Should -BeFalse
		@(Get-OnProfile).Count | Should -Be 0
	}
}
