@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_LAUNCHER=%SCRIPT_DIR%Start-MigrationToolkit.ps1"

echo ============================================
echo Server Migration Toolkit Launcher
echo ============================================
echo BAT Folder   : %SCRIPT_DIR%
echo PS Launcher  : %PS_LAUNCHER%
echo.

if not exist "%PS_LAUNCHER%" (
    echo ERROR: PowerShell launcher not found.
    echo Expected:
    echo %PS_LAUNCHER%
    echo.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','\"\"%PS_LAUNCHER%\"\"'"
    echo.
    echo If a UAC prompt appeared, approve it.
    pause
    exit /b
)

echo Running PowerShell launcher...
powershell -NoExit -ExecutionPolicy Bypass -File "%PS_LAUNCHER%"

echo.
echo Launcher finished.
pause

endlocal
