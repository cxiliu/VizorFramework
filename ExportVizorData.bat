@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\export_vizor_data.ps1" %*
if %errorlevel% neq 0 (
    echo.
    echo Export failed - see messages above.
)
pause
