[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------
$ScriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot  = Split-Path -Parent $ScriptRoot
$OutputRoot   = Join-Path $ProjectRoot 'Output'
$ExportsRoot  = Join-Path $OutputRoot 'Exports'
$ReportsRoot  = Join-Path $OutputRoot 'Reports'
$LogsRoot     = Join-Path $OutputRoot 'Logs'

foreach ($folder in @($OutputRoot, $ExportsRoot, $ReportsRoot, $LogsRoot)) {
    if (-not (Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
}

$TimeStamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile      = Join-Path $LogsRoot "Step-03-MigrateSettings_$TimeStamp.log"
$ComputerName = $env:COMPUTERNAME
$BaseName     = "$ComputerName-Step03-$TimeStamp"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Write-Log {
    param(
        [ValidateSet('INFO','PASS','WARN','FAIL')]
        [string]$Level,
        [string]$Message
    )

    $color = switch ($Level) {
        'INFO' { 'White' }
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
    }

    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value "$(Get-Date -Format s) $line"
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value ""
    Add-Content -Path $LogFile -Value "===== $Title ====="
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-Result {
    param(
        [string]$Category,
        [string]$Action,
        [string]$Status,
        [string]$Details,
        [string]$Recommendation = ''
    )

    [PSCustomObject]@{
        Timestamp      = Get-Date
        ComputerName   = $ComputerName
        Category       = $Category
        Action         = $Action
        Status         = $Status
        Details        = $Details
        Recommendation = $Recommendation
    }
}

function Save-Results {
    param([array]$Results)

    $csvPath  = Join-Path $ReportsRoot "$BaseName-MigrationResults.csv"
    $jsonPath = Join-Path $ReportsRoot "$BaseName-MigrationResults.json"
    $txtPath  = Join-Path $ReportsRoot "$BaseName-MigrationSummary.txt"

    $Results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $Results | ConvertTo-Json -Depth 6 | Out-File -Path $jsonPath -Encoding UTF8
    $Results | Format-Table -AutoSize | Out-String | Out-File -FilePath $txtPath -Encoding UTF8

    Write-Log PASS "Saved: $csvPath"
    Write-Log PASS "Saved: $jsonPath"
    Write-Log PASS "Saved: $txtPath"
}

function Get-LatestExportFile {
    param(
        [Parameter(Mandatory)][string]$Pattern
    )

    Get-ChildItem -Path $ExportsRoot -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Import-DhcpConfigFromExport {
    param(
        [Parameter(Mandatory)][string]$DhcpExportPath
    )

    if (-not (Get-Command Import-DhcpServer -ErrorAction SilentlyContinue)) {
        throw "Import-DhcpServer cmdlet not available."
    }

    $backupPath = Join-Path $ReportsRoot "DHCP-Backup-$TimeStamp"
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
    }

    Import-DhcpServer -ComputerName $env:COMPUTERNAME -File $DhcpExportPath -Leases -BackupPath $backupPath -Force
}

function Set-DnsForwardersFromExport {
    param(
        [Parameter(Mandatory)][string]$ForwarderCsv
    )

    if (-not (Get-Command Set-DnsServerForwarder -ErrorAction SilentlyContinue)) {
        throw "DNS Server cmdlets not available."
    }

    $forwarders = Import-Csv $ForwarderCsv
    $ips = @()

    foreach ($fwd in $forwarders) {
        if ($fwd.IPAddress) {
            $ips += $fwd.IPAddress
        }
    }

    $ips = $ips | Where-Object { $_ } | Select-Object -Unique

    if (-not $ips) {
        throw "No forwarder IPs found in export."
    }

    Set-DnsServerForwarder -IPAddress $ips -PassThru | Out-Null
}

function New-SmbSharesFromExport {
    param(
        [Parameter(Mandatory)][string]$SharesCsv
    )

    if (-not (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) {
        throw "SMB Share cmdlets not available."
    }

    $shares = Import-Csv $SharesCsv

    foreach ($share in $shares) {
        if (-not $share.Name -or -not $share.Path) {
            Write-Log WARN "Skipping invalid share entry."
            continue
        }

        if (-not (Test-Path $share.Path)) {
            Write-Log WARN "Share path does not exist yet: $($share.Path)"
            continue
        }

        $existing = Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log WARN "Share already exists: $($share.Name)"
            continue
        }

        try {
            New-SmbShare -Name $share.Name -Path $share.Path -Description $share.Description | Out-Null
            Write-Log PASS "Created share: $($share.Name) -> $($share.Path)"
        }
        catch {
            Write-Log FAIL "Failed to create share $($share.Name): $($_.Exception.Message)"
        }
    }
}

function New-RobocopyScriptFromShares {
    param(
        [Parameter(Mandatory)][string]$SharesCsv,
        [Parameter(Mandatory)][string]$OldServerName
    )

    $shares = Import-Csv $SharesCsv
    $scriptPath = Join-Path $ReportsRoot "$BaseName-RobocopyCommands.cmd"
    $lines = @()

    $lines += "@echo off"
    $lines += "REM Generated Robocopy commands"
    $lines += "REM Review paths before running"
    $lines += ""

    foreach ($share in $shares) {
        if (-not $share.Name -or -not $share.Path) { continue }

        $source = "\\$OldServerName\$($share.Name)"
        $dest   = $share.Path
        $log    = Join-Path $ReportsRoot ("Robocopy-" + $share.Name + ".log")

        $line = 'robocopy "{0}" "{1}" /E /COPYALL /R:2 /W:2 /MT:16 /TEE /LOG+:"{2}"' -f $source, $dest, $log
        $lines += $line
    }

    $lines | Out-File -FilePath $scriptPath -Encoding ASCII
    return $scriptPath
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
Clear-Host
Write-Section 'STEP 03 - MIGRATE SETTINGS'
Write-Log INFO "Computer Name: $ComputerName"
Write-Log INFO "Exports Root : $ExportsRoot"
Write-Log INFO "Reports Root : $ReportsRoot"
Write-Log INFO "Log File     : $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log FAIL 'This script must be run as Administrator.'
    Read-Host 'Press Enter to continue'
    exit 1
}

$results = @()

Write-Section 'Migration Source Info'
$OldServerName = Read-Host 'Enter the OLD server name used for Robocopy/share references'
if (-not $OldServerName) {
    $OldServerName = 'OLD-SERVER'
    Write-Log WARN "No old server name entered. Using placeholder: $OldServerName"
}

# ------------------------------------------------------------
# 1. DHCP Import
# ------------------------------------------------------------
Write-Section 'DHCP Import'

try {
    $dhcpFile = Get-LatestExportFile -Pattern '*DHCP-Export.xml'

    if ($dhcpFile) {
        $doDhcpImport = Read-Host "Import DHCP from $($dhcpFile.Name)? (Y/N)"
        if ($doDhcpImport -match '^(Y|y)$') {
            Import-DhcpConfigFromExport -DhcpExportPath $dhcpFile.FullName
            $results += New-Result -Category 'DHCP' -Action 'Import DHCP Configuration' -Status 'PASS' -Details "Imported DHCP from $($dhcpFile.Name)"
        }
        else {
            $results += New-Result -Category 'DHCP' -Action 'Import DHCP Configuration' -Status 'INFO' -Details 'Skipped by technician.'
        }
    }
    else {
        $results += New-Result -Category 'DHCP' -Action 'Import DHCP Configuration' -Status 'WARN' -Details 'No DHCP export file found.' -Recommendation 'Run Step 1 on the old server first.'
    }
}
catch {
    $results += New-Result -Category 'DHCP' -Action 'Import DHCP Configuration' -Status 'FAIL' -Details $_.Exception.Message -Recommendation 'Review DHCP role, export file, and permissions.'
}

# ------------------------------------------------------------
# 2. DHCP Authorization
# ------------------------------------------------------------
Write-Section 'DHCP Authorization'

try {
    if (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue) {
        $authorized = Get-DhcpServerInDC | Where-Object { $_.DnsName -match "^$ComputerName(\.|$)" }

        if ($authorized) {
            $results += New-Result -Category 'DHCP' -Action 'DHCP Authorization Check' -Status 'PASS' -Details 'This server is authorized in AD for DHCP.'
        }
        else {
            $doAuthorize = Read-Host 'This server is not currently authorized for DHCP. Authorize it now? (Y/N)'
            if ($doAuthorize -match '^(Y|y)$') {
                $fqdn = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
                $ipv4 = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1 -ExpandProperty IPAddress)

                Add-DhcpServerInDC -DnsName $fqdn -IpAddress $ipv4
                $results += New-Result -Category 'DHCP' -Action 'DHCP Authorization Check' -Status 'PASS' -Details "Authorized DHCP server: $fqdn / $ipv4"
            }
            else {
                $results += New-Result -Category 'DHCP' -Action 'DHCP Authorization Check' -Status 'WARN' -Details 'DHCP authorization skipped.' -Recommendation 'Authorize DHCP before production use.'
            }
        }
    }
    else {
        $results += New-Result -Category 'DHCP' -Action 'DHCP Authorization Check' -Status 'WARN' -Details 'DHCP authorization cmdlets not available.'
    }
}
catch {
    $results += New-Result -Category 'DHCP' -Action 'DHCP Authorization Check' -Status 'FAIL' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 3. DNS Forwarders
# ------------------------------------------------------------
Write-Section 'DNS Forwarders'

try {
    $dnsForwarderFile = Get-LatestExportFile -Pattern '*DNS-Forwarders.csv'

    if ($dnsForwarderFile) {
        $doDnsForwarders = Read-Host "Apply DNS forwarders from $($dnsForwarderFile.Name)? (Y/N)"
        if ($doDnsForwarders -match '^(Y|y)$') {
            Set-DnsForwardersFromExport -ForwarderCsv $dnsForwarderFile.FullName
            $results += New-Result -Category 'DNS' -Action 'Apply DNS Forwarders' -Status 'PASS' -Details "Applied DNS forwarders from $($dnsForwarderFile.Name)"
        }
        else {
            $results += New-Result -Category 'DNS' -Action 'Apply DNS Forwarders' -Status 'INFO' -Details 'Skipped by technician.'
        }
    }
    else {
        $results += New-Result -Category 'DNS' -Action 'Apply DNS Forwarders' -Status 'WARN' -Details 'No DNS forwarder export file found.'
    }
}
catch {
    $results += New-Result -Category 'DNS' -Action 'Apply DNS Forwarders' -Status 'FAIL' -Details $_.Exception.Message -Recommendation 'Review DNS role installation and export contents.'
}

# ------------------------------------------------------------
# 4. SMB Share Recreation
# ------------------------------------------------------------
Write-Section 'SMB Share Recreation'

try {
    $sharesFile = Get-LatestExportFile -Pattern '*Shares.csv'

    if ($sharesFile) {
        $doCreateShares = Read-Host "Create SMB shares from $($sharesFile.Name)? (Y/N)"
        if ($doCreateShares -match '^(Y|y)$') {
            New-SmbSharesFromExport -SharesCsv $sharesFile.FullName
            $results += New-Result -Category 'File Services' -Action 'Create SMB Shares' -Status 'PASS' -Details "Processed share creation from $($sharesFile.Name)"
        }
        else {
            $results += New-Result -Category 'File Services' -Action 'Create SMB Shares' -Status 'INFO' -Details 'Skipped by technician.'
        }
    }
    else {
        $results += New-Result -Category 'File Services' -Action 'Create SMB Shares' -Status 'WARN' -Details 'No SMB share export file found.'
    }
}
catch {
    $results += New-Result -Category 'File Services' -Action 'Create SMB Shares' -Status 'FAIL' -Details $_.Exception.Message -Recommendation 'Review exported share paths and destination folders.'
}

# ------------------------------------------------------------
# 5. Generate Robocopy Script
# ------------------------------------------------------------
Write-Section 'Robocopy Command Generation'

try {
    $sharesFile = Get-LatestExportFile -Pattern '*Shares.csv'

    if ($sharesFile) {
        $doRobocopyScript = Read-Host "Generate Robocopy command file from $($sharesFile.Name)? (Y/N)"
        if ($doRobocopyScript -match '^(Y|y)$') {
            $robocopyScript = New-RobocopyScriptFromShares -SharesCsv $sharesFile.FullName -OldServerName $OldServerName
            $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'PASS' -Details "Created Robocopy script: $(Split-Path $robocopyScript -Leaf)"
            Write-Log PASS "Robocopy script created: $robocopyScript"
        }
        else {
            $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'INFO' -Details 'Skipped by technician.'
        }
    }
    else {
        $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'WARN' -Details 'No SMB share export file found.'
    }
}
catch {
    $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'FAIL' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 6. Notes / Manual Items
# ------------------------------------------------------------
Write-Section 'Manual Follow-Up Items'

$results += New-Result -Category 'Manual' -Action 'AD-Integrated DNS Zones' -Status 'INFO' -Details 'Validate DNS zone replication manually. Do not blindly import AD-integrated zones.'
$results += New-Result -Category 'Manual' -Action 'Certificates' -Status 'INFO' -Details 'Import certificates manually if required for RDP, IIS, VPN, apps, or services.'
$results += New-Result -Category 'Manual' -Action 'Printers / Drivers' -Status 'INFO' -Details 'Rebuild or migrate printer configuration separately.'
$results += New-Result -Category 'Manual' -Action 'Applications / Services' -Status 'INFO' -Details 'Validate application configs, service accounts, and dependencies manually.'

# ------------------------------------------------------------
# Summary / Output
# ------------------------------------------------------------
Write-Section 'Migration Results'

foreach ($item in $results) {
    $color = switch ($item.Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'White' }
        default { 'White' }
    }

    Write-Host ("[{0}] {1} / {2} - {3}" -f $item.Status, $item.Category, $item.Action, $item.Details) -ForegroundColor $color
}

Write-Section 'Summary Totals'
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("{0}: {1}" -f $_.Name, $_.Count)
}

Save-Results -Results $results

Write-Section 'Step 3 Complete'
Write-Log INFO 'Review WARN and FAIL items before continuing.'
Write-Log INFO "Migration reports saved under: $ReportsRoot"

Read-Host 'Press Enter to return to launcher'
