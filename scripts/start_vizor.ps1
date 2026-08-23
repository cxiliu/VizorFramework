# One-click launcher for the Vizor framework: the Vizor ROS stack (roscore + rosbridge) and the
# Vizor Web Control console (operator UI + MongoDB), plus the optional Windows firewall /
# port-proxy rules that let a HoloLens on the LAN reach into the WSL2-hosted containers.
#
# Self-contained: it reads only the compose files next to it, pulls published images, and needs
# nothing but Docker Desktop. No MaIL checkout, no VizorWebControl checkout, no Python.
#
# Usage: double-click StartVizor.bat (or run this file from a PowerShell prompt).
#
# -Firewall / -RosStack / -WebControl / -Keep are not meant to be passed by hand - they are how
# this script carries already-answered prompts across an Administrator elevation relaunch.

param(
    [string]$Firewall = $null,
    [string]$RosStack = $null,
    [string]$WebControl = $null,
    [string]$Keep = $null
)

$ErrorActionPreference = 'Stop'
$FrameworkRoot = Split-Path -Parent $PSScriptRoot

# What to say at the very end. Set to $null once a "press Enter" hold has already happened.
$script:ClosePrompt = "Press Enter to close this window"

. (Join-Path $PSScriptRoot 'VizorCommon.ps1')
Register-VizorCleanupOnExit -FrameworkRoot $FrameworkRoot

function Invoke-ElevatedRelaunch {
    # Firewall / port-proxy setup needs Administrator rights. Re-runs this script elevated, carrying
    # the already-given answers so the child picks up where this one left off, then exits the
    # unelevated parent. Returns (does nothing) when already elevated.
    param([string]$Firewall, [string]$RosStack, [string]$WebControl, [string]$Keep)

    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Host "Firewall setup needs Administrator rights. Relaunching elevated..."
    # $PSCommandPath is quoted: this folder normally lives under a path with spaces.
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                      '-Firewall', $Firewall, '-RosStack', $RosStack, '-WebControl', $WebControl)
    if ($Keep) { $relaunchArgs += @('-Keep', $Keep) }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArgs -ErrorAction Stop
    } catch {
        Write-Error "Elevation was declined or failed: $_`nRe-run and answer 'n' to the firewall question to skip elevation entirely."
        exit 1
    }
    exit 0
}

function Invoke-Main {
    Write-Host "=== Vizor Framework Launcher ==="
    Write-Host ""

    if (-not $Firewall) {
        $Firewall = if (Read-YesNo -Prompt "Set up Windows Firewall / port-proxy rules (for a HoloLens on the LAN)?" -DefaultYes $false) { 'yes' } else { 'no' }
    }
    if (-not $RosStack) {
        $RosStack = if (Read-YesNo -Prompt "Start the Vizor ROS stack (ros-core + vizor-demo)?" -DefaultYes $true) { 'yes' } else { 'no' }
    }
    # Independent of the ROS stack question on purpose: the console is a rosbridge consumer, so it
    # is equally useful against a stack started earlier or one running on another machine.
    if (-not $WebControl) {
        $WebControl = if (Read-YesNo -Prompt "Start the Vizor Web Control console (operator UI + MongoDB)?" -DefaultYes $true) { 'yes' } else { 'no' }
    }

    if (($RosStack -eq 'no') -and ($WebControl -eq 'no')) {
        throw "Nothing to start: both stacks were declined. Re-run and answer 'y' to at least one of them."
    }

    if (-not $Keep) {
        $Keep = if (Read-YesNo -Prompt "Leave the containers running after this window closes? (no = stop them on exit)" -DefaultYes $true) { 'yes' } else { 'no' }
    }
    $global:VizorKeepDockerOnExit = ($Keep -eq 'yes')
    # An explicit "no" stops the stacks this launch uses even if it inherited them.
    $global:VizorTeardownAll = ($Keep -eq 'no')

    if ($Firewall -eq 'yes') {
        Invoke-ElevatedRelaunch -Firewall $Firewall -RosStack $RosStack -WebControl $WebControl -Keep $Keep
    }

    Assert-CommandExists 'docker' "Install Docker Desktop and ensure it's running: https://docs.docker.com/desktop/setup/install/windows-install/"

    if ($Firewall -eq 'yes') {
        $wslIp = Get-WslIp
        Write-Host "WSL2 IP detected: $wslIp"
        Open-VizorFirewallPorts -WslIp $wslIp
    }

    if ($RosStack -eq 'yes') {
        Start-VizorDockerStack -FrameworkRoot $FrameworkRoot
    }

    # Started before the rosbridge wait so a first-run image pull overlaps with the ROS stack's boot.
    if ($WebControl -eq 'yes') {
        Start-VizorWebControlStack -FrameworkRoot $FrameworkRoot
    }

    if ($RosStack -eq 'yes') {
        # A warning rather than a throw: nothing here is waiting to connect to rosbridge, so a slow
        # stack is worth reporting but not worth aborting the launch over.
        if (Wait-ForPort -TargetHost '127.0.0.1' -Port 9090 -Label "rosbridge at 127.0.0.1:9090") {
            Write-Host "rosbridge is reachable at 127.0.0.1:9090."
        } else {
            Write-Host "Warning: rosbridge did not become reachable at 127.0.0.1:9090 within the timeout."
            Write-Host "  Check the docker window for errors (image pull failure, container crash, roslaunch failure)."
        }
    }

    if ($WebControl -eq 'yes') {
        Confirm-VizorWebControlReady
    }

    Write-Host ""
    Write-Host "Vizor is up."
    if ($global:VizorKeepDockerOnExit) {
        Write-Host "The containers keep running after this window closes. Stop them later with: StopVizor.bat"
    } else {
        Write-Host "The containers will be stopped when you close this window."
        Write-Host ""
        Read-Host "Press Enter to stop the containers and close" | Out-Null
        Invoke-VizorCleanup -FrameworkRoot $FrameworkRoot
        # Already held the window and cleaned up - don't ask for Enter a second time.
        $script:ClosePrompt = $null
    }
}

try {
    Invoke-Main
    if ($script:ClosePrompt) {
        Write-Host ""
        Read-Host $script:ClosePrompt
    }
} catch {
    Write-Host ""
    Write-Error $_
    Read-Host "Press Enter to close"
    exit 1
}
