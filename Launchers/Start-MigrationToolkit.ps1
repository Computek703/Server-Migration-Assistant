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

    if (-not (Test-Path $StepsRoot)) {
        throw "Steps folder not found: $StepsRoot"
    }

    :ToolkitMenu do {
        Show-Banner

        Write-Host '1. Guided Migration Wizard (recommended)'
        Write-Host '2. Advanced - Export Old Server'
        Write-Host '3. Advanced - Validate New Server'
        Write-Host '4. Advanced - Migrate Settings'
        Write-Host '5. Advanced - Post-Cutover Validation'
        Write-Host '6. Advanced - Decommission Old Server'
        Write-Host '7. Exit'
        Write-Host ''

        $choice = Read-Host 'Select an option'

        switch ($choice) {
            '1' { Invoke-StepFile -StepFile 'Start-GuidedMigration.ps1' }
            '2' { Invoke-StepFile -StepFile 'Step-01-Export-OldServer.ps1' }
            '3' { Invoke-StepFile -StepFile 'Step-02-Validate-NewServer.ps1' }
            '4' { Invoke-StepFile -StepFile 'Step-03-MigrateSettings.ps1' }
            '5' { Invoke-StepFile -StepFile 'Step-04-PostCutover-Validation.ps1' }
            '6' { Invoke-StepFile -StepFile 'Step-05-Decommission-OldServer.ps1' }
            '7' { break ToolkitMenu }
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
