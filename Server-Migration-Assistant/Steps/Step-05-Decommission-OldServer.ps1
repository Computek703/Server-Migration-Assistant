[CmdletBinding()]
param([switch]$Execute)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
. (Join-Path $projectRoot 'Modules\Common-Functions.ps1')
$paths = Initialize-ToolkitOutput -ProjectRoot $projectRoot
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $paths.Logs "Step-05-Decommission-OldServer_$stamp.log"
$reportFile = Join-Path $paths.Reports "$env:COMPUTERNAME-Step05-DecommissionPlan-$stamp.txt"

$checks = [ordered]@{
    'Post-cutover validation has no unresolved FAIL results' = $false
    'Application owners approved the cutover' = $false
    'Backups and rollback snapshot are verified' = $false
    'DNS, DHCP, shares, scheduled tasks, and service accounts were reviewed' = $false
    'Monitoring and documentation point to the new server' = $false
}

Write-Host 'STEP 05 - DECOMMISSION OLD SERVER' -ForegroundColor Cyan
Write-Host 'Default mode is audit-only. It does not stop services, remove roles, unjoin the domain, or delete data.' -ForegroundColor Yellow

$latestValidation = Get-ChildItem -LiteralPath $paths.Reports -Filter '*Step04-*.csv' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestValidation) {
    $validation = @(Import-Csv -LiteralPath $latestValidation.FullName)
    $checks['Post-cutover validation has no unresolved FAIL results'] = -not ($validation.Status -contains 'FAIL')
}

$inventory = @()
foreach ($name in @('DNS','DHCPServer','LanmanServer')) {
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($service) { $inventory += "${name}: Status=$($service.Status), StartType=$($service.StartType)" }
}
$shares = if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) { @(Get-SmbShare | Where-Object { -not $_.Special } | ForEach-Object { "$($_.Name) -> $($_.Path)" }) } else { @() }

$lines = @(
    "Decommission plan for $env:COMPUTERNAME",
    "Generated: $(Get-Date -Format s)",
    '', 'PRE-FLIGHT CHECKLIST'
)
foreach ($item in $checks.GetEnumerator()) { $lines += "[$(if ($item.Value) {'x'} else {' '})] $($item.Key)" }
$lines += '', 'CURRENT ROLE SERVICES', ($inventory | ForEach-Object { "- $_" })
$lines += '', 'CURRENT NON-SYSTEM SHARES', ($shares | ForEach-Object { "- $_" })
$lines += '', 'MANUAL DECOMMISSION SEQUENCE',
    '1. Resolve every failed validation and obtain stakeholder approval.',
    '2. Take and verify the final backup; document the rollback deadline.',
    '3. Remove or migrate role-specific authorization/configuration using vendor guidance.',
    '4. Disable workloads during an approved change window and monitor the replacement.',
    '5. Remove the server from monitoring, DNS, backups, and the domain only after the hold period.',
    '6. Sanitize or dispose of storage according to organizational policy.'
$lines | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-ToolkitLog -Level 'PASS' -Message "Saved audit and decommission plan: $reportFile" -LogFile $logFile

if ($Execute) {
    Write-ToolkitLog -Level 'WARN' -Message 'Execute mode requested, but destructive decommission actions are intentionally not automated.' -LogFile $logFile
    Write-Host 'Use the generated plan in an approved change window. Domain demotion, role removal, and data deletion require environment-specific procedures.' -ForegroundColor Yellow
}

Read-Host 'Press Enter to return to launcher'
