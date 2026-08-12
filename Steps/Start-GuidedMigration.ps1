[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
. (Join-Path $projectRoot 'Modules\Common-Functions.ps1')
$paths = Initialize-ToolkitOutput -ProjectRoot $projectRoot
$statePath = Join-Path $paths.Output 'Migration-State.json'
$computerName = $env:COMPUTERNAME

function Invoke-ToolkitStep([string]$Name) {
    $path = Join-Path $scriptRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing toolkit step: $path" }
    & $path
}

function Get-LatestFile([string]$Folder,[string]$Pattern) {
    Get-ChildItem -LiteralPath $Folder -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function New-State {
    [PSCustomObject]@{
        SchemaVersion=1; SourceServer=''; TargetServer=''; IntendedDomain=''; DomainGuid=''; Phase='Discovery';
        InitialCopyVerified=$false; CutoverApproved=$false; FinalCopyVerified=$false;
        PostCutoverVerified=$false; LastUpdated=(Get-Date).ToString('o')
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return (New-State) }
    try {
        $loaded = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $defaults = New-State
        foreach ($property in $defaults.PSObject.Properties) {
            if ($loaded.PSObject.Properties.Name -notcontains $property.Name) {
                $loaded | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
            }
        }
        return $loaded
    }
    catch { Write-Host 'The migration state file is unreadable. A new state will be created.' -ForegroundColor Yellow; return (New-State) }
}

function Save-State($State) {
    $State.LastUpdated = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Show-Heading([string]$Text) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}

function Stop-Wizard([string]$Message) {
    Write-Host ''
    Write-Host "NEXT ACTION: $Message" -ForegroundColor Yellow
    Write-Host "Progress file: $statePath"
    Read-Host 'Press Enter to return to the launcher'
}

function Complete-MigrationCleanup {
    param([Parameter(Mandatory)][object]$State)

    Show-Heading 'FINAL ARCHIVE AND CLEANUP'
    Write-Host 'This removes the active migration package only after creating and verifying an archive.' -ForegroundColor Yellow
    Write-Host "Source: $($State.SourceServer)  Target: $($State.TargetServer)  Domain: $($State.IntendedDomain)"
    $confirmation = Read-Host 'Type ARCHIVE AND RESET TOOLKIT to close this migration, or SKIP'
    if ($confirmation -cne 'ARCHIVE AND RESET TOOLKIT') { return $false }

    $archiveRoot = Join-Path $projectRoot 'MigrationArchives'
    if (-not (Test-Path -LiteralPath $archiveRoot)) { New-Item -Path $archiveRoot -ItemType Directory -Force | Out-Null }
    $safeSource = ($State.SourceServer -replace '[^A-Za-z0-9_.-]','_')
    $safeTarget = ($State.TargetServer -replace '[^A-Za-z0-9_.-]','_')
    $archivePath = Join-Path $archiveRoot ("Migration-{0}-to-{1}-{2}.zip" -f $safeSource,$safeTarget,(Get-Date -Format 'yyyyMMdd_HHmmss'))
    $outputItems = @(Get-ChildItem -LiteralPath $paths.Output -Force -ErrorAction Stop)
    if (-not $outputItems.Count) { Write-Host 'Output is already empty; cleanup cancelled.' -ForegroundColor Red; return $false }

    Compress-Archive -LiteralPath @($outputItems.FullName) -DestinationPath $archivePath -CompressionLevel Optimal -ErrorAction Stop
    $archive = Get-Item -LiteralPath $archivePath -ErrorAction Stop
    if ($archive.Length -le 0) { throw "Archive verification failed: $archivePath" }
    $hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    $hashFile = "$archivePath.sha256.txt"
    "SHA256  $($hash.Hash)  $($archive.Name)" | Set-Content -LiteralPath $hashFile -Encoding ASCII

    $resolvedOutput = (Resolve-Path -LiteralPath $paths.Output).Path
    $expectedOutput = (Join-Path $projectRoot 'Output')
    if ($resolvedOutput -ne $expectedOutput) { throw "Refusing cleanup of unexpected path: $resolvedOutput" }
    foreach ($item in $outputItems) {
        if (-not $item.FullName.StartsWith("$resolvedOutput\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing cleanup outside Output: $($item.FullName)"
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
    Initialize-ToolkitOutput -ProjectRoot $projectRoot | Out-Null
    Write-Host "Migration archived: $archivePath" -ForegroundColor Green
    Write-Host "Checksum saved : $hashFile" -ForegroundColor Green
    Write-Host 'The toolkit is reset and ready for the next migration.' -ForegroundColor Green
    return $true
}

Clear-Host
Show-Heading 'GUIDED SERVER MIGRATION WIZARD'
Write-Host "Current server : $computerName"
Write-Host "Toolkit folder : $projectRoot"
Write-Host 'The wizard performs one safe checkpoint at a time and can be rerun after restarts.'

if (-not (Test-ToolkitAdministrator)) {
    Stop-Wizard 'Close the toolkit and run the launcher as Administrator.'
    return
}

$state = Read-State
$manifestFile = Get-LatestFile -Folder $paths.Exports -Pattern '*MigrationManifest.json'
$manifest = if ($manifestFile) { Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json } else { $null }

if (-not $manifest) {
    Show-Heading 'CHECKPOINT 1 OF 7 - DISCOVER THE OLD SERVER'
    Write-Host 'No migration package was found. Run this checkpoint on the OLD server.'
    if ((Read-Host 'Is this the old server that will be replaced? Type YES or NO') -cne 'YES') {
        Stop-Wizard 'Move the complete toolkit to the old server and run Guided Migration again.'
        return
    }
    Invoke-ToolkitStep 'Step-01-Export-OldServer.ps1'
    Stop-Wizard 'Review Step 1 warnings. Then move this complete toolkit folder to the new server.'
    return
}

$state.SourceServer = [string]$manifest.SourceComputer
$hasDomainIdentity = $manifest.PSObject.Properties.Name -contains 'DomainIdentity' -and $null -ne $manifest.DomainIdentity
$exportDomain = if ($hasDomainIdentity -and $manifest.DomainIdentity.DNSRoot) { [string]$manifest.DomainIdentity.DNSRoot } else { [string]$manifest.SourceDomain }
$exportGuid = if ($hasDomainIdentity -and $manifest.DomainIdentity.ObjectGUID) { [string]$manifest.DomainIdentity.ObjectGUID } else { '' }
if (-not $state.IntendedDomain) {
    Show-Heading 'CONFIRM THE MIGRATION DOMAIN'
    Write-Host "The old-server export identifies this domain: $exportDomain" -ForegroundColor Yellow
    Write-Host 'The toolkit will save this choice on the flash drive and refuse a different domain later.'
    $domainConfirmation = Read-Host "Type the exact domain name $exportDomain to bind this migration"
    if ($domainConfirmation -cne $exportDomain) {
        Stop-Wizard 'Domain confirmation did not match the old-server export. No domain action was taken.'
        return
    }
    $state.IntendedDomain = $exportDomain
    $state.DomainGuid = $exportGuid
    Save-State $state
}
elseif ($state.IntendedDomain -ine $exportDomain -or ($state.DomainGuid -and $exportGuid -and $state.DomainGuid -ine $exportGuid)) {
    Write-Host 'The saved migration domain does not match the current export package.' -ForegroundColor Red
    Write-Host "Saved domain : $($state.IntendedDomain) / $($state.DomainGuid)"
    Write-Host "Export domain: $exportDomain / $exportGuid"
    Stop-Wizard 'Stop and use the correct flash drive/export package. The migration state will not be changed automatically.'
    return
}
if ($computerName -ieq $state.SourceServer) {
    Show-Heading 'OLD SERVER CHECKPOINT'
    if ($state.PostCutoverVerified) {
        Write-Host 'The replacement passed post-cutover validation.' -ForegroundColor Green
        if ((Read-Host 'Open the guarded decommission checklist? Type YES or NO') -ceq 'YES') {
            Invoke-ToolkitStep 'Step-05-Decommission-OldServer.ps1'
            $completion = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step05-Completion-*.json"
            if ($completion) {
                $completionResult = Get-Content -LiteralPath $completion.FullName -Raw | ConvertFrom-Json
                if ($completionResult.Ready) {
                    if (Complete-MigrationCleanup -State $state) { return }
                }
                else { Write-Host 'Cleanup is unavailable because the decommission checklist is not READY.' -ForegroundColor Yellow }
            }
        }
        return
    }
    Write-Host 'The export package already identifies this computer as the old server.'
    if ((Read-Host 'Refresh Step 1 before continuing? Type YES or NO') -ceq 'YES') {
        Invoke-ToolkitStep 'Step-01-Export-OldServer.ps1'
    }
    Stop-Wizard 'Move the complete toolkit folder to the differently named replacement server.'
    return
}

$state.TargetServer = $computerName
Save-State $state
Write-Host "Bound migration domain: $($state.IntendedDomain)" -ForegroundColor Cyan
$currentSystem = Get-CimInstance Win32_ComputerSystem
if ($currentSystem.PartOfDomain -and $currentSystem.Domain -ine $state.IntendedDomain) {
    Write-Host "This server is joined to the wrong domain: $($currentSystem.Domain)" -ForegroundColor Red
    Write-Host "Migration is bound to: $($state.IntendedDomain)"
    Stop-Wizard 'Stop. Do not continue until a senior technician reviews the incorrect domain membership.'
    return
}

Show-Heading 'WORKLOAD SAFETY CLASSIFICATION'
$special = @()
if ($manifest.PurposeSignals.DomainController) { $special += 'Domain Controller / DNS' }
if ($manifest.PurposeSignals.HyperV) { $special += 'Hyper-V' }
if (@($manifest.InstalledFeatures) -contains 'Failover-Clustering') { $special += 'Failover Cluster' }
if (@($manifest.InstalledFeatures) -contains 'ADCS-Cert-Authority') { $special += 'Certificate Authority' }
if ($special.Count) {
    Write-Host ('Specialized workloads detected: ' + ($special -join ', ')) -ForegroundColor Yellow
    Write-Host 'The wizard will automate prerequisites but pause for supported role-specific checkpoints.'
}
else { Write-Host 'No high-risk Windows role was identified by the Step 1 manifest.' -ForegroundColor Green }

$step2 = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step02-*-ValidationResults.csv"
if (-not $step2) {
    Show-Heading 'CHECKPOINT 2 OF 7 - VALIDATE THE NEW SERVER'
    Invoke-ToolkitStep 'Step-02-Validate-NewServer.ps1'
    Stop-Wizard 'Review the Step 2 results, correct failures, and rerun Guided Migration.'
    return
}

$step2Results = @(Import-Csv -LiteralPath $step2.FullName)
$step2Failures = @($step2Results | Where-Object Status -eq 'FAIL')
if ($step2Failures.Count) {
    Show-Heading 'CHECKPOINT 2 BLOCKED - READINESS FAILURES'
    $step2Failures | Format-Table Category,Check,Details,Recommendation -Wrap
    if ($manifest.PurposeSignals.DomainController -and ($step2Failures.Check -contains 'Domain Controller Migration')) {
        Write-Host 'The guided AD DS assistant can install prerequisites and create the next-action runbook.'
        if ((Read-Host 'Open the guided AD DS assistant now? Type YES or NO') -ceq 'YES') {
            Invoke-ToolkitStep 'Step-03-MigrateSettings.ps1'
        }
    }
    Stop-Wizard 'Resolve every Step 2 failure, restart if required, then rerun Steps 2 and Guided Migration.'
    return
}

if (@($step2Results | Where-Object Status -eq 'WARN').Count) {
    Show-Heading 'READINESS WARNINGS REQUIRE REVIEW'
    $step2Results | Where-Object Status -eq 'WARN' | Format-Table Category,Check,Details,Recommendation -Wrap
    if ((Read-Host 'Have you reviewed these warnings and accepted or corrected each one? Type WARNINGS REVIEWED or NO') -cne 'WARNINGS REVIEWED') {
        Stop-Wizard 'Review the warnings and rerun Guided Migration.'
        return
    }
}

$step3 = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step03-*-MigrationResults.csv"
if (-not $step3) {
    Show-Heading 'CHECKPOINT 3 OF 7 - PREPARE ROLES, SETTINGS, AND COPY JOBS'
    Invoke-ToolkitStep 'Step-03-MigrateSettings.ps1'
    Stop-Wizard 'Resolve Step 3 failures and review the generated initial/final Robocopy scripts.'
    return
}

$step3Failures = @(Import-Csv -LiteralPath $step3.FullName | Where-Object Status -eq 'FAIL')
if ($step3Failures.Count) {
    Show-Heading 'CHECKPOINT 3 BLOCKED - MIGRATION FAILURES'
    $step3Failures | Format-Table Category,Action,Details,Recommendation -Wrap
    Stop-Wizard 'Correct these failures and rerun Step 3.'
    return
}

$initialScript = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step03-*-Robocopy-Initial.cmd"
$finalScript = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step03-*-Robocopy-Final.cmd"
if (-not $initialScript -or -not $finalScript) {
    Stop-Wizard 'Robocopy jobs are missing. Rerun Step 3 and choose to generate both copy jobs.'
    return
}
if (-not $state.InitialCopyVerified) {
    Show-Heading 'CHECKPOINT 4 OF 7 - INITIAL DATA COPY'
    Write-Host "Initial copy job: $($initialScript.FullName)"
    Write-Host 'Review every source and destination. Run the job as Administrator while the old server remains online.'
    if ((Read-Host 'Did Robocopy finish with exit code 0 through 7 and were the logs reviewed? Type INITIAL COPY VERIFIED or NO') -ceq 'INITIAL COPY VERIFIED') {
        $state.InitialCopyVerified = $true; $state.Phase='InitialCopy'; Save-State $state
    }
    else { Stop-Wizard 'Run and verify the initial copy job, then rerun Guided Migration.'; return }
}

if (-not $state.CutoverApproved) {
    Show-Heading 'CHECKPOINT 5 OF 7 - CUTOVER APPROVAL'
    Write-Host 'Before final copy: notify users, stop applications/services that write to old shares, and verify rollback backups.'
    if ((Read-Host 'Is the approved outage active and are writes to old shares stopped? Type CUTOVER APPROVED or NO') -ceq 'CUTOVER APPROVED') {
        $state.CutoverApproved = $true; $state.Phase='Cutover'; Save-State $state
    }
    else { Stop-Wizard 'Obtain approval and stop source writes before final copy.'; return }
}

if (-not $state.FinalCopyVerified) {
    Show-Heading 'CHECKPOINT 6 OF 7 - FINAL DELTA COPY'
    Write-Host "Final copy job: $($finalScript.FullName)" -ForegroundColor Yellow
    Write-Host 'This job uses /MIR and can remove destination files absent from the source. Review it before running.'
    if ((Read-Host 'Did final Robocopy finish with exit code 0 through 7 and were logs reviewed? Type FINAL COPY VERIFIED or NO') -ceq 'FINAL COPY VERIFIED') {
        $state.FinalCopyVerified = $true; $state.Phase='FinalCopy'; Save-State $state
    }
    else { Stop-Wizard 'Run and verify the final delta job during the outage.'; return }
}

$step4 = Get-LatestFile -Folder $paths.Reports -Pattern "$computerName-Step04-*.csv"
if (-not $step4) {
    Show-Heading 'CHECKPOINT 7 OF 7 - POST-CUTOVER VALIDATION'
    Invoke-ToolkitStep 'Step-04-PostCutover-Validation.ps1'
    Stop-Wizard 'Review post-cutover failures and rerun Guided Migration.'
    return
}

$step4Failures = @(Import-Csv -LiteralPath $step4.FullName | Where-Object Status -eq 'FAIL')
if ($step4Failures.Count) {
    Show-Heading 'POST-CUTOVER VALIDATION FAILED'
    $step4Failures | Format-Table Category,Check,Details -Wrap
    Stop-Wizard 'Correct the failures or execute the rollback plan. Do not decommission the old server.'
    return
}

$state.PostCutoverVerified = $true; $state.Phase='PostCutoverVerified'; Save-State $state
Show-Heading 'MIGRATION VALIDATION COMPLETE'
Write-Host 'No post-cutover FAIL results were found.' -ForegroundColor Green
Write-Host 'Monitor through the approved rollback period. Then move the toolkit back to the old server and run Guided Migration for the decommission checklist.'
Read-Host 'Press Enter to return to the launcher'
