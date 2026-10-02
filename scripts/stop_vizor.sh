#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
framework_root="$(cd -- "$script_dir/.." && pwd)"

# shellcheck source=VizorCommon.sh
source "$script_dir/VizorCommon.sh"

do_vizor=false
do_web=false

usage() {
    cat <<'EOF'
Usage: ./StopVizor.sh [options]

Options:
  --vizor, -Vizor              Stop the Vizor ROS stack only.
  --web-control, -WebControl   Stop the Web Control stack only.
  -h, --help                   Show this help.

With no options, both stacks are stopped. The MongoDB volume is kept.
EOF
}

while (($#)); do
    case "$1" in
        --vizor|-Vizor)
            do_vizor=true
            ;;
        --web-control|-WebControl)
            do_web=true
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

if [[ "$do_vizor" == false && "$do_web" == false ]]; then
    do_vizor=true
    do_web=true
fi

stop_stack() {
    local label="$1"
    local compose_file="$2"
    shift 2
    local containers=("$@")
    local running

    mapfile -t running < <(running_containers "${containers[@]}")
    if (( ${#running[@]} == 0 )); then
        printf '%s - not running, nothing to stop.\n' "$label"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        printf '%s - running (%s) but the compose file is missing at %s.\n' "$label" "$(join_by ', ' "${running[@]}")" "$compose_file"
        printf '  Stop it manually with: docker stop %s\n' "$(join_by ' ' "${running[@]}")"
        return 1
    fi

    printf '%s - stopping (%s)...\n' "$label" "$(join_by ', ' "${running[@]}")"
    if invoke_compose "$compose_file" down; then
        printf '%s - stopped.\n' "$label"
        return 0
    fi

    printf '%s - warning: failed to stop cleanly.\n' "$label"
    return 1
}

main() {
    local stopped_any=false

    printf '=== Stop Vizor Docker stacks ===\n\n'
    assert_command_exists docker "Install Docker Desktop and ensure it is running with WSL integration enabled."

    if [[ "$do_vizor" == true ]]; then
        if stop_stack 'Vizor ROS stack' "$(compose_file_vizor "$framework_root")" "${vizor_stack_containers[@]}"; then
            stopped_any=true
        fi
    fi

    if [[ "$do_web" == true ]]; then
        if stop_stack 'Vizor Web Control' "$(compose_file_web "$framework_root")" "${web_control_containers[@]}"; then
            stopped_any=true
        fi
    fi

    printf '\n'
    if [[ "$stopped_any" == false ]]; then
        printf 'Nothing to stop.\n'
    fi
}

if ! main; then
    printf '\nStop failed - see messages above.\n' >&2
    exit 1
fi
