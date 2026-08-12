Set-StrictMode -Version 2.0

function Initialize-ToolkitOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $output = Join-Path $ProjectRoot 'Output'
    $paths = [ordered]@{
        Output  = $output
        Exports = Join-Path $output 'Exports'
        Reports = Join-Path $output 'Reports'
        Logs    = Join-Path $output 'Logs'
    }
    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    [PSCustomObject]$paths
}

function Test-ToolkitAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-ToolkitLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','PASS','WARN','FAIL')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$LogFile
    )
    $colors = @{ INFO='White'; PASS='Green'; WARN='Yellow'; FAIL='Red' }
    $line = '[{0}] {1}' -f $Level, $Message
    Write-Host $line -ForegroundColor $colors[$Level]
    Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format s), $line)
}

function Confirm-ToolkitPhrase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Phrase
    )
    (Read-Host "$Prompt Type '$Phrase' to continue") -ceq $Phrase
}
