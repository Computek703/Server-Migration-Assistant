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
    $Results | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8
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
            foreach ($candidate in @($fwd.IPAddress -split '[,;\s]+')) {
                if (-not $candidate) { continue }
                $parsed = $null
                if ([System.Net.IPAddress]::TryParse($candidate,[ref]$parsed) -and $parsed.AddressFamily -eq 'InterNetwork') {
                    $ips += $parsed.IPAddressToString
                }
                else { Write-Log WARN "Skipping invalid DNS forwarder value: $candidate" }
            }
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

        if ($share.Name -in @('NETLOGON','SYSVOL')) {
            Write-Log WARN "Skipping protected domain-controller share: $($share.Name). Use AD replication."
            continue
        }

        if (-not (Test-Path -LiteralPath $share.Path)) {
            New-Item -Path $share.Path -ItemType Directory -Force | Out-Null
            Write-Log INFO "Created destination folder: $($share.Path)"
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

function Set-SmbSharePermissionsFromExport {
    param([Parameter(Mandatory)][string]$PermissionsCsv)

    if (-not (Get-Command Grant-SmbShareAccess -ErrorAction SilentlyContinue)) {
        throw 'SMB share permission cmdlets are not available.'
    }
    foreach ($entry in (Import-Csv -LiteralPath $PermissionsCsv)) {
        if (-not $entry.ShareName -or -not $entry.AccountName -or $entry.ShareName -match '["\r\n]') { continue }
        if ($entry.ShareName -in @('NETLOGON','SYSVOL')) {
            Write-Log WARN "Skipping protected domain-controller share permission: $($entry.ShareName)"
            continue
        }
        if (-not (Get-SmbShare -Name $entry.ShareName -ErrorAction SilentlyContinue)) {
            Write-Log WARN "Cannot apply access; share does not exist: $($entry.ShareName)"
            continue
        }
        try {
            if ($entry.AccessControlType -eq 'Deny') {
                Block-SmbShareAccess -Name $entry.ShareName -AccountName $entry.AccountName -Force | Out-Null
            }
            elseif ($entry.AccessRight -in @('Full','Change','Read')) {
                Grant-SmbShareAccess -Name $entry.ShareName -AccountName $entry.AccountName -AccessRight $entry.AccessRight -Force | Out-Null
            }
            Write-Log PASS "Applied $($entry.AccessControlType) $($entry.AccessRight) for $($entry.AccountName) on $($entry.ShareName)"
        }
        catch { Write-Log FAIL "Share access failed for $($entry.ShareName)/$($entry.AccountName): $($_.Exception.Message)" }
    }
    Write-Log WARN 'Review effective share permissions manually; additional pre-existing entries are not removed.'
}

function Invoke-RoleInstallationGuide {
    param([Parameter(Mandatory)][object]$Manifest)

    if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
        Write-Log WARN 'Server Manager cmdlets are unavailable. Install roles manually with Server Manager.'
        return $false
    }

    $available = @(Get-WindowsFeature)
    $installedNames = @($available | Where-Object InstallState -eq 'Installed' | Select-Object -ExpandProperty Name)
    $missing = @($Manifest.InstalledFeatures | Where-Object { $_ -and $_ -notin $installedNames })
    if (-not $missing.Count) {
        Write-Log PASS 'All exported Windows roles and features are installed on this server.'
        return $true
    }

    $specialPatterns = @(
        '^AD-Domain-Services$','^ADCS-','^Hyper-V$','^Failover-Clustering$','^FS-DFS-',
        '^DHCP$','^DNS$','^Web-','^NPAS$','^RemoteAccess$','^RDS-','^WDS$','^UpdateServices'
    )
    $optionalPatterns = @('^RSAT','^GPMC$','^PowerShell-ISE$','-Tools$','-PowerShell$')
    $safe = @(); $special = @(); $optional = @(); $unavailable = @()

    foreach ($name in $missing) {
        $feature = $available | Where-Object Name -eq $name | Select-Object -First 1
        if (-not $feature) { $unavailable += $name; continue }
        if ($specialPatterns | Where-Object { $name -match $_ }) { $special += $feature; continue }
        if ($optionalPatterns | Where-Object { $name -match $_ }) { $optional += $feature; continue }
        $safe += $feature
    }

    $planPath = Join-Path $ReportsRoot "$BaseName-RoleInstallationPlan.txt"
    $lines = @(
        'NEW SERVER ROLE INSTALLATION PLAN',
        "Source: $($Manifest.SourceComputer)", "Target: $ComputerName", "Generated: $(Get-Date -Format s)", ''
    )
    foreach ($group in @(
        @{Title='SAFE AUTOMATIC INSTALL CANDIDATES';Items=$safe},
        @{Title='SPECIALIZED - USE GUIDED OR PRODUCT-SPECIFIC MIGRATION';Items=$special},
        @{Title='OPTIONAL MANAGEMENT TOOLS';Items=$optional}
    )) {
        $lines += $group.Title
        if (@($group.Items).Count) {
            $lines += @($group.Items | ForEach-Object { "- $($_.DisplayName) [$($_.Name)]" })
        } else { $lines += '- None' }
        $lines += ''
    }
    $lines += 'UNAVAILABLE ON THIS OPERATING SYSTEM'
    $lines += $(if ($unavailable.Count) { @($unavailable | ForEach-Object { "- $_" }) } else { '- None' })
    $lines += '', 'Do not blindly install specialized roles. Their configuration and data require supported migration procedures.'
    $lines | Set-Content -LiteralPath $planPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Missing Windows roles and features:' -ForegroundColor Yellow
    foreach ($feature in $safe) { Write-Host "  AUTO: $($feature.DisplayName) [$($feature.Name)]" -ForegroundColor Green }
    foreach ($feature in $special) { Write-Host "  GUIDED: $($feature.DisplayName) [$($feature.Name)]" -ForegroundColor Yellow }
    foreach ($feature in $optional) { Write-Host "  OPTIONAL: $($feature.DisplayName) [$($feature.Name)]" }
    foreach ($name in $unavailable) { Write-Host "  UNAVAILABLE: $name" -ForegroundColor Red }
    Write-Log INFO "Role installation plan saved: $planPath"

    if ($safe.Count) {
        $answer = Read-Host 'Type INSTALL SAFE ROLES to install the green AUTO items, or SKIP'
        if ($answer -ceq 'INSTALL SAFE ROLES') {
            $result = Install-WindowsFeature -Name @($safe.Name) -IncludeManagementTools -ErrorAction Stop
            $result | Format-Table DisplayName,Name,InstallState -AutoSize | Out-String | ForEach-Object { Write-Log INFO $_.Trim() }
            if ($result.RestartNeeded -eq 'Yes') {
                Write-Log WARN 'A restart is required. Restart the server, then rerun Step 2 and the wizard.'
                return $false
            }
        }
    }
    if ($optional.Count -and (Read-Host 'Install the optional management tools listed above? Type INSTALL TOOLS or SKIP') -ceq 'INSTALL TOOLS') {
        $toolResult = Install-WindowsFeature -Name @($optional.Name) -ErrorAction Stop
        if ($toolResult.RestartNeeded -eq 'Yes') { Write-Log WARN 'A restart is required after management-tool installation.'; return $false }
    }

    return (-not $special.Count -and -not $unavailable.Count)
}

function Invoke-DomainControllerMigrationGuide {
    param([Parameter(Mandatory)][object]$Manifest)

    $guidePath = Join-Path $ReportsRoot "$BaseName-DomainController-Guide.txt"
    $system = Get-CimInstance Win32_ComputerSystem
    $adds = Get-WindowsFeature AD-Domain-Services -ErrorAction SilentlyContinue
    $dns = Get-WindowsFeature DNS -ErrorAction SilentlyContinue
    $targetDomain = [string]$Manifest.SourceDomain
    $hasDomainIdentity = $Manifest.PSObject.Properties.Name -contains 'DomainIdentity' -and $null -ne $Manifest.DomainIdentity
    if ($hasDomainIdentity -and $Manifest.DomainIdentity.DNSRoot) { $targetDomain = [string]$Manifest.DomainIdentity.DNSRoot }
    $lines = @(
        'DOMAIN CONTROLLER MIGRATION GUIDE',
        "Source DC: $($Manifest.SourceComputer)",
        "Target: $ComputerName",
        "Domain: $targetDomain",
        "Target domain joined: $($system.PartOfDomain)",
        "AD DS installed: $($adds.InstallState -eq 'Installed')",
        "DNS installed: $($dns.InstallState -eq 'Installed')",
        '',
        'Important: never create or copy SYSVOL/NETLOGON manually. They must appear through AD replication.'
    )

    if (-not $system.PartOfDomain) {
        $activeConfigs = @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address })
        if ($activeConfigs.Count -ne 1) {
            Write-Log WARN "Expected one active IPv4 adapter but found $($activeConfigs.Count). Network configuration will be skipped."
        }
        else {
            $config = $activeConfigs[0]
            $address = Get-NetIPAddress -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
            $gateway = @($config.IPv4DefaultGateway.NextHop) | Select-Object -First 1
            $sourceAddresses = @()
            if ($Manifest.PSObject.Properties.Name -contains 'SourceIPv4') {
                $sourceRecords = @($Manifest.SourceIPv4 | Where-Object IPAddress)
                $routedSourceRecords = @($sourceRecords | Where-Object Gateway)
                if ($routedSourceRecords.Count) { $sourceRecords = $routedSourceRecords }
                $sourceAddresses = @($sourceRecords | Select-Object -ExpandProperty IPAddress -Unique)
            }
            if (-not $sourceAddresses.Count) {
                try {
                    $sourceAddresses = @([System.Net.Dns]::GetHostAddresses([string]$Manifest.SourceComputer) |
                        Where-Object AddressFamily -eq 'InterNetwork' | ForEach-Object IPAddressToString)
                } catch { }
            }

            Write-Host ''
            Write-Host 'NEW SERVER NETWORK CHECKPOINT' -ForegroundColor Cyan
            Write-Host "Adapter       : $($config.InterfaceAlias)"
            Write-Host "Current IPv4  : $($address.IPAddress)/$($address.PrefixLength)"
            Write-Host "Address source: $($address.PrefixOrigin)"
            Write-Host "Gateway       : $gateway"
            Write-Host "Current DNS   : $(@($config.DnsServer.ServerAddresses) -join ', ')"
            Write-Host "Old server IP : $($sourceAddresses -join ', ')" -ForegroundColor Yellow

            if ($address.PrefixOrigin -eq 'Dhcp') {
                Write-Host 'The current address was received from DHCP.' -ForegroundColor Yellow
                Write-Host '1. Keep DHCP (skip static configuration)'
                Write-Host '2. Convert the current DHCP address to static'
                Write-Host '3. Enter a different planned static address'
                $networkChoice = Read-Host 'Select 1, 2, or 3'
                if ($networkChoice -eq '2') {
                    $leaseSafety = Read-Host 'Confirm this address is reserved for this server or excluded from the DHCP pool. Type DHCP ADDRESS SAFE or CANCEL'
                    if ($leaseSafety -ceq 'DHCP ADDRESS SAFE') {
                        $proposedIp = $address.IPAddress; $proposedPrefix = $address.PrefixLength; $proposedGateway = $gateway
                    }
                }
                elseif ($networkChoice -eq '3') {
                    $proposedIp = Read-Host 'Enter the planned IPv4 address'
                    $proposedPrefix = Read-Host 'Enter the prefix length (for example 24)'
                    $proposedGateway = Read-Host 'Enter the default gateway'
                }

                if ($proposedIp) {
                    $parsedIp = $null; $parsedGateway = $null
                    if (-not [System.Net.IPAddress]::TryParse($proposedIp,[ref]$parsedIp) -or $parsedIp.AddressFamily -ne 'InterNetwork') { throw "Invalid IPv4 address: $proposedIp" }
                    if (-not [System.Net.IPAddress]::TryParse($proposedGateway,[ref]$parsedGateway) -or $parsedGateway.AddressFamily -ne 'InterNetwork') { throw "Invalid gateway: $proposedGateway" }
                    $prefixNumber = 0
                    if (-not [int]::TryParse([string]$proposedPrefix,[ref]$prefixNumber) -or $prefixNumber -lt 1 -or $prefixNumber -gt 32) { throw "Invalid prefix length: $proposedPrefix" }
                    if ($proposedIp -in $sourceAddresses) { throw 'The new server cannot use the old server IP while both servers are online.' }
                    Write-Host "Proposed static configuration: $proposedIp/$prefixNumber, gateway $proposedGateway" -ForegroundColor Yellow
                    if ((Read-Host 'Type APPLY STATIC NETWORK to make this change, or SKIP') -ceq 'APPLY STATIC NETWORK') {
                        Set-NetIPInterface -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
                        Get-NetIPAddress -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object PrefixOrigin -eq 'Dhcp' | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                        New-NetIPAddress -InterfaceIndex $config.InterfaceIndex -IPAddress $proposedIp -PrefixLength $prefixNumber -DefaultGateway $proposedGateway -ErrorAction Stop | Out-Null
                        Write-Log PASS "Applied static IPv4 configuration to $($config.InterfaceAlias): $proposedIp/$prefixNumber"
                    }
                }
            }
            else { Write-Log INFO 'The active IPv4 address is already static; no address conversion is needed.' }

            if ($sourceAddresses.Count) {
                $currentDomainDns = @((Get-DnsClientServerAddress -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
                if (@($sourceAddresses | Where-Object { $_ -notin $currentDomainDns }).Count -eq 0) {
                    Write-Log PASS "Domain DNS is already configured: $($currentDomainDns -join ', ')"
                }
                else {
                    Write-Host "The old server IP will be used as internal DNS for joining $targetDomain." -ForegroundColor Yellow
                    if ((Read-Host 'Type SET DOMAIN DNS to apply it, or SKIP') -ceq 'SET DOMAIN DNS') {
                    Set-DnsClientServerAddress -InterfaceIndex $config.InterfaceIndex -ServerAddresses $sourceAddresses -ErrorAction Stop
                    Clear-DnsClientCache
                    Write-Log PASS "Set DNS on $($config.InterfaceAlias) to: $($sourceAddresses -join ', ')"
                    }
                }
            }
            else { Write-Log FAIL 'No old-server IPv4 address was found in the export or DNS. Domain DNS was not changed.' }
        }
    }

    if (-not $system.PartOfDomain) {
        Write-Log WARN "The replacement must join $targetDomain before domain-controller promotion."
        $install = Read-Host 'Install AD DS/DNS prerequisites and management tools now? Type INSTALL or SKIP'
        if ($install -ceq 'INSTALL') {
            Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools -ErrorAction Stop | Out-String | ForEach-Object { Write-Log INFO $_.Trim() }
        }
        $domainDns = @()
        try {
            $domainDns = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$targetDomain" -Type SRV -ErrorAction Stop)
            Write-Log PASS "The existing AD domain is discoverable through DNS: $targetDomain"
        }
        catch {
            Write-Log FAIL "The AD domain cannot be discovered through DNS: $targetDomain"
            Write-Log WARN 'Set the active network adapter DNS server to the existing domain controller IP, then rerun this step.'
        }

        $lines += @(
            '', 'NEXT CHECKPOINT: JOIN THE EXISTING DOMAIN',
            "Confirm the target uses the existing AD DNS server - not public DNS - then run:",
            "Add-Computer -DomainName '$targetDomain' -Credential (Get-Credential) -Restart",
            'After restart, sign in with a domain administrative account and rerun Step 2.'
        )
        $lines | Set-Content -LiteralPath $guidePath -Encoding UTF8
        Write-Log WARN "Guide saved: $guidePath"
        if ($domainDns.Count) {
            Write-Host "TARGET DOMAIN: $targetDomain" -ForegroundColor Yellow
            if ($hasDomainIdentity -and $Manifest.DomainIdentity.ObjectGUID) { Write-Host "DOMAIN ID: $($Manifest.DomainIdentity.ObjectGUID)" }
            $domainNameConfirmation = Read-Host "Type the exact domain name $targetDomain to authorize the join, or SKIP"
            if ($domainNameConfirmation -ceq $targetDomain) {
                $joinAnswer = Read-Host 'Type JOIN DOMAIN to execute the join and restart, or SKIP'
            }
            if ($domainNameConfirmation -ceq $targetDomain -and $joinAnswer -ceq 'JOIN DOMAIN') {
                Write-Host 'Enter an account permitted to join computers to the existing domain.' -ForegroundColor Yellow
                $credential = Get-Credential -Message "Credentials for joining $targetDomain"
                if (-not $credential) { Write-Log WARN 'No credentials supplied. Domain join cancelled.'; return $false }
                Add-Computer -DomainName $targetDomain -Credential $credential -ErrorAction Stop
                Write-Log PASS "Domain join succeeded. Restarting this server; rerun the wizard after signing in."
                Restart-Computer -Force
            }
        }
        return $false
    }

    if (-not $adds -or $adds.InstallState -ne 'Installed' -or -not $dns -or $dns.InstallState -ne 'Installed') {
        $install = Read-Host 'Install AD DS/DNS prerequisites and management tools now? Type INSTALL or SKIP'
        if ($install -ceq 'INSTALL') {
            Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools -ErrorAction Stop | Out-String | ForEach-Object { Write-Log INFO $_.Trim() }
        }
        $lines += @('', 'NEXT CHECKPOINT: REBOOT IF REQUESTED, THEN RERUN STEP 2.')
        $lines | Set-Content -LiteralPath $guidePath -Encoding UTF8
        Write-Log WARN "Guide saved: $guidePath"
        return $false
    }

    $isDc = (Get-Service NTDS -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters')
    if (-not $isDc) {
        $lines += @(
            '', 'NEXT CHECKPOINT: PROMOTE AS AN ADDITIONAL DOMAIN CONTROLLER',
            'Verify DNS points to an existing healthy domain controller, then run in an elevated PowerShell session:',
            '$credential = Get-Credential',
            '$dsrmPassword = Read-Host ''DSRM password'' -AsSecureString',
            "Install-ADDSDomainController -DomainName '$targetDomain' -InstallDns -Credential `$credential -SafeModeAdministratorPassword `$dsrmPassword",
            'The promotion normally restarts the server. Rerun Step 2 afterward.'
        )
        $lines | Set-Content -LiteralPath $guidePath -Encoding UTF8
        Write-Log WARN 'AD DS is installed, but this server is not yet a domain controller. Promotion is intentionally not executed automatically.'
        Write-Log WARN "Guide saved: $guidePath"
        return $false
    }

    $healthPath = Join-Path $ReportsRoot "$BaseName-DomainController-Health.txt"
    $dcdiagOutput = dcdiag.exe /test:Advertising /test:Services /test:Replications /test:SysVolCheck /test:NetLogons /test:DNS /q 2>&1 | Out-String
    $dcdiagPassed = $LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($dcdiagOutput)
    $repSummary = repadmin.exe /replsummary 2>&1 | Out-String
    $showRepl = repadmin.exe /showrepl 2>&1 | Out-String
    $replicationFailures = @(Get-ADReplicationFailure -Target $ComputerName -Scope Server -ErrorAction SilentlyContinue)
    $partners = @(Get-ADReplicationPartnerMetadata -Target $ComputerName -Scope Server -ErrorAction SilentlyContinue)
    $partnersHealthy = $partners.Count -gt 0 -and -not @($partners | Where-Object LastReplicationResult -ne 0).Count
    $shares = @(Get-SmbShare -Name SYSVOL,NETLOGON -ErrorAction SilentlyContinue)
    $shareNames = @($shares.Name)
    $requiredSharesHealthy = 'SYSVOL' -in $shareNames -and 'NETLOGON' -in $shareNames
    $requiredServices = @('NTDS','DNS','DFSR','Netlogon')
    $stoppedServices = @($requiredServices | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -ne 'Running' })
    try { $domainRecords = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$targetDomain" -Type SRV -ErrorAction Stop) }
    catch { $domainRecords = @() }
    $healthPassed = $dcdiagPassed -and -not $replicationFailures.Count -and $partnersHealthy -and $requiredSharesHealthy -and -not $stoppedServices.Count -and $domainRecords.Count

    @(
        "AUTOMATED RESULT: $(if ($healthPassed) {'PASS'} else {'FAIL'})",
        "Focused DCDIAG passed: $dcdiagPassed",
        "Replication failure records: $($replicationFailures.Count)",
        "Healthy replication partners: $partnersHealthy (partners=$($partners.Count))",
        "SYSVOL and NETLOGON present: $requiredSharesHealthy",
        "Stopped required services: $($stoppedServices -join ', ')",
        "AD DNS SRV records: $($domainRecords.Count)",
        '', '=== FOCUSED DCDIAG ===', $dcdiagOutput,
        '=== REPADMIN REPLSUMMARY ===', $repSummary,
        '=== REPADMIN SHOWREPL ===', $showRepl,
        '=== REPLICATION PARTNERS ===', ($partners | Format-Table Server,Partner,Partition,LastReplicationSuccess,LastReplicationResult -AutoSize | Out-String),
        '=== SYSVOL/NETLOGON ===', ($shares | Format-Table -AutoSize | Out-String)
    ) | Set-Content -LiteralPath $healthPath -Encoding UTF8
    $lines += @(
        '', 'DOMAIN CONTROLLER DETECTED',
        "Health evidence: $healthPath",
        "Automated health result: $(if ($healthPassed) {'PASS'} else {'FAIL'})",
        'Only then consider transferring FSMO roles with Move-ADDirectoryServerOperationMasterRole.',
        'Do not demote the old DC until DNS, authentication, SYSVOL/NETLOGON, Global Catalog, and replication are verified.'
    )
    $lines | Set-Content -LiteralPath $guidePath -Encoding UTF8
    if ($healthPassed) {
        Write-Log PASS "Automated domain-controller health and replication checks passed. Evidence: $healthPath"
        return $true
    }
    Write-Log FAIL "Automated domain-controller health checks failed. Evidence: $healthPath"
    if (-not $dcdiagPassed) { Write-Log FAIL 'One or more focused DCDIAG tests failed.' }
    if ($replicationFailures.Count -or -not $partnersHealthy) { Write-Log FAIL 'Active Directory replication is not healthy.' }
    if (-not $requiredSharesHealthy) { Write-Log FAIL 'SYSVOL or NETLOGON is missing.' }
    if ($stoppedServices.Count) { Write-Log FAIL "Required services are stopped: $($stoppedServices -join ', ')" }
    if (-not $domainRecords.Count) { Write-Log FAIL 'AD DNS SRV discovery failed.' }
    return $false
}

function New-RobocopyScriptFromShares {
    param(
        [Parameter(Mandatory)][string]$SharesCsv,
        [Parameter(Mandatory)][string]$OldServerName
    )

    if ($OldServerName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$') {
        throw "Invalid old server name: $OldServerName"
    }

    $shares = Import-Csv $SharesCsv
    $initialPath = Join-Path $ReportsRoot "$BaseName-Robocopy-Initial.cmd"
    $finalPath = Join-Path $ReportsRoot "$BaseName-Robocopy-Final.cmd"
    $initialLines = @('@echo off','setlocal','REM Initial copy: safe to repeat while the source remains online.','')
    $finalLines = @('@echo off','setlocal','REM FINAL DELTA: stop writes to source shares first.','REM /MIR can delete destination files absent from the source. Review all paths.','')

    foreach ($share in $shares) {
        if (-not $share.Name -or -not $share.Path) { continue }
        if ($share.Name -in @('NETLOGON','SYSVOL')) {
            Write-Log WARN "Skipping protected domain-controller share in Robocopy generation: $($share.Name)"
            continue
        }
        if ($share.Name -match '["\r\n\\/:*?<>|]' -or $share.Path -match '["\r\n]') {
            Write-Log WARN "Skipping unsafe share entry: $($share.Name)"
            continue
        }

        $source = "\\$OldServerName\$($share.Name)"
        $dest   = $share.Path
        $initialLog = Join-Path $ReportsRoot ("Robocopy-Initial-" + $share.Name + ".log")
        $finalLog = Join-Path $ReportsRoot ("Robocopy-Final-" + $share.Name + ".log")
        $initialLines += 'robocopy "{0}" "{1}" /E /COPYALL /DCOPY:DAT /ZB /SECFIX /TIMFIX /XJ /R:2 /W:5 /MT:16 /TEE /LOG+:"{2}"' -f $source, $dest, $initialLog
        $initialLines += 'if errorlevel 8 exit /b %errorlevel%'
        $finalLines += 'robocopy "{0}" "{1}" /MIR /COPYALL /DCOPY:DAT /ZB /SECFIX /TIMFIX /XJ /R:2 /W:5 /MT:16 /TEE /LOG+:"{2}"' -f $source, $dest, $finalLog
        $finalLines += 'if errorlevel 8 exit /b %errorlevel%'
    }

    $initialLines += @('exit /b 0','endlocal')
    $finalLines += @('exit /b 0','endlocal')
    $initialLines | Set-Content -LiteralPath $initialPath -Encoding ASCII
    $finalLines | Set-Content -LiteralPath $finalPath -Encoding ASCII
    return [PSCustomObject]@{ Initial=$initialPath; Final=$finalPath }
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
    return
}

Write-Host 'Step 3 can change DHCP, DNS, and SMB configuration on this server.' -ForegroundColor Yellow
$targetConfirmation = Read-Host "Type this NEW server name to continue: $ComputerName"
if ($targetConfirmation -cne $ComputerName) {
    Write-Log WARN 'Target server confirmation did not match. Migration cancelled.'
    return
}
$changeConfirmation = Read-Host 'Confirm you reviewed Step 2 and want to enter the migration prompts? (YES/NO)'
if ($changeConfirmation -cne 'YES') {
    Write-Log WARN 'Migration cancelled by technician.'
    return
}

$results = @()
$step2Failures = @()
$guideFailures = @()
$blockingFailures = @()

$manifestFile = Get-LatestExportFile -Pattern '*MigrationManifest.json'
if ($manifestFile) {
    $latestStep2 = Get-ChildItem -Path $ReportsRoot -Filter "$ComputerName-Step02-*-ValidationResults.csv" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if (-not $latestStep2 -or $latestStep2.LastWriteTime -lt $manifestFile.LastWriteTime -or $latestStep2.LastWriteTime -lt $lastBoot) {
        Write-Log FAIL 'Step 3 blocked: a fresh Step 2 validation is required after the latest export and server restart.'
        Write-Log WARN 'Return to the wizard or Troubleshooting Tools, run Step 2, and resolve every FAIL result.'
        Read-Host 'Press Enter to return to launcher'
        return
    }
    $step2Failures = @(Import-Csv -LiteralPath $latestStep2.FullName | Where-Object Status -eq 'FAIL')
    if ($step2Failures.Count) {
        $guideFailures = @($step2Failures | Where-Object Check -eq 'Domain Controller Migration')
        $blockingFailures = @($step2Failures | Where-Object Check -ne 'Domain Controller Migration')
        if ($blockingFailures.Count) {
            Write-Log FAIL "Step 3 blocked: the latest Step 2 validation contains $($blockingFailures.Count) non-remediable failure(s)."
            $blockingFailures | Format-Table Category,Check,Details,Recommendation -Wrap
            Read-Host 'Press Enter to return to launcher'
            return
        }
        if ($guideFailures.Count) { Write-Log WARN 'Step 3 is entering guided domain-controller remediation only. Run Step 2 again afterward.' }
    }
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    $roleReady = Invoke-RoleInstallationGuide -Manifest $manifest
    if ($manifest.PurposeSignals.DomainController) {
        if (-not (Invoke-DomainControllerMigrationGuide -Manifest $manifest)) {
            Write-Log WARN 'Migration paused at the domain-controller checkpoint. Complete the guide and rerun Step 2.'
            Read-Host 'Press Enter to return to launcher'
            return
        }
        Write-Log WARN 'Domain-controller source detected. SYSVOL and NETLOGON will be excluded from share creation, permissions, and Robocopy.'
        if ($guideFailures.Count) {
            Write-Log WARN 'Domain-controller remediation completed or paused. Step 3 will not continue until Step 2 is rerun with no FAIL results.'
            Read-Host 'Press Enter to return to launcher'
            return
        }
        if (-not $roleReady) {
            Write-Log FAIL 'Migration blocked: one or more specialized source roles still require a completed migration plan.'
            Write-Log WARN 'Review the role installation plan before continuing with file migration.'
            Read-Host 'Press Enter to return to launcher'
            return
        }
    }
    elseif (-not $roleReady) {
        Write-Log WARN 'Migration paused because specialized or unavailable roles require review. See the role installation plan.'
        Read-Host 'Press Enter to return to launcher'
        return
    }
}

Write-Section 'Migration Source Info'
$OldServerName = Read-Host 'Enter the OLD server name used for Robocopy/share references'
if (-not $OldServerName) {
    Write-Log WARN 'No old server name entered. Robocopy command generation will be skipped.'
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
        if (($doRobocopyScript -match '^(Y|y)$') -and $OldServerName) {
            $robocopyScripts = New-RobocopyScriptFromShares -SharesCsv $sharesFile.FullName -OldServerName $OldServerName
            $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'PASS' -Details 'Created initial and final-delta Robocopy scripts.'
            Write-Log PASS "Initial copy script: $($robocopyScripts.Initial)"
            Write-Log WARN "Final /MIR script (review before use): $($robocopyScripts.Final)"
        }
        elseif (-not $OldServerName) {
            $results += New-Result -Category 'File Services' -Action 'Generate Robocopy Commands' -Status 'WARN' -Details 'Skipped because no valid old server name was supplied.'
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
# 6. Apply SMB Share Permissions
# ------------------------------------------------------------
Write-Section 'SMB Share Permissions'
try {
    $permissionsFile = Get-LatestExportFile -Pattern '*SharePermissions.csv'
    if ($permissionsFile) {
        $applyPermissions = Read-Host "Apply exported SMB share permissions from $($permissionsFile.Name)? (Y/N)"
        if ($applyPermissions -match '^(Y|y)$') {
            Set-SmbSharePermissionsFromExport -PermissionsCsv $permissionsFile.FullName
            $results += New-Result -Category 'File Services' -Action 'Apply Share Permissions' -Status 'PASS' -Details 'Processed exported SMB share permissions.'
        }
        else { $results += New-Result -Category 'File Services' -Action 'Apply Share Permissions' -Status 'INFO' -Details 'Skipped by technician.' }
    }
    else { $results += New-Result -Category 'File Services' -Action 'Apply Share Permissions' -Status 'WARN' -Details 'No share-permission export found.' }
}
catch { $results += New-Result -Category 'File Services' -Action 'Apply Share Permissions' -Status 'FAIL' -Details $_.Exception.Message }

# ------------------------------------------------------------
# 7. Notes / Manual Items
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
