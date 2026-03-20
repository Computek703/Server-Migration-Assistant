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

$TimeStamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile     = Join-Path $LogsRoot "Step-01-Export-OldServer_$TimeStamp.log"
$ComputerName = $env:COMPUTERNAME
$BaseName     = "$ComputerName-Step01-$TimeStamp"

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

function Save-ObjectCsv {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $InputObject | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        Write-Log PASS "Saved: $Path"
    }
    catch {
        Write-Log FAIL "Failed to save CSV: $Path - $($_.Exception.Message)"
    }
}

function Save-ObjectTxt {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $InputObject | Out-File -FilePath $Path -Encoding UTF8 -Width 300
        Write-Log PASS "Saved: $Path"
    }
    catch {
        Write-Log FAIL "Failed to save TXT: $Path - $($_.Exception.Message)"
    }
}

function Invoke-SafeExport {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        Write-Log INFO "Starting export: $Name"
        & $ScriptBlock
        Write-Log PASS "Completed export: $Name"
    }
    catch {
        Write-Log FAIL "$Name failed: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
Clear-Host
Write-Section "STEP 01 - EXPORT OLD SERVER"
Write-Log INFO "Computer Name: $ComputerName"
Write-Log INFO "Exports Root : $ExportsRoot"
Write-Log INFO "Reports Root : $ReportsRoot"
Write-Log INFO "Log File     : $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log FAIL "This script must be run as Administrator."
    Read-Host "Press Enter to continue"
    exit 1
}

# ------------------------------------------------------------
# 1. System Summary
# ------------------------------------------------------------
Invoke-SafeExport -Name 'System Summary' -ScriptBlock {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS

    $summary = [PSCustomObject]@{
        ComputerName   = $env:COMPUTERNAME
        Manufacturer   = $cs.Manufacturer
        Model          = $cs.Model
        Domain         = $cs.Domain
        PartOfDomain   = $cs.PartOfDomain
        OSName         = $os.Caption
        OSVersion      = $os.Version
        BuildNumber    = $os.BuildNumber
        LastBoot       = $os.LastBootUpTime
        RAMGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        BIOSVersion    = ($bios.SMBIOSBIOSVersion -join ', ')
        SerialNumber   = $bios.SerialNumber
    }

    $txtPath = Join-Path $ReportsRoot "$BaseName-SystemSummary.txt"
    $csvPath = Join-Path $ReportsRoot "$BaseName-SystemSummary.csv"

    $summary | Format-List | Out-File -FilePath $txtPath -Encoding UTF8
    $summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Log PASS "Saved: $txtPath"
    Write-Log PASS "Saved: $csvPath"
}

# ------------------------------------------------------------
# 2. Network Configuration
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Network Configuration' -ScriptBlock {
    $netCfg = Get-NetIPConfiguration
    $csvPath = Join-Path $ExportsRoot "$BaseName-NetworkConfig.csv"
    $txtPath = Join-Path $ReportsRoot "$BaseName-ipconfig-all.txt"

    $netCfg | Select-Object InterfaceAlias, InterfaceDescription, IPv4Address, IPv4DefaultGateway, DNSServer, NetAdapter |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    ipconfig /all | Out-File -FilePath $txtPath -Encoding UTF8

    Write-Log PASS "Saved: $csvPath"
    Write-Log PASS "Saved: $txtPath"
}

# ------------------------------------------------------------
# 3. Installed Roles / Features
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Installed Roles and Features' -ScriptBlock {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $roles = Get-WindowsFeature | Where-Object { $_.InstallState -eq 'Installed' }
        $csvPath = Join-Path $ExportsRoot "$BaseName-InstalledRoles.csv"
        Save-ObjectCsv -InputObject $roles -Path $csvPath
    }
    else {
        Write-Log WARN 'Get-WindowsFeature not available on this system.'
    }
}

# ------------------------------------------------------------
# 4. Installed Programs
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Installed Programs' -ScriptBlock {
    $programs = @(
        Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        Get-ItemProperty 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    ) | Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Sort-Object DisplayName -Unique

    $csvPath = Join-Path $ExportsRoot "$BaseName-InstalledPrograms.csv"
    Save-ObjectCsv -InputObject $programs -Path $csvPath
}

# ------------------------------------------------------------
# 5. Services
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Services' -ScriptBlock {
    $services = Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, State, StartMode, StartName, PathName

    $csvPath = Join-Path $ExportsRoot "$BaseName-Services.csv"
    Save-ObjectCsv -InputObject $services -Path $csvPath
}

# ------------------------------------------------------------
# 6. Shared Folders
# ------------------------------------------------------------
Invoke-SafeExport -Name 'SMB Shares' -ScriptBlock {
    if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
        $shares = Get-SmbShare | Where-Object { -not $_.Special } |
            Select-Object Name, Path, Description, FolderEnumerationMode, CachingMode, ConcurrentUserLimit

        $csvPath = Join-Path $ExportsRoot "$BaseName-Shares.csv"
        Save-ObjectCsv -InputObject $shares -Path $csvPath
    }
    else {
        Write-Log WARN 'Get-SmbShare not available.'
    }
}

# ------------------------------------------------------------
# 7. Local Administrators / Groups
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Local Groups and Admins' -ScriptBlock {
    if (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue) {
        $groupsPath = Join-Path $ExportsRoot "$BaseName-LocalGroups.csv"
        $adminsPath = Join-Path $ExportsRoot "$BaseName-LocalAdministrators.csv"

        $groups = Get-LocalGroup | Select-Object Name, Description
        Save-ObjectCsv -InputObject $groups -Path $groupsPath

        try {
            $admins = Get-LocalGroupMember -Group 'Administrators' |
                Select-Object Name, ObjectClass, PrincipalSource
            Save-ObjectCsv -InputObject $admins -Path $adminsPath
        }
        catch {
            Write-Log WARN "Could not read local Administrators group: $($_.Exception.Message)"
        }
    }
    else {
        Write-Log WARN 'LocalAccounts module not available.'
    }
}

# ------------------------------------------------------------
# 8. Scheduled Tasks
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Scheduled Tasks' -ScriptBlock {
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $tasks = Get-ScheduledTask |
            Select-Object TaskName, TaskPath, State, Author, Description

        $csvPath = Join-Path $ExportsRoot "$BaseName-ScheduledTasks.csv"
        Save-ObjectCsv -InputObject $tasks -Path $csvPath
    }
    else {
        Write-Log WARN 'Get-ScheduledTask not available.'
    }
}

# ------------------------------------------------------------
# 9. Printers
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Printers' -ScriptBlock {
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        $printers = Get-Printer |
            Select-Object Name, DriverName, PortName, Shared, ShareName, Type, ComputerName

        $csvPath = Join-Path $ExportsRoot "$BaseName-Printers.csv"
        Save-ObjectCsv -InputObject $printers -Path $csvPath
    }
    else {
        Write-Log WARN 'Get-Printer not available.'
    }
}

# ------------------------------------------------------------
# 10. DNS Inventory
# ------------------------------------------------------------
Invoke-SafeExport -Name 'DNS Inventory' -ScriptBlock {
    if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
        $zonesPath = Join-Path $ExportsRoot "$BaseName-DNS-Zones.csv"
        $fwdPath   = Join-Path $ExportsRoot "$BaseName-DNS-Forwarders.csv"

        $zones = Get-DnsServerZone |
            Select-Object ZoneName, ZoneType, IsDsIntegrated, ReplicationScope, DynamicUpdate, IsReverseLookupZone
        Save-ObjectCsv -InputObject $zones -Path $zonesPath

        if (Get-Command Get-DnsServerForwarder -ErrorAction SilentlyContinue) {
            $forwarders = Get-DnsServerForwarder |
                Select-Object IPAddress, Timeout, UseRootHint
            Save-ObjectCsv -InputObject $forwarders -Path $fwdPath
        }
    }
    else {
        Write-Log WARN 'DNS Server module not available.'
    }
}

# ------------------------------------------------------------
# 11. DHCP Export
# ------------------------------------------------------------
Invoke-SafeExport -Name 'DHCP Export' -ScriptBlock {
    if (Get-Command Export-DhcpServer -ErrorAction SilentlyContinue) {
        $dhcpPath = Join-Path $ExportsRoot "$BaseName-DHCP-Export.xml"
        Export-DhcpServer -ComputerName $env:COMPUTERNAME -File $dhcpPath -Leases -Force
        Write-Log PASS "Saved: $dhcpPath"
    }
    else {
        Write-Log WARN 'Export-DhcpServer not available.'
    }
}

# ------------------------------------------------------------
# 12. NTFS Permissions
# ------------------------------------------------------------
Write-Section 'NTFS Permission Export'
$pathsInput = Read-Host 'Enter folders to export NTFS permissions for, separated by commas (or leave blank to skip)'

if ($pathsInput) {
    $paths = $pathsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($path in $paths) {
        if (Test-Path $path) {
            $safeName = ($path -replace '[:\\\/ ]','_')
            $permPath = Join-Path $ExportsRoot "$BaseName-NTFS-$safeName.txt"

            try {
                icacls $path /save $permPath /t /c | Out-Null
                Write-Log PASS "Saved NTFS permissions: $permPath"
            }
            catch {
                Write-Log FAIL "Failed NTFS export for $path - $($_.Exception.Message)"
            }
        }
        else {
            Write-Log WARN "Path not found: $path"
        }
    }
}
else {
    Write-Log INFO 'NTFS permission export skipped.'
}

# ------------------------------------------------------------
# 13. Event Logs Summary
# ------------------------------------------------------------
Invoke-SafeExport -Name 'System and Application Error Events' -ScriptBlock {
    $since = (Get-Date).AddDays(-7)

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = @('System','Application')
        Level     = 1,2,3
        StartTime = $since
    } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LogName, Id, LevelDisplayName, ProviderName, Message

    $csvPath = Join-Path $ReportsRoot "$BaseName-RecentEvents.csv"
    Save-ObjectCsv -InputObject $events -Path $csvPath
}

# ------------------------------------------------------------
# 14. Extra command outputs
# ------------------------------------------------------------
Invoke-SafeExport -Name 'Extra Command Outputs' -ScriptBlock {
    systeminfo | Out-File -FilePath (Join-Path $ReportsRoot "$BaseName-systeminfo.txt") -Encoding UTF8
    hostname   | Out-File -FilePath (Join-Path $ReportsRoot "$BaseName-hostname.txt") -Encoding UTF8
    route print | Out-File -FilePath (Join-Path $ReportsRoot "$BaseName-routeprint.txt") -Encoding UTF8
    net share   | Out-File -FilePath (Join-Path $ReportsRoot "$BaseName-netshare.txt") -Encoding UTF8
    Write-Log PASS 'Saved extra text command outputs.'
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
Write-Section 'STEP 01 COMPLETE'
Write-Log PASS 'Old server export stage completed.'
Write-Log INFO "Review files under: $OutputRoot"
Write-Log INFO 'These exports can now be used to build/import on the new server.'

Read-Host 'Press Enter to return to launcher'
