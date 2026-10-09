# Stops the Docker stacks StartVizor.bat brings up: the Vizor ROS stack
# (compose\vizor-stack.yml) and Vizor Web Control (compose\vizor-web-stack.yml).
#
# Needed because the launcher can be told to leave its containers running so the next launch
# reuses them, and because a hard kill (Task Manager) leaves containers behind that no exit
# handler can catch.
#
# Usage:
#   StopVizor.bat                            # both stacks
#   .\scripts\stop_vizor.ps1 -Vizor          # ROS stack only (plus its relay, in relay mode)
#   .\scripts\stop_vizor.ps1 -WebControl     # web console + MongoDB only
#
# Stopping the web console keeps its MongoDB volume, so logged sessions survive. Discarding them
# is an explicit: docker compose -f compose\vizor-web-stack.yml down -v

param(
    [switch]$Vizor,
    [switch]$WebControl
)

$ErrorActionPreference = 'Stop'
$FrameworkRoot = Split-Path -Parent $PSScriptRoot

# Dot-sourced for the container-name lists and the compose helpers. Deliberately does NOT call
# Register-VizorCleanupOnExit - this script is the teardown.
. (Join-Path $PSScriptRoot 'VizorCommon.ps1')

# No switch means both of them, so the common case stays a bare double-click.
$noneGiven = (-not $Vizor -and -not $WebControl)
$doVizor = $Vizor -or $noneGiven
$doWeb   = $WebControl -or $noneGiven

function Stop-Stack {
    param([string]$Label, [string]$ComposeFile, [string[]]$Containers)

    $running = Get-RunningContainers -Names $Containers
    if ($running.Count -eq 0) {
        Write-Host "$Label - not running, nothing to stop."
        return $false
    }

    if (-not (Test-Path $ComposeFile)) {
        Write-Host "$Label - running ($($running -join ', ')) but the compose file is missing at $ComposeFile."
        Write-Host "  Stop it manually with: docker stop $($running -join ' ')"
        return $false
    }

    Write-Host "$Label - stopping ($($running -join ', '))..."
    try {
        # Out-Host, not the pipeline: docker's own stdout would otherwise be captured into this
        # function's return value alongside the boolean and break the caller's $stoppedAny test.
        Invoke-Compose -ComposeFile $ComposeFile -ComposeArgs @('down') | Out-Host
        Write-Host "$Label - stopped."
        return $true
    } catch {
        Write-Host "$Label - warning: failed to stop cleanly: $_"
        return $false
    }
}

try {
    Write-Host "=== Stop Vizor Docker stacks ==="
    Write-Host ""

    Assert-CommandExists 'docker' "Install Docker Desktop and ensure it's running: https://docs.docker.com/desktop/setup/install/windows-install/"

    $stoppedAny = $false
    if ($doVizor) {
        $stoppedAny = (Stop-Stack -Label 'Vizor ROS stack' `
                                  -ComposeFile (Get-VizorComposeFile -FrameworkRoot $FrameworkRoot) `
                                  -Containers $VizorStackContainers) -or $stoppedAny
        # Relay mode only; it serves nothing without the stack.
        if (@(Get-VizorRelayProcess).Count -gt 0) {
            Write-Host "Vizor relay - stopping..."
            Stop-VizorRelay
            Write-Host "Vizor relay - stopped."
            $stoppedAny = $true
        }
    }
    if ($doWeb) {
        $stoppedAny = (Stop-Stack -Label 'Vizor Web Control' `
                                  -ComposeFile (Get-WebComposeFile -FrameworkRoot $FrameworkRoot) `
                                  -Containers $WebControlContainers) -or $stoppedAny
    }

    Write-Host ""
    if (-not $stoppedAny) {
        Write-Host "Nothing to stop."
    }
    Read-Host "Press Enter to close"
} catch {
    Write-Host ""
    Write-Error $_
    Read-Host "Press Enter to close"
    exit 1
}
