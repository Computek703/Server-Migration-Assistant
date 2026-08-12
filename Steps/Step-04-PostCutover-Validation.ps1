[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
. (Join-Path $projectRoot 'Modules\Common-Functions.ps1')
$paths = Initialize-ToolkitOutput -ProjectRoot $projectRoot
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $paths.Logs "Step-04-PostCutover-Validation_$stamp.log"
$reportFile = Join-Path $paths.Reports "$env:COMPUTERNAME-Step04-$stamp.csv"
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Category,[string]$Check,[string]$Status,[string]$Details) {
    $results.Add([PSCustomObject]@{ Timestamp=Get-Date; ComputerName=$env:COMPUTERNAME; Category=$Category; Check=$Check; Status=$Status; Details=$Details })
    Write-ToolkitLog -Level $Status -Message "$Category / $Check - $Details" -LogFile $logFile
}

Write-Host 'STEP 04 - POST-CUTOVER VALIDATION' -ForegroundColor Cyan
$validationConfirmation = Read-Host "Type VALIDATE to check the replacement server $env:COMPUTERNAME"
if ($validationConfirmation -cne 'VALIDATE') {
    Write-ToolkitLog -Level 'WARN' -Message 'Post-cutover validation cancelled by technician.' -LogFile $logFile
    return
}

$manifestFile = Get-ChildItem -LiteralPath $paths.Exports -Filter '*MigrationManifest.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$manifest = $null
if ($manifestFile) {
    try {
        $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
        Add-Check 'Migration Package' 'Target name' $(if ($manifest.SourceComputer -ine $env:COMPUTERNAME) {'PASS'} else {'FAIL'}) "Source=$($manifest.SourceComputer); Target=$env:COMPUTERNAME"
    }
    catch { Add-Check 'Migration Package' 'Manifest' 'FAIL' $_.Exception.Message }
}
else { Add-Check 'Migration Package' 'Manifest' 'FAIL' 'No Step 1 migration manifest found.' }

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Add-Check 'System' 'Operating system' 'PASS' "$($os.Caption), build $($os.BuildNumber)"
} catch { Add-Check 'System' 'Operating system' 'FAIL' $_.Exception.Message }

try {
    $adapters = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object IPv4Address)
    if ($adapters.Count) { Add-Check 'Network' 'IPv4 adapters' 'PASS' "$($adapters.Count) configured adapter(s)" }
    else { Add-Check 'Network' 'IPv4 adapters' 'FAIL' 'No configured IPv4 adapter found.' }
    foreach ($adapter in $adapters) {
        $dns = @($adapter.DnsServer.ServerAddresses)
        $gateway = @($adapter.IPv4DefaultGateway.NextHop)
        $status = if ($dns.Count -and $gateway.Count) { 'PASS' } else { 'WARN' }
        Add-Check 'Network' $adapter.InterfaceAlias $status "IP=$($adapter.IPv4Address.IPAddress -join ', '); Gateway=$($gateway -join ', '); DNS=$($dns -join ', ')"
    }
} catch { Add-Check 'Network' 'Configuration' 'FAIL' $_.Exception.Message }

foreach ($target in @('localhost')) {
    try {
        $ok = Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction Stop
        Add-Check 'Connectivity' $target $(if ($ok) {'PASS'} else {'FAIL'}) $(if ($ok) {'Reachable'} else {'Not reachable'})
    } catch { Add-Check 'Connectivity' $target 'FAIL' $_.Exception.Message }
}

$serviceMap = [ordered]@{ DNS='DNS'; DHCP='DHCPServer'; FileServer='LanmanServer'; Time='W32Time' }
foreach ($entry in $serviceMap.GetEnumerator()) {
    $service = Get-Service -Name $entry.Value -ErrorAction SilentlyContinue
    if (-not $service) { Add-Check 'Services' $entry.Key 'WARN' 'Role service is not installed.'; continue }
    Add-Check 'Services' $entry.Key $(if ($service.Status -eq 'Running') {'PASS'} else {'FAIL'}) "Status=$($service.Status); StartType=$($service.StartType)"
}

if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
    $shares = @(Get-SmbShare | Where-Object { -not $_.Special })
    foreach ($share in $shares) {
        Add-Check 'File Services' $share.Name $(if (Test-Path -LiteralPath $share.Path) {'PASS'} else {'FAIL'}) "Path=$($share.Path)"
    }
    if (-not $shares.Count) { Add-Check 'File Services' 'SMB shares' 'WARN' 'No non-system shares found.' }
    if ($manifest) {
        foreach ($expected in @($manifest.Shares)) {
            $actual = $shares | Where-Object Name -eq $expected.Name | Select-Object -First 1
            if (-not $actual) { Add-Check 'File Services' "Expected share $($expected.Name)" 'FAIL' 'Share is missing.'; continue }
            Add-Check 'File Services' "Expected share $($expected.Name) path" $(if ($actual.Path -eq $expected.Path) {'PASS'} else {'FAIL'}) "Expected=$($expected.Path); Actual=$($actual.Path)"
        }
    }
}

if ($manifest -and (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    $actualFeatures = @(Get-WindowsFeature | Where-Object InstallState -eq 'Installed' | Select-Object -ExpandProperty Name)
    $optionalFeaturePatterns = @('^RSAT','^GPMC$','^PowerShell-ISE$','-Tools$','-PowerShell$')
    foreach ($feature in @($manifest.InstalledFeatures)) {
        $installed = $actualFeatures -contains $feature
        $optional = [bool]($optionalFeaturePatterns | Where-Object { $feature -match $_ })
        $status = if ($installed) { 'PASS' } elseif ($optional) { 'WARN' } else { 'FAIL' }
        $details = if ($installed) { 'Installed' } elseif ($optional) { 'Optional management tool is missing' } else { 'Required runtime role/feature is missing from replacement server' }
        Add-Check 'Roles' $feature $status $details
    }
}

try {
    $recentErrors = @(Get-WinEvent -FilterHashtable @{LogName=@('System','Application');Level=1,2;StartTime=(Get-Date).AddHours(-24)} -MaxEvents 100 -ErrorAction Stop)
    Add-Check 'Event Logs' 'Critical/errors (24h)' $(if ($recentErrors.Count) {'WARN'} else {'PASS'}) "$($recentErrors.Count) event(s), capped at 100"
} catch { Add-Check 'Event Logs' 'Critical/errors (24h)' 'WARN' $_.Exception.Message }

$results | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-ToolkitLog -Level 'INFO' -Message "Complete: $($counts -join '; '). Report: $reportFile" -LogFile $logFile
Read-Host 'Press Enter to return to launcher'
