# Shared helpers for start_vizor.ps1 and stop_vizor.ps1. Dot-source this file, do not run directly.
#
# Everything here resolves paths from the -FrameworkRoot handed in by the caller (the folder holding
# StartVizor.bat), so this folder can be copied or zipped anywhere and still work. Nothing outside
# it is referenced.

# Fixed by container_name: in the compose files - used to detect stacks that are already up.
# The names match MaIL's launcher on purpose: a stack a developer already brought up from there is
# then reused rather than colliding by name.
$VizorStackContainers  = @('vizor-bridge', 'vizor-ros-master')
$WebControlContainers  = @('vizor-web', 'vizor-mongo')

# Relay mode: client-facing port -> the loopback-only port Docker publishes it on instead.
# See Get-VizorRelayMode.
$VizorRelayPorts = [ordered]@{
    9090  = 19090
    10000 = 20000
    10001 = 20001
    10002 = 20002
    10003 = 20003
    11311 = 21311
}

# Tracks which docker stacks THIS process actually started, as opposed to inherited from a previous
# launch. Used when the user was never asked what to do on exit: then cleanup is conservative and
# only tears down what it started itself.
$global:VizorStartedStack      = $false
$global:VizorStartedWebControl = $false
$global:VizorCleanupDone       = $false

# Tracks which stacks this launch is USING - started or reused. When the user explicitly answers
# "no" to the keep-running question their answer wins over ownership, and these are what gets torn
# down. Without this, "no" was almost always a no-op: the question defaults to yes, so containers
# survive, so the next launch inherits them, so it owns nothing and stops nothing.
$global:VizorUsingStack      = $false
$global:VizorUsingWebControl = $false

# $true only when the user explicitly asked for teardown (answered "no" to keep-running).
$global:VizorTeardownAll = $false

# When true, Invoke-VizorCleanup is a no-op: the user asked to leave the containers up so the next
# launch can reuse them instead of re-pulling and re-booting the stack.
$global:VizorKeepDockerOnExit = $false

# Whether this process started the relay window (relay mode only).
$global:VizorStartedRelay = $false

function Assert-CommandExists {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' was not found on PATH. $Hint"
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $raw = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultYes }
    return $raw.Trim().ToLower().StartsWith('y')
}

function Get-WslIp {
    Assert-CommandExists 'wsl.exe' "Install WSL2 and Docker Desktop's WSL2 backend before using the firewall option."
    $raw = (wsl.exe -e hostname -I) 2>$null
    if ($raw -match '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') {
        return $matches[0]
    }
    throw "Could not detect the WSL2 IP address via 'wsl.exe hostname -I'. Ensure Docker Desktop's WSL2 backend " +
          "is running and a default WSL distro is installed."
}

function Open-VizorFirewallPorts {
    # Opens the Vizor ports in the firewall, so a HoloLens (or anything else on the LAN) can reach
    # them. With a WSL IP it also forwards them from this Windows host into the WSL2 VM. Without
    # one (relay mode) it only removes stale port-proxy rules: there the relay owns these ports,
    # and a port-proxy rule on them would hold them and lock both the relay and Docker out.
    # Requires Administrator - the caller elevates before getting here.
    param([string]$WslIp)
    $ports = @(10000, 10001, 10002, 10003, 11311, 9090)
    foreach ($port in $ports) {
        Write-Host "Opening port $port..."
        Invoke-Expression "netsh interface portproxy delete v4tov4 listenport=$port" | Out-Null
        Invoke-Expression "netsh advfirewall firewall delete rule name=$port" | Out-Null
        if ($WslIp) {
            Invoke-Expression "netsh interface portproxy add v4tov4 listenport=$port connectport=$port connectaddress=$WslIp" | Out-Null
        }
        Invoke-Expression "netsh advfirewall firewall add rule name=$port dir=in action=allow protocol=TCP localport=$port" | Out-Null
    }
    if (-not $WslIp) {
        # The relay runs in powershell.exe. Dismissing Windows' "allow access?" prompt for
        # PowerShell without admin rights leaves "Query User" block rules for it, and a block
        # rule beats the port allow rules above - the relay would then be unreachable from the
        # LAN while still working from this PC.
        $blocks = @(Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*Query User*' } |
                    Where-Object { ($_ | Get-NetFirewallApplicationFilter).Program -like '*\WindowsPowerShell\v1.0\powershell.exe' })
        if ($blocks.Count -gt 0) {
            Write-Host "Removing $($blocks.Count) Windows Firewall block rule(s) for PowerShell left by a dismissed prompt..."
            $blocks | Remove-NetFirewallRule
        }
    }
    netsh interface portproxy show v4tov4
}

function Test-WslMirroredNetworking {
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path $wslConfig)) { return $false }
    foreach ($line in Get-Content $wslConfig) {
        if ($line -match '^\s*networkingMode\s*=\s*mirrored\s*([#;].*)?$') { return $true }
    }
    return $false
}

function Get-VizorRelayMode {
    # Relay mode exists for WSL mirrored networking. There a port Docker publishes lives inside the
    # WSL VM and is reachable only through the host adapters WSL mirrors - not the Windows Mobile
    # Hotspot one - and Windows cannot listen on a port the VM holds. So Docker moves to
    # loopback-only internal ports ($VizorRelayPorts) and scripts\vizor_relay.ps1, a plain
    # Windows listener reachable on every adapter, serves the real ones.
    # VIZOR_RELAY=on / off overrides the detection.
    switch (("$env:VIZOR_RELAY").Trim().ToLower()) {
        'on'  { return $true }
        'off' { return $false }
    }
    return (Test-WslMirroredNetworking)
}

function Set-VizorPublishedPorts {
    # Sets the variables compose\vizor-stack.yml reads for its host-side ports. Child processes
    # (the stack's log window) inherit them. Cleared, the compose defaults apply: the real ports
    # on all interfaces.
    param([bool]$Relay)
    # GetEnumerator, not $VizorRelayPorts[$port]: an [ordered] table indexed with an int looks
    # up by position, not by key.
    foreach ($entry in $VizorRelayPorts.GetEnumerator()) {
        $value = if ($Relay) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable("VIZOR_HOST_PORT_$($entry.Key)", $value, 'Process')
    }
    $prefix = if ($Relay) { '127.0.0.1:' } else { $null }
    [Environment]::SetEnvironmentVariable('VIZOR_PUBLISH_PREFIX', $prefix, 'Process')
}

function Get-VizorRosbridgeHostPort {
    # Where Docker publishes rosbridge on this host, under the current Set-VizorPublishedPorts.
    if ($env:VIZOR_HOST_PORT_9090) { return [int]$env:VIZOR_HOST_PORT_9090 }
    return 9090
}

function Get-VizorRelayProcess {
    # Callers wrap this in @(...): a single CimInstance comes back unwrapped and has no .Count.
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -like '*vizor_relay.ps1*' })
}

function Start-VizorRelay {
    param([string]$FrameworkRoot)

    if (@(Get-VizorRelayProcess).Count -gt 0) {
        Write-Host "Reusing the Vizor relay already running."
        return
    }
    $map = ($VizorRelayPorts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
    $relayScript = Join-Path $FrameworkRoot 'scripts\vizor_relay.ps1'
    Write-Host "Starting the Vizor relay in a separate window..."
    # Quoted for the same reason as the elevation relaunch: this folder may live under a path
    # with spaces.
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$relayScript`"", '-PortMap', $map) `
        -WorkingDirectory $FrameworkRoot
    $global:VizorStartedRelay = $true
}

function Test-VizorRelayListening {
    # True when the relay process holds every client-facing port - not merely when something
    # does, since a stale port-proxy rule on them would pass a plain connect test.
    param([int]$TimeoutSec = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $relayIds = @(Get-VizorRelayProcess | ForEach-Object { $_.ProcessId })
        if ($relayIds.Count -gt 0) {
            $held = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                      Where-Object { ($relayIds -contains $_.OwningProcess) -and ($VizorRelayPorts.Keys -contains $_.LocalPort) } |
                      ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
            if ($held.Count -eq $VizorRelayPorts.Count) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-VizorRelay {
    foreach ($relay in Get-VizorRelayProcess) {
        Stop-Process -Id $relay.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-ComposeExe {
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) { return 'docker-compose' }
    return 'docker compose'
}

function Invoke-Compose {
    # 'docker compose' is two tokens, so it cannot be invoked through a single variable the way
    # 'docker-compose' can - this splats whichever form is available over the same arguments.
    param([string]$ComposeFile, [string[]]$ComposeArgs)
    if ((Get-ComposeExe) -eq 'docker-compose') {
        docker-compose -f $ComposeFile @ComposeArgs
    } else {
        docker compose -f $ComposeFile @ComposeArgs
    }
}

function Get-RunningContainers {
    # Returns the subset of $Names that docker currently reports as running. Callers use the
    # count to decide between reuse (all up), gap-filling (some up) and a cold start (none up).
    param([string[]]$Names)
    $running = @(docker ps --format '{{.Names}}' 2>$null)
    return @($Names | Where-Object { $running -contains $_ })
}

function Get-VizorComposeFile {
    param([string]$FrameworkRoot)
    return (Join-Path $FrameworkRoot 'compose\vizor-stack.yml')
}

function Get-WebComposeFile {
    param([string]$FrameworkRoot)
    return (Join-Path $FrameworkRoot 'compose\vizor-web-stack.yml')
}

function Start-VizorDockerStack {
    param([string]$FrameworkRoot)

    $composeFile = Get-VizorComposeFile -FrameworkRoot $FrameworkRoot
    if (-not (Test-Path $composeFile)) {
        throw "Compose file not found at $composeFile"
    }

    # Reuse a stack that is already up rather than starting a duplicate - and, crucially, do NOT
    # set the ownership flag in that case, so cleanup never tears down containers we inherited.
    $global:VizorUsingStack = $true

    $alreadyUp = Get-RunningContainers -Names $VizorStackContainers
    if ($alreadyUp.Count -eq $VizorStackContainers.Count) {
        # A stack started in the other mode (relay vs. real ports) publishes on the wrong ports:
        # 'up -d' recreates exactly the containers whose ports changed.
        $expected = Get-VizorRosbridgeHostPort
        $published = @(docker port vizor-bridge 9090 2>$null)
        if (($published.Count -gt 0) -and ($published[0] -match ':(\d+)$') -and ([int]$matches[1] -ne $expected)) {
            Write-Host "The running Vizor stack publishes rosbridge on host port $($matches[1]), but this launch needs $expected."
            Write-Host "Recreating it on the right ports..."
            Invoke-Compose -ComposeFile $composeFile -ComposeArgs @('up', '-d') | Out-Host
            return
        }
        Write-Host "Reusing the Vizor stack already running ($($VizorStackContainers -join ', ')) - skipping startup."
        return
    }
    if ($alreadyUp.Count -gt 0) {
        $missing = $VizorStackContainers | Where-Object { $alreadyUp -notcontains $_ }
        Write-Host "Warning: the Vizor stack is only partly up (running: $($alreadyUp -join ', '); missing: $($missing -join ', '))."
        Write-Host "Starting the missing container(s)."
        Invoke-Compose -ComposeFile $composeFile -ComposeArgs @('up', '-d')
        return
    }

    $composeExe = Get-ComposeExe

    # Build the child window's commands as a temp script rather than an inline -Command string.
    # A compound "-Command" string containing embedded quoted paths does not reliably survive
    # Start-Process's re-quoting when the path itself contains spaces - and this folder normally
    # lives under "...\AR Project\...", so that is not hypothetical. Writing to a file and using
    # -File sidesteps that command-line re-quoting entirely.
    #
    # 'up -d' followed by 'logs -f' rather than a foreground 'up': the log stream looks the same,
    # but the containers' lifetime is no longer tied to this window. Foreground 'up' installs a
    # SIGINT handler that stops the containers, so whether they survived depended on exactly how
    # the window died - which defeats the point of leaving them running for the next launch.
    $escapedComposeFile = $composeFile -replace "'", "''"
    $scriptBody = @"
docker pull cxy201/noetic-vizor:v1.2
$composeExe -f '$escapedComposeFile' up -d
$composeExe -f '$escapedComposeFile' logs -f
"@
    $tempScript = Join-Path $env:TEMP ("vizor_docker_stack_{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $tempScript -Value $scriptBody -Encoding UTF8

    Write-Host "Starting the Vizor ROS stack in a separate window..."
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoExit', '-File', $tempScript) `
        -WorkingDirectory $FrameworkRoot
    $global:VizorStartedStack = $true
}

function Start-VizorWebControlStack {
    param([string]$FrameworkRoot)

    $composeFile = Get-WebComposeFile -FrameworkRoot $FrameworkRoot
    if (-not (Test-Path $composeFile)) {
        throw "Compose file not found at $composeFile"
    }

    # An already-running stack is still refreshed through Compose below, so the latest published
    # image is used. The ownership flag stays $false when the containers were inherited, so cleanup
    # never tears down containers this launch did not start.
    $global:VizorUsingWebControl = $true

    $alreadyUp = Get-RunningContainers -Names $WebControlContainers
    if ($alreadyUp.Count -eq $WebControlContainers.Count) {
        Write-Host "Refreshing the Vizor Web Control stack already running ($($WebControlContainers -join ', ')) with the latest image."
    }
    elseif ($alreadyUp.Count -gt 0) {
        $missing = $WebControlContainers | Where-Object { $alreadyUp -notcontains $_ }
        Write-Host "Warning: the Vizor Web Control stack is only partly up (running: $($alreadyUp -join ', '); missing: $($missing -join ', '))."
        Write-Host "Starting the missing container(s)."
    }

    $composeExe = Get-ComposeExe

    # Temp script + separate window, for the same reasons as Start-VizorDockerStack: a compound
    # "-Command" string with an embedded space-bearing path does not survive Start-Process's
    # re-quoting, and 'up -d' + 'logs -f' decouples the containers' lifetime from that window.
    #
    # '--pull always' refreshes the floating tag and recreates the service when its digest changes.
    # First launch downloads roughly 600 MB.
    $escapedComposeFile = $composeFile -replace "'", "''"
    $scriptBody = @"
$composeExe -f '$escapedComposeFile' up -d --pull always
$composeExe -f '$escapedComposeFile' logs -f
"@
    $tempScript = Join-Path $env:TEMP ("vizor_web_control_{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $tempScript -Value $scriptBody -Encoding UTF8

    Write-Host "Starting Vizor Web Control (console + MongoDB) in a separate window..."
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoExit', '-File', $tempScript) `
        -WorkingDirectory $FrameworkRoot
    $global:VizorStartedWebControl = $true

    # Deliberately returns without waiting: a first-run image pull then overlaps with the ROS
    # stack's boot instead of serializing behind it. Confirm-VizorWebControlReady does the waiting.
}

function Wait-ForPort {
    param(
        [string]$TargetHost = '127.0.0.1',
        [int]$Port = 9090,
        [int]$TimeoutSec = 120,
        [int]$IntervalSec = 2,
        [string]$Label = $null
    )
    $what = if ($Label) { $Label } else { "${TargetHost}:${Port}" }
    Write-Host "Waiting for $what ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
            $connected = $iar.AsyncWaitHandle.WaitOne(1500, $false) -and $client.Connected
            $client.Close()
            if ($connected) { return $true }
        } catch { }
        Write-Host ("  ... still waiting ({0}s elapsed)" -f [int]$sw.Elapsed.TotalSeconds)
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function Wait-ForHttpOk {
    # Wait-ForPort proves only that a socket accepts. The web console needs a real 200 before the
    # browser is worth opening, since the port is published as soon as the container starts.
    # The default timeout is long because the FIRST launch pulls a ~600 MB image and the caller
    # waits through that.
    param(
        [string]$Url,
        [int]$TimeoutSec = 300,
        [int]$IntervalSec = 3,
        [string]$Label = $null
    )
    $what = if ($Label) { $Label } else { $Url }
    Write-Host "Waiting for $what ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { return $true }
        } catch { }
        Write-Host ("  ... still waiting ({0}s elapsed)" -f [int]$sw.Elapsed.TotalSeconds)
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function Confirm-VizorWebControlReady {
    $url = 'http://127.0.0.1:8000'
    $ready = Wait-ForHttpOk -Url "$url/health" -Label "Vizor Web Control at http://localhost:8000"
    if (-not $ready) {
        Write-Host "Warning: the Vizor Web Control console did not answer /health within the timeout."
        Write-Host "  Check its docker window for pull or startup errors."
        return
    }
    Write-Host "Opening the Vizor Web Control console at http://localhost:8000 ..."
    Start-Process 'http://localhost:8000'
    Write-Host "Note: 'ros_connected' can take ~2.5 min to turn true after a cold start of the Vizor"
    Write-Host "stack (MoveIt boots before rosbridge, then the backend waits out its retry backoff)."
}

function Invoke-VizorCleanup {
    # No -FrameworkRoot given (e.g. when called from the PowerShell.Exiting event action, where
    # -MessageData does not reliably propagate to $Event.MessageData for this event source)
    # falls back to the global set by Register-VizorCleanupOnExit.
    param([string]$FrameworkRoot = $global:VizorFrameworkRoot)

    if ($global:VizorCleanupDone) { return }
    $global:VizorCleanupDone = $true

    if ($global:VizorKeepDockerOnExit) {
        Write-Host ""
        Write-Host "Leaving the Docker containers running as requested - the next launch will reuse them."
        Write-Host "Stop them later with: StopVizor.bat"
        return
    }

    # Deliberately inlined rather than routed through Get-ComposeExe/Invoke-Compose: this function
    # also runs from the PowerShell.Exiting action (the "user closed the window" path), which
    # executes in a separate scope during a short shutdown grace period. Keeping it free of
    # sibling-function calls keeps that fragile path working - same reason $FrameworkRoot arrives
    # via a global rather than -MessageData.
    $composeExe = if (Get-Command docker-compose -ErrorAction SilentlyContinue) { 'docker-compose' } else { 'docker compose' }

    # An explicit "no" to the keep-running question wins over ownership: tear down every stack this
    # launch used, including ones it inherited. Without an explicit answer, stay conservative and
    # only touch what this launch started.
    if ($global:VizorTeardownAll) {
        $downVizor = $global:VizorUsingStack
        $downWeb   = $global:VizorUsingWebControl
    } else {
        $downVizor = $global:VizorStartedStack
        $downWeb   = $global:VizorStartedWebControl
    }

    if ($downVizor) {
        $vizorCompose = Join-Path $FrameworkRoot 'compose\vizor-stack.yml'
        if (Test-Path $vizorCompose) {
            Write-Host "Stopping the Vizor ROS stack (compose down)..."
            try {
                if ($composeExe -eq 'docker-compose') { docker-compose -f $vizorCompose down } else { docker compose -f $vizorCompose down }
            } catch {
                Write-Host "Warning: failed to stop the Vizor ROS stack cleanly: $_"
            }
        }
        # The relay (relay mode only) serves nothing without the stack. Inlined for the same
        # reason as the compose call above.
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*vizor_relay.ps1*' } |
            ForEach-Object {
                Write-Host "Stopping the Vizor relay..."
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    }

    if ($downWeb) {
        $webCompose = Join-Path $FrameworkRoot 'compose\vizor-web-stack.yml'
        if (Test-Path $webCompose) {
            Write-Host "Stopping Vizor Web Control (compose down)..."
            try {
                # No '-v': the named volume, and with it every logged session, must survive a
                # normal teardown. Discarding the data stays an explicit 'down -v'.
                if ($composeExe -eq 'docker-compose') { docker-compose -f $webCompose down } else { docker compose -f $webCompose down }
            } catch {
                Write-Host "Warning: failed to stop Vizor Web Control cleanly: $_"
            }
        }
    }
}

function Register-VizorCleanupOnExit {
    param([string]$FrameworkRoot)

    # $FrameworkRoot is stashed in a global rather than passed via -MessageData: $Event.MessageData
    # comes back $null for the PowerShell.Exiting engine event source (unlike object events), even
    # though -MessageData is accepted without error.
    $global:VizorFrameworkRoot = $FrameworkRoot

    # Best-effort: PowerShell.Exiting fires on a normal script end and, per Windows console
    # shutdown handling, generally also on closing the console window (e.g. clicking X) - it
    # gives a short grace period to run cleanup before the process is force-terminated. It
    # cannot intercept a hard kill (e.g. Task Manager "End Task"); nothing in user space can.
    Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        Invoke-VizorCleanup
    } | Out-Null
}
