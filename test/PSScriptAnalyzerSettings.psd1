# PSScriptAnalyzer settings for the Windows host agent (host-agent.ps1, tray.ps1)
# and its Pester suite:
#   Invoke-ScriptAnalyzer -Path <file> -Settings test/PSScriptAnalyzerSettings.psd1
# Syntax must hold on Windows PowerShell 5.1 (what Windows ships) and pwsh 7.4+.
# Excluded: rules written for published cmdlets, not for a script's own helpers
# — plural nouns, ShouldProcess, positional calls between them — and
# Write-Host, which a test uses to show where it waits.
@{
	ExcludeRules = @(
		'PSUseSingularNouns'
		'PSUseShouldProcessForStateChangingFunctions'
		'PSAvoidUsingPositionalParameters'
		'PSAvoidUsingWriteHost'
	)
	Rules = @{
		PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.4') }
	}
}
