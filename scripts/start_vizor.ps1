# One-click launcher for the Vizor framework: the Vizor ROS stack (roscore + rosbridge) and the
# Vizor Web Control console (operator UI + MongoDB), plus the optional Windows firewall /
# port-proxy rules that let a HoloLens on the LAN reach into the WSL2-hosted containers.
#
# Self-contained: it reads only the compose files next to it, pulls published images, and needs
# nothing but Docker Desktop. No MaIL checkout, no VizorWebControl checkout, no Python.
#
# Usage: double-click StartVizor.bat (or run this file from a PowerShell prompt).
#
# -Firewall / -RosStack / -WebControl / -Keep / -Relay are not meant to be passed by hand - they
# are how this script carries already-answered prompts across an Administrator elevation relaunch.
# -Relay in particular: the elevated child may run as a different (admin) account whose
# .wslconfig, and so relay-mode detection, differs from the user's.

param(
    [string]$Firewall = $null,
    [string]$RosStack = $null,
    [string]$WebControl = $null,
    [string]$Keep = $null,
    [string]$Relay = $null
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
    param([string]$Firewall, [string]$RosStack, [string]$WebControl, [string]$Keep, [string]$Relay)

    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Host "Firewall setup needs Administrator rights. Relaunching elevated..."
    # $PSCommandPath is quoted: this folder normally lives under a path with spaces.
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                      '-Firewall', $Firewall, '-RosStack', $RosStack, '-WebControl', $WebControl,
                      '-Relay', $Relay)
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

    if (-not $Relay) {
        $Relay = if (Get-VizorRelayMode) { 'on' } else { 'off' }
    }
    $relayMode = ($Relay -eq 'on')
    Set-VizorPublishedPorts -Relay $relayMode
    if ($relayMode) {
        Write-Host "Relay mode: WSL uses mirrored networking (or VIZOR_RELAY=on). Docker publishes on"
        Write-Host "loopback-only internal ports and a relay window serves 9090 / 10000-10003 / 11311 on"
        Write-Host "every network, including this PC's Mobile Hotspot."
        Write-Host ""
    }

    if (-not $Firewall) {
        $Firewall = if (Read-YesNo -Prompt "Set up Windows Firewall / port-proxy rules (for a HoloLens on the LAN)?" -DefaultYes $false) { 'yes' } else { 'no' }
    }
    if (-not $RosStack) {
        $RosStack = if (Read-YesNo -Prompt "Start the Vizor ROS stack (vizor-ros-master + vizor-bridge)?" -DefaultYes $true) { 'yes' } else { 'no' }
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
        Invoke-ElevatedRelaunch -Firewall $Firewall -RosStack $RosStack -WebControl $WebControl -Keep $Keep -Relay $Relay
    }

    Assert-CommandExists 'docker' "Install Docker Desktop and ensure it's running: https://docs.docker.com/desktop/setup/install/windows-install/"

    if ($Firewall -eq 'yes') {
        if ($relayMode) {
            # No port-proxy in relay mode: the relay itself listens on these ports.
            Write-Host "Relay mode: opening the firewall and removing any old port-proxy rules."
            Open-VizorFirewallPorts -WslIp $null
        } else {
            $wslIp = Get-WslIp
            Write-Host "WSL2 IP detected: $wslIp"
            Open-VizorFirewallPorts -WslIp $wslIp
        }
    }

    if ($RosStack -eq 'yes') {
        if (-not $relayMode -and @(Get-VizorRelayProcess).Count -gt 0) {
            # Left over from a relay-mode launch; it holds the real ports Docker needs now.
            Write-Host "Stopping the Vizor relay left over from a relay-mode launch..."
            Stop-VizorRelay
        }
        Start-VizorDockerStack -FrameworkRoot $FrameworkRoot
        if ($relayMode) {
            Start-VizorRelay -FrameworkRoot $FrameworkRoot
        }
    }

    # Started before the rosbridge wait so a first-run image pull overlaps with the ROS stack's boot.
    if ($WebControl -eq 'yes') {
        Start-VizorWebControlStack -FrameworkRoot $FrameworkRoot
    }

    if ($RosStack -eq 'yes') {
        # A warning rather than a throw: nothing here is waiting to connect to rosbridge, so a slow
        # stack is worth reporting but not worth aborting the launch over.
        # Probes Docker's own port, not the relay's: the relay accepts connections even while
        # rosbridge is still down.
        $rosbridgePort = Get-VizorRosbridgeHostPort
        if (Wait-ForPort -TargetHost '127.0.0.1' -Port $rosbridgePort -Label "rosbridge at 127.0.0.1:$rosbridgePort") {
            Write-Host "rosbridge is reachable at 127.0.0.1:$rosbridgePort."
        } else {
            Write-Host "Warning: rosbridge did not become reachable at 127.0.0.1:$rosbridgePort within the timeout."
            Write-Host "  Check the docker window for errors (image pull failure, container crash, roslaunch failure)."
        }

        if ($relayMode) {
            if (Test-VizorRelayListening) {
                Write-Host "The relay is serving ports $($VizorRelayPorts.Keys -join ', ')."
            } else {
                Write-Host "Warning: the relay is not listening on all of $($VizorRelayPorts.Keys -join ', ')."
                Write-Host "  Its window says why - usually an old port-proxy rule (netsh interface portproxy show all)."
            }
        }

        # The addresses an XR client can use, so nobody has to dig through ipconfig.
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } |
                       ForEach-Object { "$($_.IPAddress) ($($_.InterfaceAlias))" })
        if ($addresses.Count -gt 0) {
            Write-Host ""
            Write-Host "XR clients can connect to this PC at:"
            $addresses | ForEach-Object { Write-Host "  $_" }
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
