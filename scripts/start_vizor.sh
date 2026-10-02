#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
framework_root="$(cd -- "$script_dir/.." && pwd)"

# shellcheck source=VizorCommon.sh
source "$script_dir/VizorCommon.sh"

firewall=''
ros_stack=''
web_control=''
keep=''
close_prompt=true

usage() {
    cat <<'EOF'
Usage: ./StartVizor.sh [options]

Options:
  --firewall yes|no      Set up Windows Firewall / port-proxy rules for LAN clients.
  --ros-stack yes|no     Start the Vizor ROS stack.
  --web-control yes|no   Start the Vizor Web Control console.
  --keep yes|no          Leave containers running after this script exits.
  -Firewall yes|no       PowerShell-compatible alias.
  -RosStack yes|no       PowerShell-compatible alias.
  -WebControl yes|no     PowerShell-compatible alias.
  -Keep yes|no           PowerShell-compatible alias.
  -h, --help             Show this help.
EOF
}

normalize_yes_no() {
    case "${1,,}" in
        y|yes|true|1) printf 'yes\n' ;;
        n|no|false|0) printf 'no\n' ;;
        *) printf 'Expected yes or no, got: %s\n' "$1" >&2; return 1 ;;
    esac
}

while (($#)); do
    opt="$1"
    case "$1" in
        --firewall|-Firewall)
            shift; (($#)) || { printf '%s requires yes or no\n' "$opt" >&2; exit 1; }
            firewall="$(normalize_yes_no "$1")"
            ;;
        --ros-stack|-RosStack)
            shift; (($#)) || { printf '%s requires yes or no\n' "$opt" >&2; exit 1; }
            ros_stack="$(normalize_yes_no "$1")"
            ;;
        --web-control|-WebControl)
            shift; (($#)) || { printf '%s requires yes or no\n' "$opt" >&2; exit 1; }
            web_control="$(normalize_yes_no "$1")"
            ;;
        --keep|-Keep)
            shift; (($#)) || { printf '%s requires yes or no\n' "$opt" >&2; exit 1; }
            keep="$(normalize_yes_no "$1")"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

on_exit() {
    local status=$?
    if [[ "$close_prompt" == false ]]; then
        return "$status"
    fi
    invoke_vizor_cleanup "$framework_root"
    return "$status"
}
trap on_exit EXIT

main() {
    local wsl_ip

    printf '=== Vizor Framework Launcher ===\n\n'

    if [[ -z "$firewall" ]]; then
        if read_yes_no 'Set up Windows Firewall / port-proxy rules (for a HoloLens on the LAN)?' false; then
            firewall=yes
        else
            firewall=no
        fi
    fi
    if [[ -z "$ros_stack" ]]; then
        if read_yes_no 'Start the Vizor ROS stack (ros-core + vizor-demo)?' true; then
            ros_stack=yes
        else
            ros_stack=no
        fi
    fi
    if [[ -z "$web_control" ]]; then
        if read_yes_no 'Start the Vizor Web Control console (operator UI + MongoDB)?' true; then
            web_control=yes
        else
            web_control=no
        fi
    fi

    if [[ "$ros_stack" == no && "$web_control" == no ]]; then
        printf 'Nothing to start: both stacks were declined. Re-run and answer y to at least one of them.\n' >&2
        return 1
    fi

    if [[ -z "$keep" ]]; then
        if read_yes_no 'Leave the containers running after this window closes? (no = stop them on exit)' true; then
            keep=yes
        else
            keep=no
        fi
    fi
    [[ "$keep" == yes ]] && vizor_keep_docker_on_exit=true || vizor_keep_docker_on_exit=false
    [[ "$keep" == no ]] && vizor_teardown_all=true || vizor_teardown_all=false

    assert_command_exists docker "Install Docker Desktop and ensure it is running with WSL integration enabled."

    if [[ "$firewall" == yes ]]; then
        wsl_ip="$(get_wsl_ip)"
        [[ -n "$wsl_ip" ]] || { printf 'Could not detect the WSL IP address via hostname -I.\n' >&2; return 1; }
        printf 'WSL2 IP detected: %s\n' "$wsl_ip"
        open_vizor_firewall_ports "$wsl_ip"
    fi

    if [[ "$ros_stack" == yes ]]; then
        start_vizor_docker_stack "$framework_root"
    fi

    if [[ "$web_control" == yes ]]; then
        start_vizor_web_control_stack "$framework_root"
    fi

    if [[ "$ros_stack" == yes ]]; then
        if wait_for_port 127.0.0.1 9090 120 2 'rosbridge at 127.0.0.1:9090'; then
            printf 'rosbridge is reachable at 127.0.0.1:9090.\n'
        else
            printf 'Warning: rosbridge did not become reachable at 127.0.0.1:9090 within the timeout.\n'
            printf '  Check docker logs for errors (image pull failure, container crash, roslaunch failure).\n'
        fi
    fi

    if [[ "$web_control" == yes ]]; then
        confirm_vizor_web_control_ready
    fi

    printf '\nVizor is up.\n'
    if [[ "$vizor_keep_docker_on_exit" == true ]]; then
        printf 'The containers keep running after this shell exits. Stop them later with: ./StopVizor.sh\n'
    else
        printf 'The containers will be stopped when you press Enter or close this shell.\n\n'
        read -r -p 'Press Enter to stop the containers and close' _
        invoke_vizor_cleanup "$framework_root"
        close_prompt=false
    fi
}

if ! main; then
    printf '\nLaunch failed - see messages above.\n' >&2
    exit 1
fi
