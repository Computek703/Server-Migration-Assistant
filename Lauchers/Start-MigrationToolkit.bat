
@echo off
setlocal

REM Get the folder this BAT is running from
set "SCRIPT_DIR=%~dp0"

REM PowerShell launcher path
set "PS_LAUNCHER=%SCRIPT_DIR%Start-MigrationToolkit.ps1"

REM Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c cd /d ""%SCRIPT_DIR%"" ^&^& ""%~f0""' -Verb RunAs"
    exit /b
)

REM Verify the PowerShell launcher exists
if not exist "%PS_LAUNCHER%" (
    echo ERROR: Could not find:
    echo %PS_LAUNCHER%
    pause
    exit /b 1
)

REM Launch PowerShell menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_LAUNCHER%"

endlocal
