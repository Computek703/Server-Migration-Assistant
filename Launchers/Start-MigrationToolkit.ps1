[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ProjectRoot = Split-Path -Parent $ScriptRoot
    $StepsRoot   = Join-Path $ProjectRoot 'Steps'

    function Show-Banner {
        Clear-Host
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host '              Server Migration Toolkit Launcher             ' -ForegroundColor Cyan
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host "Script Root  : $ScriptRoot"
        Write-Host "Project Root : $ProjectRoot"
        Write-Host "Steps Folder : $StepsRoot"
        Write-Host ''
    }

    function Pause-Toolkit {
        Write-Host ''
        Read-Host 'Press Enter to continue'
    }

    function Invoke-StepFile {
        param(
            [Parameter(Mandatory)]
            [string]$StepFile
        )

        $fullPath = Join-Path $StepsRoot $StepFile

        if (-not (Test-Path $fullPath)) {
            Write-Host "[ERROR] Step file not found: $fullPath" -ForegroundColor Red
            Pause-Toolkit
            return
        }

        try {
            Write-Host ''
            Write-Host "Running: $StepFile" -ForegroundColor Yellow
            Write-Host '------------------------------------------------------------' -ForegroundColor Yellow

            & $fullPath
        }
        catch {
            Write-Host ''
            Write-Host "[ERROR] Failed to run $StepFile" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        Pause-Toolkit
    }

    function Show-TroubleshootingMenu {
        do {
            Show-Banner
            Write-Host 'Troubleshooting Tools' -ForegroundColor Yellow
            Write-Host 'Use these only when the wizard tells you to rerun a specific phase.'
            Write-Host ''
            Write-Host '1. Export / refresh old-server inventory'
            Write-Host '2. Validate new-server readiness'
            Write-Host '3. Prepare roles, settings, and copy jobs'
            Write-Host '4. Run post-cutover validation'
            Write-Host '5. Open old-server decommission checklist'
            Write-Host '6. Return to main menu'
            Write-Host ''
            $advancedChoice = Read-Host 'Select a troubleshooting tool'
            switch ($advancedChoice) {
                '1' { Invoke-StepFile -StepFile 'Step-01-Export-OldServer.ps1' }
                '2' { Invoke-StepFile -StepFile 'Step-02-Validate-NewServer.ps1' }
                '3' { Invoke-StepFile -StepFile 'Step-03-MigrateSettings.ps1' }
                '4' { Invoke-StepFile -StepFile 'Step-04-PostCutover-Validation.ps1' }
                '5' { Invoke-StepFile -StepFile 'Step-05-Decommission-OldServer.ps1' }
                '6' { return }
                default { Write-Host '[WARN] Invalid selection.' -ForegroundColor Yellow; Pause-Toolkit }
            }
        } while ($true)
    }

    if (-not (Test-Path $StepsRoot)) {
        throw "Steps folder not found: $StepsRoot"
    }

    :ToolkitMenu do {
        Show-Banner

        Write-Host '1. Start or Resume Migration (recommended)'
        Write-Host '2. Troubleshooting Tools'
        Write-Host '3. Exit'
        Write-Host ''

        $choice = Read-Host 'Select an option'

        switch ($choice) {
            '1' { Invoke-StepFile -StepFile 'Start-GuidedMigration.ps1' }
            '2' { Show-TroubleshootingMenu }
            '3' { break ToolkitMenu }
            default {
                Write-Host ''
                Write-Host '[WARN] Invalid selection.' -ForegroundColor Yellow
                Pause-Toolkit
            }
        }

    } while ($true)
}
catch {
    Write-Host ''
    Write-Host 'FATAL LAUNCHER ERROR' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Read-Host 'Press Enter to close'
}
