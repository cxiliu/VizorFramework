@echo off
setlocal
rem Run the launcher as the first tab of the "Vizor" Windows Terminal window, so the stack's log
rem consoles open as tabs next to it. "%~dp0." avoids a trailing backslash escaping the quote.
if not defined WT_SESSION (
    where wt.exe >nul 2>nul && (
        wt.exe -w Vizor new-tab --title "Vizor launcher" --suppressApplicationTitle -d "%~dp0." powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_vizor.ps1" %*
        exit /b 0
    )
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_vizor.ps1" %*
if %errorlevel% neq 0 (
    echo.
    echo Launch failed - see messages above.
    pause
)
