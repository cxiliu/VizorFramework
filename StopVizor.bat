@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop_vizor.ps1" %*
if %errorlevel% neq 0 (
    echo.
    echo Stop failed - see messages above.
    pause
)
