# Windows-side TCP relay for relay mode (see Get-VizorRelayMode in VizorCommon.ps1).
#
# Under WSL mirrored networking, a port Docker publishes lives inside the WSL VM and is only
# reachable through the host adapters WSL mirrors - not, notably, the Windows Mobile Hotspot one.
# This relay is an ordinary Windows listener on the real ports, so it is reachable on every
# adapter, and it forwards each connection to the loopback port Docker publishes on instead
# (loopback is always forwarded into the VM). It copies bytes only, so raw TCP and WebSocket
# traffic pass through unchanged.
#
# Started by start_vizor.ps1 in its own window; stopped by closing that window, by Ctrl+C, or by
# StopVizor.bat.
#
# Usage: .\vizor_relay.ps1 -PortMap "9090=19090,10000=20000"   (listen port = loopback target port)

param(
    [Parameter(Mandatory = $true)][string]$PortMap
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Vizor relay'

# C# 5 (the compiler Add-Type uses on Windows PowerShell 5.1): no string interpolation.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;

public static class VizorRelay
{
    static readonly object LogLock = new object();

    static void Log(string message)
    {
        lock (LogLock) { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  " + message); }
    }

    // Binds every listen port before accepting anything, so a port that is already taken fails the
    // whole relay up front instead of leaving it half working.
    public static Task Start(int[] listenPorts, int[] targetPorts)
    {
        var listeners = new List<TcpListener>();
        try
        {
            foreach (int port in listenPorts)
            {
                // Dual-mode IPv6 socket: also accepts IPv4, so both 127.0.0.1 and "localhost"
                // (which resolves to ::1 first) work on this PC.
                var listener = new TcpListener(IPAddress.IPv6Any, port);
                listener.Server.DualMode = true;
                listener.Start();
                listeners.Add(listener);
            }
        }
        catch
        {
            foreach (var listener in listeners) listener.Stop();
            throw;
        }

        var loops = new List<Task>();
        for (int i = 0; i < listeners.Count; i++)
        {
            Log("Listening on " + listenPorts[i] + " -> 127.0.0.1:" + targetPorts[i]);
            loops.Add(AcceptLoop(listeners[i], listenPorts[i], targetPorts[i]));
        }
        return Task.WhenAll(loops);
    }

    static async Task AcceptLoop(TcpListener listener, int listenPort, int targetPort)
    {
        while (true)
        {
            TcpClient client = await listener.AcceptTcpClientAsync();
            var ignored = Handle(client, listenPort, targetPort);
        }
    }

    static async Task Handle(TcpClient client, int listenPort, int targetPort)
    {
        string peer = Describe(client);
        var upstream = new TcpClient(AddressFamily.InterNetwork);
        bool connected = false;
        try
        {
            client.NoDelay = true;
            upstream.NoDelay = true;
            await upstream.ConnectAsync(IPAddress.Loopback, targetPort);
            connected = true;
            Log(peer + " -> " + listenPort + "  connected");

            NetworkStream clientStream = client.GetStream();
            NetworkStream upstreamStream = upstream.GetStream();
            Task toUpstream = Pump(clientStream, upstreamStream, upstream.Client);
            Task toClient = Pump(upstreamStream, clientStream, client.Client);

            // A clean end of one direction is passed on as a half-close and the other direction
            // is allowed to finish; an error in either one tears down both.
            Task first = await Task.WhenAny(toUpstream, toClient);
            await first;
            await (first == toUpstream ? toClient : toUpstream);
        }
        catch (Exception e)
        {
            if (!connected)
                Log(peer + " -> " + listenPort + "  FAILED: nothing answers on 127.0.0.1:" + targetPort +
                    " (is the Vizor stack running?) " + e.Message);
        }
        finally
        {
            client.Close();
            upstream.Close();
            if (connected) Log(peer + " -> " + listenPort + "  closed");
        }
    }

    static async Task Pump(NetworkStream from, NetworkStream to, Socket toSocket)
    {
        var buffer = new byte[65536];
        int read;
        while ((read = await from.ReadAsync(buffer, 0, buffer.Length)) > 0)
            await to.WriteAsync(buffer, 0, read);
        try { toSocket.Shutdown(SocketShutdown.Send); } catch (SocketException) { } catch (ObjectDisposedException) { }
    }

    static string Describe(TcpClient client)
    {
        try
        {
            var endpoint = (IPEndPoint)client.Client.RemoteEndPoint;
            IPAddress address = endpoint.Address.IsIPv4MappedToIPv6 ? endpoint.Address.MapToIPv4() : endpoint.Address;
            return address.ToString();
        }
        catch { return "?"; }
    }
}
'@

$listenPorts = @()
$targetPorts = @()
foreach ($pair in $PortMap.Split(',')) {
    $parts = $pair.Split('=')
    $listenPorts += [int]$parts[0].Trim()
    $targetPorts += [int]$parts[1].Trim()
}

Write-Host "=== Vizor relay ==="
Write-Host "Forwards the Vizor ports from every network this PC is on (Wi-Fi, Ethernet, Mobile Hotspot)"
Write-Host "to the loopback ports Docker publishes on. Close this window to stop it."
Write-Host ""

try {
    $relay = [VizorRelay]::Start([int[]]$listenPorts, [int[]]$targetPorts)
} catch {
    Write-Host ""
    Write-Host "ERROR: could not listen on the Vizor ports: $($_.Exception.InnerException.Message)"
    Write-Host "Something else already holds one of them ($($listenPorts -join ', ')). Common causes:"
    Write-Host "  - old 'netsh interface portproxy' rules:  netsh interface portproxy show all"
    Write-Host "  - the Vizor stack still running on the real ports (not in relay mode)"
    Write-Host "  - a second relay window"
    Read-Host "Press Enter to close"
    exit 1
}

# Polled rather than a blocking Wait(), so Ctrl+C can still interrupt this window.
while (-not $relay.Wait(500)) { }
if ($relay.IsFaulted) {
    Write-Host "Relay stopped with an error: $($relay.Exception.InnerException.Message)"
    Read-Host "Press Enter to close"
    exit 1
}
