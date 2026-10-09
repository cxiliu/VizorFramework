# VizorFramework

**Double-click `StartVizor.bat`.** Brings up the Vizor ROS stack (roscore + rosbridge) and the
Vizor Web Control console (operator UI + MongoDB), and optionally the Windows port-proxy /
firewall rules a HoloLens on the LAN needs.

Self-contained: pulls published images, needs Docker Desktop (WSL2 backend). First launch downloads ~600 MB per image.

## The four questions

| Question | Default | Effect |
|---|---|---|
| Firewall / port-proxy rules? | **n** | Firewall rules for 9090, 10000-10003, 11311, plus `netsh` port-proxy rules -> the WSL2 IP (no port-proxy in relay mode). Only for LAN clients (HoloLens). One UAC prompt. |
| Start the Vizor ROS stack? | **y** | `vizor-ros-master` + `vizor-bridge`, own log window. |
| Start the Web Control console? | **y** | `vizor-web` + `vizor-mongo`; opens http://localhost:8000 when ready. |
| Leave containers running? | **y** | **y** = next launch reuses them. **n** = stopped when you press Enter / close the window. |

Ports: 9090 rosbridge · 10000-10003 Vizor TCP · 11311 ROS master · 8000 console ·
27017 MongoDB (unauthenticated, lab machine only).

## Relay mode (WSL mirrored networking)

With `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`, ports Docker publishes live inside
the WSL VM and are reachable only through the network adapters WSL mirrors - not this PC's
Windows Mobile Hotspot. Windows also cannot listen on a port the VM already holds, so a port-proxy
on the same port cannot bridge the gap.

The launcher detects mirrored mode and switches to relay mode on its own:

- Docker publishes on loopback-only internal ports (9090 -> 19090, 10000-10003 -> 20000-20003,
  11311 -> 21311).
- `scripts\vizor_relay.ps1` runs in its own window, listens on the real ports on every network
  (Wi-Fi, Ethernet, Mobile Hotspot) and forwards each connection to the internal port.

Clients see no difference: they still connect to 9090 / 10000-10003 / 11311. The relay must be
running while clients are connected; `StopVizor.bat` stops it with the stack. Without mirrored
networking, or when the stack is started by hand with `docker compose`, nothing changes.

Force it either way with `VIZOR_RELAY=on` or `VIZOR_RELAY=off` (environment variable) before
running `StartVizor.bat`.

On the PC hotspot the HoloLens connects to `192.168.137.1`. The launcher lists this PC's addresses
when it is done.

The relay runs in `powershell.exe`. If Windows ever asks whether to allow "Windows PowerShell"
through the firewall, do not cancel without admin rights: that creates block rules for PowerShell
that cut the relay off from the LAN (it keeps working from this PC, which hides the problem).
Answering **y** to the firewall question removes such rules.

## Stopping

`StopVizor.bat` stops both stacks and keeps the data. Per-stack:
`.\scripts\stop_vizor.ps1 -Vizor` / `-WebControl`.

Logged sessions live in the `vizor_mongo_data` volume and survive every normal teardown.
Discarding them is explicit: `docker compose -f compose\vizor-web-stack.yml down -v`.

## Layout

```
StartVizor.bat / StopVizor.bat     entry points
compose\vizor-stack.yml            vizor-ros-master + vizor-bridge
compose\vizor-web-stack.yml        vizor-web + vizor-mongo
scripts\VizorCommon.ps1            shared helpers (dot-sourced, not run directly)
scripts\start_vizor.ps1 / stop_vizor.ps1
```

## Troubleshooting

- **rosbridge never reachable** — check the ROS stack's log window (pull failure, roslaunch error).
  The launcher only warns; it never aborts on this.
- **`ros_connected` stays false** — normal for up to ~2.5 min after a cold start.
- **HoloLens can't connect** — re-run with **y** to the firewall question; the WSL IP changes across
  reboots. Check with `netsh interface portproxy show v4tov4`. In relay mode, check that the relay
  window is open and shows no error; a leftover port-proxy rule on these ports blocks it (removing
  one needs admin: `netsh interface portproxy delete v4tov4 listenport=<port>`).
- **`localhost` fails but `127.0.0.1` works** (mirrored mode) — `localhost` resolves to IPv6 `::1`
  first, which mirrored WSL does not forward. Use `127.0.0.1`; in relay mode both work.
- **Containers left after a Task Manager kill** — run `StopVizor.bat`.
- **Port conflicts after upgrading from the old names** (`vizor-demo`, `ros-core`, `vizor-web-control`)
  — the launcher no longer sees those containers. Remove them once, keeping the data:
  `docker compose -p vizor-rviz down` and `docker compose -p vizor-web-control down` (no `-v`).
