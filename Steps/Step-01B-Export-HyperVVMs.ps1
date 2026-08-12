[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
. (Join-Path $projectRoot 'Modules\Common-Functions.ps1')
$paths = Initialize-ToolkitOutput -ProjectRoot $projectRoot
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $paths.Logs "Step-01B-HyperV-Export-$stamp.log"

function Write-StepLog([string]$Level,[string]$Message) {
    Write-ToolkitLog -Level $Level -Message $Message -LogFile $logFile
}

Write-Host 'HYPER-V VM EXPORT - OLD SERVER CUTOVER' -ForegroundColor Cyan
if (-not (Test-ToolkitAdministrator)) { Write-StepLog FAIL 'Run this action as Administrator.'; return }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue) -or -not (Get-Command Export-VM -ErrorAction SilentlyContinue)) {
    Write-StepLog FAIL 'Hyper-V PowerShell cmdlets are unavailable on this server.'; return
}

$vms = @(Get-VM | Sort-Object Name)
if (-not $vms.Count) { Write-StepLog WARN 'No virtual machines were found.'; return }
$vms | Format-Table Name,State,Generation,Version,ProcessorCount -AutoSize
Write-Host 'Exports can be very large. Use storage with enough free space; a normal small flash drive is usually unsuitable.' -ForegroundColor Yellow
$destination = Read-Host 'Enter the full destination folder for VM exports (local disk, external disk, or accessible UNC path)'
if (-not [System.IO.Path]::IsPathRooted($destination)) { Write-StepLog FAIL 'A full rooted path is required.'; return }
if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
$destination = (Resolve-Path -LiteralPath $destination).Path

$selection = Read-Host 'Type ALL to export every VM, or enter exact VM names separated by commas'
$selected = if ($selection -ceq 'ALL') { $vms } else {
    $names = @($selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    @($vms | Where-Object { $_.Name -in $names })
}
if (-not $selected.Count) { Write-StepLog FAIL 'No matching VMs were selected.'; return }

Write-Host 'The selected VMs will be gracefully shut down and left OFF after export.' -ForegroundColor Red
$selected | Format-Table Name,State -AutoSize
$confirm = Read-Host "Type SHUTDOWN AND EXPORT $env:COMPUTERNAME to begin the outage, or CANCEL"
if ($confirm -cne "SHUTDOWN AND EXPORT $env:COMPUTERNAME") { Write-StepLog WARN 'VM export cancelled before any shutdown.'; return }

$receipts = @()
foreach ($vm in $selected) {
    try {
        if ($vm.State -ne 'Off') {
            Write-StepLog INFO "Requesting graceful shutdown of VM: $($vm.Name)"
            Stop-VM -VM $vm -Shutdown -ErrorAction Stop
            $deadline = (Get-Date).AddMinutes(10)
            do { Start-Sleep -Seconds 5; $vm = Get-VM -Id $vm.Id } until ($vm.State -eq 'Off' -or (Get-Date) -ge $deadline)
            if ($vm.State -ne 'Off') { throw 'Graceful shutdown did not finish within 10 minutes. The VM was not forced off.' }
        }
        Write-StepLog INFO "Exporting VM: $($vm.Name)"
        Export-VM -VM $vm -Path $destination -ErrorAction Stop
        $receipts += [PSCustomObject]@{ Name=$vm.Name; Id=[string]$vm.Id; Status='Exported'; Destination=$destination; ExportedAt=(Get-Date).ToString('o'); Error='' }
        Write-StepLog PASS "Exported and left off: $($vm.Name)"
    }
    catch {
        $receipts += [PSCustomObject]@{ Name=$vm.Name; Id=[string]$vm.Id; Status='Failed'; Destination=$destination; ExportedAt=(Get-Date).ToString('o'); Error=$_.Exception.Message }
        Write-StepLog FAIL "VM export failed for $($vm.Name): $($_.Exception.Message)"
    }
}

$receiptPath = Join-Path $paths.Exports "$env:COMPUTERNAME-HyperV-ExportReceipt-$stamp.json"
$receipts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-StepLog INFO "Export receipt: $receiptPath"
if (@($receipts | Where-Object Status -eq 'Failed').Count) {
    Write-StepLog FAIL 'One or more VM exports failed. Keep the old host available and do not continue cutover.'
} else {
    Write-StepLog PASS 'All selected VMs exported. Keep them off to prevent data divergence while completing import and validation.'
}
Read-Host 'Press Enter to return to the wizard'
