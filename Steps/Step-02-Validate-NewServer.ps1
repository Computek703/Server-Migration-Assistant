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
$LogFile      = Join-Path $LogsRoot "Step-02-Validate-NewServer_$TimeStamp.log"
$ComputerName = $env:COMPUTERNAME
$BaseName     = "$ComputerName-Step02-$TimeStamp"

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
        [string]$Check,
        [string]$Status,
        [string]$Details,
        [string]$Recommendation = ''
    )

    [PSCustomObject]@{
        Timestamp      = Get-Date
        ComputerName   = $ComputerName
        Category       = $Category
        Check          = $Check
        Status         = $Status
        Details        = $Details
        Recommendation = $Recommendation
    }
}

function Save-Results {
    param([array]$Results)

    $csvPath = Join-Path $ReportsRoot "$BaseName-ValidationResults.csv"
    $jsonPath = Join-Path $ReportsRoot "$BaseName-ValidationResults.json"
    $txtPath = Join-Path $ReportsRoot "$BaseName-ValidationSummary.txt"

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

function Get-PendingUpdateCount {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Software'")
        return $result.Updates.Count
    }
    catch {
        return $null
    }
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
Clear-Host
Write-Section 'STEP 02 - VALIDATE NEW SERVER READINESS'
Write-Log INFO "Computer Name: $ComputerName"
Write-Log INFO "Reports Root : $ReportsRoot"
Write-Log INFO "Log File     : $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log FAIL 'This script must be run as Administrator.'
    Read-Host 'Press Enter to continue'
    exit 1
}

$results = @()

# ------------------------------------------------------------
# 1. Basic OS / Name
# ------------------------------------------------------------
Write-Section 'Basic System Checks'

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem

    $results += New-Result -Category 'System' -Check 'Computer Name' -Status 'PASS' -Details $ComputerName
    $results += New-Result -Category 'System' -Check 'Operating System' -Status 'PASS' -Details "$($os.Caption) | Version $($os.Version) | Build $($os.BuildNumber)"
}
catch {
    $results += New-Result -Category 'System' -Check 'Operating System' -Status 'FAIL' -Details $_.Exception.Message -Recommendation 'Verify WMI/CIM is healthy.'
}

# ------------------------------------------------------------
# 2. Windows Activation
# ------------------------------------------------------------
Write-Section 'Windows Activation'

try {
    $license = Get-CimInstance SoftwareLicensingProduct |
        Where-Object { $_.PartialProductKey -and $_.Name -match 'Windows' } |
        Select-Object -First 1

    if ($license -and $license.LicenseStatus -eq 1) {
        $results += New-Result -Category 'Licensing' -Check 'Windows Activation' -Status 'PASS' -Details 'Windows is activated.'
    }
    elseif ($license) {
        $results += New-Result -Category 'Licensing' -Check 'Windows Activation' -Status 'WARN' -Details "License status code: $($license.LicenseStatus)" -Recommendation 'Activate Windows before production cutover.'
    }
    else {
        $results += New-Result -Category 'Licensing' -Check 'Windows Activation' -Status 'WARN' -Details 'Unable to determine activation state.' -Recommendation 'Validate activation manually.'
    }
}
catch {
    $results += New-Result -Category 'Licensing' -Check 'Windows Activation' -Status 'WARN' -Details $_.Exception.Message -Recommendation 'Validate activation manually.'
}

# ------------------------------------------------------------
# 3. Windows Updates
# ------------------------------------------------------------
Write-Section 'Windows Updates'

try {
    $pendingCount = Get-PendingUpdateCount

    if ($null -eq $pendingCount) {
        $results += New-Result -Category 'Updates' -Check 'Pending Updates' -Status 'WARN' -Details 'Unable to query Windows Update status.' -Recommendation 'Check Windows Update manually.'
    }
    elseif ($pendingCount -eq 0) {
        $results += New-Result -Category 'Updates' -Check 'Pending Updates' -Status 'PASS' -Details 'No pending software updates detected.'
    }
    else {
        $results += New-Result -Category 'Updates' -Check 'Pending Updates' -Status 'WARN' -Details "$pendingCount pending software update(s) detected." -Recommendation 'Install updates and reboot before migration.'
    }
}
catch {
    $results += New-Result -Category 'Updates' -Check 'Pending Updates' -Status 'WARN' -Details $_.Exception.Message -Recommendation 'Check Windows Update manually.'
}

# ------------------------------------------------------------
# 4. Network / Static IP / DNS
# ------------------------------------------------------------
Write-Section 'Network Configuration'

try {
    $adapters = Get-NetIPConfiguration | Where-Object { $_.IPv4Address }

    if (-not $adapters) {
        $results += New-Result -Category 'Network' -Check 'IPv4 Adapters' -Status 'FAIL' -Details 'No active IPv4 adapters found.' -Recommendation 'Verify NIC configuration.'
    }
    else {
        foreach ($adapter in $adapters) {
            $ipv4Info = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $dnsInfo  = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

            $hasStatic = ($ipv4Info.PrefixOrigin -contains 'Manual')
            $hasDns    = [bool]($dnsInfo.ServerAddresses)

            $status = if ($hasStatic -and $hasDns) { 'PASS' } else { 'WARN' }
            $detail = "Adapter=$($adapter.InterfaceAlias) | IP=$($adapter.IPv4Address.IPAddress -join ', ') | GW=$($adapter.IPv4DefaultGateway.NextHop -join ', ') | DNS=$($dnsInfo.ServerAddresses -join ', ')"
            $rec    = if ($status -eq 'WARN') { 'Set static IP, subnet, gateway, and DNS correctly before cutover.' } else { '' }

            $results += New-Result -Category 'Network' -Check "Adapter $($adapter.InterfaceAlias)" -Status $status -Details $detail -Recommendation $rec
        }
    }
}
catch {
    $results += New-Result -Category 'Network' -Check 'IPv4 Configuration' -Status 'FAIL' -Details $_.Exception.Message -Recommendation 'Verify adapter configuration manually.'
}

# ------------------------------------------------------------
# 5. Domain Join / DC Reachability
# ------------------------------------------------------------
Write-Section 'Domain Checks'

try {
    $cs = Get-CimInstance Win32_ComputerSystem

    if ($cs.PartOfDomain) {
        $results += New-Result -Category 'Identity' -Check 'Domain Membership' -Status 'PASS' -Details "Joined to domain: $($cs.Domain)"

        try {
            $dc = nltest /dsgetdc:$($cs.Domain) 2>&1
            if ($LASTEXITCODE -eq 0) {
                $results += New-Result -Category 'Identity' -Check 'Domain Controller Reachability' -Status 'PASS' -Details (($dc | Out-String).Trim())
            }
            else {
                $results += New-Result -Category 'Identity' -Check 'Domain Controller Reachability' -Status 'FAIL' -Details (($dc | Out-String).Trim()) -Recommendation 'Check DNS and domain connectivity.'
            }
        }
        catch {
            $results += New-Result -Category 'Identity' -Check 'Domain Controller Reachability' -Status 'WARN' -Details 'Unable to run nltest.' -Recommendation 'Validate secure channel and DC reachability manually.'
        }
    }
    else {
        $results += New-Result -Category 'Identity' -Check 'Domain Membership' -Status 'WARN' -Details 'Server is not domain joined.' -Recommendation 'Join the domain before migration if required.'
    }
}
catch {
    $results += New-Result -Category 'Identity' -Check 'Domain Membership' -Status 'FAIL' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 6. Time Service
# ------------------------------------------------------------
Write-Section 'Time Service'

try {
    $svc = Get-Service W32Time -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $results += New-Result -Category 'Time' -Check 'Windows Time Service' -Status 'PASS' -Details 'W32Time is running.'
    }
    else {
        $results += New-Result -Category 'Time' -Check 'Windows Time Service' -Status 'WARN' -Details 'W32Time is not running.' -Recommendation 'Start and sync time service before cutover.'
    }

    $w32 = w32tm /query /status 2>&1
    $results += New-Result -Category 'Time' -Check 'Time Query' -Status 'PASS' -Details (($w32 | Out-String).Trim())
}
catch {
    $results += New-Result -Category 'Time' -Check 'Time Service' -Status 'WARN' -Details $_.Exception.Message -Recommendation 'Validate NTP/time sync manually.'
}

# ------------------------------------------------------------
# 7. Disk Space
# ------------------------------------------------------------
Write-Section 'Storage'

try {
    $volumes = Get-Volume | Where-Object { $_.DriveLetter }
    foreach ($volume in $volumes) {
        $freePct = if ($volume.Size -gt 0) { [math]::Round(($volume.SizeRemaining / $volume.Size) * 100,2) } else { 0 }
        $status = if ($freePct -ge 15) { 'PASS' } else { 'WARN' }
        $results += New-Result -Category 'Storage' -Check "Drive $($volume.DriveLetter)" -Status $status -Details "Free $([math]::Round($volume.SizeRemaining/1GB,2)) GB of $([math]::Round($volume.Size/1GB,2)) GB ($freePct`%)" -Recommendation 'Ensure enough free space exists for data copy, logs, and rollback.'
    }
}
catch {
    $results += New-Result -Category 'Storage' -Check 'Disk Free Space' -Status 'FAIL' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 8. Installed Roles / Compare to Step 1 Export
# ------------------------------------------------------------
Write-Section 'Roles and Features'

try {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $installedRoles = Get-WindowsFeature | Where-Object { $_.InstallState -eq 'Installed' }

        $results += New-Result -Category 'Roles' -Check 'Role Enumeration' -Status 'PASS' -Details "Installed roles/features found: $($installedRoles.Count)"

        $oldRolesFile = Get-LatestExportFile -Pattern '*InstalledRoles.csv'
        if ($oldRolesFile) {
            $oldRoles = Import-Csv $oldRolesFile.FullName
            $oldRoleNames = $oldRoles.Name | Where-Object { $_ } | Sort-Object -Unique
            $newRoleNames = $installedRoles.Name | Where-Object { $_ } | Sort-Object -Unique

            $missingRoles = $oldRoleNames | Where-Object { $_ -notin $newRoleNames }

            if (-not $missingRoles) {
                $results += New-Result -Category 'Roles' -Check 'Role Comparison' -Status 'PASS' -Details "New server matches roles from export file: $($oldRolesFile.Name)"
            }
            else {
                $results += New-Result -Category 'Roles' -Check 'Role Comparison' -Status 'WARN' -Details ("Missing roles/features: " + ($missingRoles -join ', ')) -Recommendation 'Install required roles/features before migration.'
            }
        }
        else {
            $results += New-Result -Category 'Roles' -Check 'Role Comparison' -Status 'WARN' -Details 'No Step 1 InstalledRoles export file found.' -Recommendation 'Run Step 1 on the old server first or compare manually.'
        }
    }
    else {
        $results += New-Result -Category 'Roles' -Check 'Role Enumeration' -Status 'WARN' -Details 'Get-WindowsFeature not available.' -Recommendation 'Install ServerManager module or validate roles manually.'
    }
}
catch {
    $results += New-Result -Category 'Roles' -Check 'Role Comparison' -Status 'FAIL' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 9. Critical Services
# ------------------------------------------------------------
Write-Section 'Critical Services'

$serviceNames = @('LanmanServer','W32Time','DNS','DHCPServer','NTDS')

foreach ($svcName in $serviceNames) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $status = if ($svc.Status -eq 'Running') { 'PASS' } else { 'WARN' }
            $results += New-Result -Category 'Services' -Check $svcName -Status $status -Details "Status=$($svc.Status)" -Recommendation 'Review service state if this role is required.'
        }
    }
    catch {
        $results += New-Result -Category 'Services' -Check $svcName -Status 'WARN' -Details $_.Exception.Message
    }
}

# ------------------------------------------------------------
# 10. Step 1 Export Files Present
# ------------------------------------------------------------
Write-Section 'Old Server Export Files'

$requiredExportPatterns = @(
    '*SystemSummary.csv',
    '*NetworkConfig.csv',
    '*InstalledPrograms.csv',
    '*Services.csv'
)

foreach ($pattern in $requiredExportPatterns) {
    $file = Get-LatestExportFile -Pattern $pattern
    if ($file) {
        $results += New-Result -Category 'Exports' -Check $pattern -Status 'PASS' -Details "Found export file: $($file.Name)"
    }
    else {
        $results += New-Result -Category 'Exports' -Check $pattern -Status 'WARN' -Details "Missing export file matching: $pattern" -Recommendation 'Run Step 1 on the old server and save exports to this USB first.'
    }
}

# ------------------------------------------------------------
# 11. Recent reboot / pending reboot hints
# ------------------------------------------------------------
Write-Section 'Reboot Status'

try {
    $pendingReboot = $false

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pendingReboot = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pendingReboot = $true }

    if ($pendingReboot) {
        $results += New-Result -Category 'System' -Check 'Pending Reboot' -Status 'WARN' -Details 'A pending reboot was detected.' -Recommendation 'Reboot and rerun validation before migration.'
    }
    else {
        $results += New-Result -Category 'System' -Check 'Pending Reboot' -Status 'PASS' -Details 'No common pending reboot flags detected.'
    }
}
catch {
    $results += New-Result -Category 'System' -Check 'Pending Reboot' -Status 'WARN' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# 12. Optional software spot-check from Step 1 export
# ------------------------------------------------------------
Write-Section 'Installed Software Spot Check'

try {
    $oldProgramsFile = Get-LatestExportFile -Pattern '*InstalledPrograms.csv'
    if ($oldProgramsFile) {
        $oldPrograms = Import-Csv $oldProgramsFile.FullName | Where-Object { $_.DisplayName }
        $newPrograms = @(
            Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        ) | Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName

        $importantPrograms = $oldPrograms | Select-Object -First 15
        $missingPrograms = @()

        foreach ($prog in $importantPrograms) {
            if ($prog.DisplayName -and ($prog.DisplayName -notin $newPrograms)) {
                $missingPrograms += $prog.DisplayName
            }
        }

        if ($missingPrograms.Count -eq 0) {
            $results += New-Result -Category 'Software' -Check 'Basic Software Spot Check' -Status 'PASS' -Details 'Sample of exported software appears present on new server.'
        }
        else {
            $results += New-Result -Category 'Software' -Check 'Basic Software Spot Check' -Status 'WARN' -Details ('Potentially missing software: ' + ($missingPrograms -join ', ')) -Recommendation 'Review required application installs before cutover.'
        }
    }
    else {
        $results += New-Result -Category 'Software' -Check 'Basic Software Spot Check' -Status 'WARN' -Details 'No InstalledPrograms export found from Step 1.'
    }
}
catch {
    $results += New-Result -Category 'Software' -Check 'Basic Software Spot Check' -Status 'WARN' -Details $_.Exception.Message
}

# ------------------------------------------------------------
# Summary / Output
# ------------------------------------------------------------
Write-Section 'Validation Results'

foreach ($item in $results) {
    $color = switch ($item.Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'White' }
    }

    Write-Host ("[{0}] {1} / {2} - {3}" -f $item.Status, $item.Category, $item.Check, $item.Details) -ForegroundColor $color
}

Write-Section 'Summary Totals'
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("{0}: {1}" -f $_.Name, $_.Count)
}

Save-Results -Results $results

Write-Section 'Step 2 Complete'
Write-Log INFO 'Review WARN and FAIL items before continuing to migration.'
Write-Log INFO "Validation reports saved under: $ReportsRoot"

Read-Host 'Press Enter to return to launcher'
