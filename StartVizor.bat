@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_vizor.ps1" %*
if %errorlevel% neq 0 (
    echo.
    echo Launch failed - see messages above.
    pause
)
