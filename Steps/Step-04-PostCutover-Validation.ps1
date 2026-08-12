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
}

try {
    $recentErrors = @(Get-WinEvent -FilterHashtable @{LogName=@('System','Application');Level=1,2;StartTime=(Get-Date).AddHours(-24)} -MaxEvents 100 -ErrorAction Stop)
    Add-Check 'Event Logs' 'Critical/errors (24h)' $(if ($recentErrors.Count) {'WARN'} else {'PASS'}) "$($recentErrors.Count) event(s), capped at 100"
} catch { Add-Check 'Event Logs' 'Critical/errors (24h)' 'WARN' $_.Exception.Message }

$results | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-ToolkitLog -Level 'INFO' -Message "Complete: $($counts -join '; '). Report: $reportFile" -LogFile $logFile
Read-Host 'Press Enter to return to launcher'
