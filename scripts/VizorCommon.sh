#!/usr/bin/env bash

vizor_stack_containers=(vizor-demo ros-core)
web_control_containers=(vizor-web-control vizor-mongo)

vizor_started_stack=false
vizor_started_web_control=false
vizor_using_stack=false
vizor_using_web_control=false
vizor_teardown_all=false
vizor_keep_docker_on_exit=false
vizor_cleanup_done=false

assert_command_exists() {
    local name="$1"
    local hint="$2"
    if ! command -v "$name" >/dev/null 2>&1; then
        printf "'%s' was not found on PATH. %s\n" "$name" "$hint" >&2
        return 1
    fi
}

read_yes_no() {
    local prompt="$1"
    local default_yes="$2"
    local suffix default raw

    if [[ "$default_yes" == true ]]; then
        suffix='[Y/n]'
        default=0
    else
        suffix='[y/N]'
        default=1
    fi

    read -r -p "$prompt $suffix " raw || raw=''
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        return "$default"
    fi
    [[ "${raw,,}" == y* ]]
}

compose_file_vizor() {
    printf '%s/compose/vizor-stack.yml\n' "$1"
}

compose_file_web() {
    printf '%s/compose/vizor-web-stack.yml\n' "$1"
}

compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        printf 'docker-compose\n'
    else
        printf 'docker compose\n'
    fi
}

invoke_compose() {
    local compose_file="$1"
    shift

    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$compose_file" "$@"
    else
        docker compose -f "$compose_file" "$@"
    fi
}

running_containers() {
    local names=("$@")
    local running name

    running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
    for name in "${names[@]}"; do
        if grep -Fxq "$name" <<<"$running"; then
            printf '%s\n' "$name"
        fi
    done
}

join_by() {
    local sep="$1"
    shift
    local first=true item
    for item in "$@"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            printf '%s' "$sep"
        fi
        printf '%s' "$item"
    done
}

get_wsl_ip() {
    hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1
}

open_vizor_firewall_ports() {
    local wsl_ip="$1"
    local ps_file win_ps_file

    assert_command_exists powershell.exe "Run this from WSL on Windows, or answer 'n' to skip the firewall option."
    assert_command_exists wslpath "Run this from WSL, or answer 'n' to skip the firewall option."

    ps_file="$(mktemp /tmp/vizor_firewall_XXXXXX.ps1)"
    cat >"$ps_file" <<PS1
\$ErrorActionPreference = 'Stop'
\$ports = @(10000, 10001, 10002, 10003, 11311, 9090)
\$wslIp = '$wsl_ip'
foreach (\$port in \$ports) {
    Write-Host "Opening port \$port..."
    netsh interface portproxy delete v4tov4 listenport=\$port | Out-Null
    netsh advfirewall firewall delete rule name=\$port | Out-Null
    netsh interface portproxy add v4tov4 listenport=\$port connectport=\$port connectaddress=\$wslIp | Out-Null
    netsh advfirewall firewall add rule name=\$port dir=in action=allow protocol=TCP localport=\$port | Out-Null
}
netsh interface portproxy show v4tov4
PS1
    win_ps_file="$(wslpath -w "$ps_file")"

    printf 'Firewall setup needs Administrator rights. Approve the Windows UAC prompt if it appears.\n'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','\"$win_ps_file\"')"
    rm -f "$ps_file"
}

start_vizor_docker_stack() {
    local framework_root="$1"
    local compose_file already_up missing compose

    compose_file="$(compose_file_vizor "$framework_root")"
    [[ -f "$compose_file" ]] || { printf 'Compose file not found at %s\n' "$compose_file" >&2; return 1; }

    vizor_using_stack=true
    mapfile -t already_up < <(running_containers "${vizor_stack_containers[@]}")

    if (( ${#already_up[@]} == ${#vizor_stack_containers[@]} )); then
        printf 'Reusing the Vizor stack already running (%s) - skipping startup.\n' "$(join_by ', ' "${vizor_stack_containers[@]}")"
        return 0
    fi

    if (( ${#already_up[@]} > 0 )); then
        missing=()
        for container in "${vizor_stack_containers[@]}"; do
            if ! printf '%s\n' "${already_up[@]}" | grep -Fxq "$container"; then
                missing+=("$container")
            fi
        done
        printf 'Warning: the Vizor stack is only partly up (running: %s; missing: %s).\n' "$(join_by ', ' "${already_up[@]}")" "$(join_by ', ' "${missing[@]}")"
        printf 'Starting the missing container(s).\n'
        invoke_compose "$compose_file" up -d
        return 0
    fi

    compose="$(compose_cmd)"
    printf 'Starting the Vizor ROS stack...\n'
    docker pull cxy201/noetic-vizor
    invoke_compose "$compose_file" up -d
    printf 'Follow ROS stack logs with: %s -f %q logs -f\n' "$compose" "$compose_file"
    vizor_started_stack=true
}

start_vizor_web_control_stack() {
    local framework_root="$1"
    local compose_file already_up missing compose

    compose_file="$(compose_file_web "$framework_root")"
    [[ -f "$compose_file" ]] || { printf 'Compose file not found at %s\n' "$compose_file" >&2; return 1; }

    vizor_using_web_control=true
    mapfile -t already_up < <(running_containers "${web_control_containers[@]}")

    if (( ${#already_up[@]} == ${#web_control_containers[@]} )); then
        printf 'Refreshing the Vizor Web Control stack already running (%s) with the latest image.\n' "$(join_by ', ' "${web_control_containers[@]}")"
    elif (( ${#already_up[@]} > 0 )); then
        missing=()
        for container in "${web_control_containers[@]}"; do
            if ! printf '%s\n' "${already_up[@]}" | grep -Fxq "$container"; then
                missing+=("$container")
            fi
        done
        printf 'Warning: the Vizor Web Control stack is only partly up (running: %s; missing: %s).\n' "$(join_by ', ' "${already_up[@]}")" "$(join_by ', ' "${missing[@]}")"
        printf 'Starting the missing container(s).\n'
    else
        printf 'Starting Vizor Web Control (console + MongoDB)...\n'
    fi

    compose="$(compose_cmd)"
    invoke_compose "$compose_file" up -d --pull always
    printf 'Follow Web Control logs with: %s -f %q logs -f\n' "$compose" "$compose_file"
    if (( ${#already_up[@]} != ${#web_control_containers[@]} )); then
        vizor_started_web_control=true
    fi
}

wait_for_port() {
    local target_host="${1:-127.0.0.1}"
    local port="${2:-9090}"
    local timeout_sec="${3:-120}"
    local interval_sec="${4:-2}"
    local label="${5:-$target_host:$port}"
    local start elapsed

    printf 'Waiting for %s ...\n' "$label"
    start="$(date +%s)"
    while true; do
        if timeout 2 bash -c "</dev/tcp/$target_host/$port" >/dev/null 2>&1; then
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        (( elapsed >= timeout_sec )) && return 1
        printf '  ... still waiting (%ss elapsed)\n' "$elapsed"
        sleep "$interval_sec"
    done
}

wait_for_http_ok() {
    local url="$1"
    local timeout_sec="${2:-300}"
    local interval_sec="${3:-3}"
    local label="${4:-$url}"
    local start elapsed status

    assert_command_exists curl "Install curl, or check $url manually."
    printf 'Waiting for %s ...\n' "$label"
    start="$(date +%s)"
    while true; do
        status="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
        [[ "$status" == 200 ]] && return 0
        elapsed=$(( $(date +%s) - start ))
        (( elapsed >= timeout_sec )) && return 1
        printf '  ... still waiting (%ss elapsed)\n' "$elapsed"
        sleep "$interval_sec"
    done
}

open_url() {
    local url="$1"
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
    fi
}

confirm_vizor_web_control_ready() {
    local url='http://127.0.0.1:8000'

    if ! wait_for_http_ok "$url/health" 300 3 'Vizor Web Control at http://localhost:8000'; then
        printf 'Warning: the Vizor Web Control console did not answer /health within the timeout.\n'
        printf '  Check its docker logs for pull or startup errors.\n'
        return 0
    fi
    printf 'Opening the Vizor Web Control console at http://localhost:8000 ...\n'
    open_url 'http://localhost:8000'
    printf "Note: 'ros_connected' can take ~2.5 min to turn true after a cold start of the Vizor\n"
    printf 'stack (MoveIt boots before rosbridge, then the backend waits out its retry backoff).\n'
}

invoke_vizor_cleanup() {
    local framework_root="$1"
    local down_vizor=false down_web=false vizor_compose web_compose

    [[ "$vizor_cleanup_done" == true ]] && return 0
    vizor_cleanup_done=true

    if [[ "$vizor_keep_docker_on_exit" == true ]]; then
        printf '\nLeaving the Docker containers running as requested - the next launch will reuse them.\n'
        printf 'Stop them later with: ./StopVizor.sh\n'
        return 0
    fi

    if [[ "$vizor_teardown_all" == true ]]; then
        down_vizor="$vizor_using_stack"
        down_web="$vizor_using_web_control"
    else
        down_vizor="$vizor_started_stack"
        down_web="$vizor_started_web_control"
    fi

    if [[ "$down_vizor" == true ]]; then
        vizor_compose="$(compose_file_vizor "$framework_root")"
        if [[ -f "$vizor_compose" ]]; then
            printf 'Stopping the Vizor ROS stack (compose down)...\n'
            invoke_compose "$vizor_compose" down || printf 'Warning: failed to stop the Vizor ROS stack cleanly.\n'
        fi
    fi

    if [[ "$down_web" == true ]]; then
        web_compose="$(compose_file_web "$framework_root")"
        if [[ -f "$web_compose" ]]; then
            printf 'Stopping Vizor Web Control (compose down)...\n'
            invoke_compose "$web_compose" down || printf 'Warning: failed to stop Vizor Web Control cleanly.\n'
        fi
    fi
}
