# VizorFramework

**Double-click `StartVizor.bat`.** Brings up the Vizor ROS stack (roscore + rosbridge) and the
Vizor Web Control console (operator UI + MongoDB), and optionally the Windows port-proxy /
firewall rules a HoloLens on the LAN needs.

Self-contained: pulls published images, needs Docker Desktop (WSL2 backend). First launch downloads ~600 MB per image.

## The four questions

| Question | Default | Effect |
|---|---|---|
| Firewall / port-proxy rules? | **n** | `netsh` rules for 9090, 10000-10003, 11311 -> the WSL2 IP. Only for LAN clients (HoloLens). One UAC prompt. |
| Start the Vizor ROS stack? | **y** | `ros-core` + `vizor-demo`, own log window. |
| Start the Web Control console? | **y** | `vizor-web-control` + `vizor-mongo`; opens http://localhost:8000 when ready. |
| Leave containers running? | **y** | **y** = next launch reuses them. **n** = stopped when you press Enter / close the window. |

Ports: 9090 rosbridge · 10000-10003 Vizor TCP · 11311 ROS master · 8000 console ·
27017 MongoDB (unauthenticated, lab machine only).

## Stopping

`StopVizor.bat` stops both stacks and keeps the data. Per-stack:
`.\scripts\stop_vizor.ps1 -Vizor` / `-WebControl`.

Logged sessions live in the `vizor_mongo_data` volume and survive every normal teardown.
Discarding them is explicit: `docker compose -f compose\vizor-web-stack.yml down -v`.

## Layout

```
StartVizor.bat / StopVizor.bat     entry points
compose\vizor-stack.yml            ros-core + vizor-demo
compose\vizor-web-stack.yml        vizor-web-control + vizor-mongo
scripts\VizorCommon.ps1            shared helpers (dot-sourced, not run directly)
scripts\start_vizor.ps1 / stop_vizor.ps1
```

## Troubleshooting

- **rosbridge never reachable** — check the ROS stack's log window (pull failure, roslaunch error).
  The launcher only warns; it never aborts on this.
- **`ros_connected` stays false** — normal for up to ~2.5 min after a cold start.
- **HoloLens can't connect** — re-run with **y** to the firewall question; the WSL IP changes across
  reboots. Check with `netsh interface portproxy show v4tov4`.
- **Containers left after a Task Manager kill** — run `StopVizor.bat`.
