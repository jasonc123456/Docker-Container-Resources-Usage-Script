#!/usr/bin/env bash
# Live Docker resource monitor, grouped by Docker Compose project/stack.
# Usage: docker_monitor.sh [--interval SECONDS] [--once] [--no-color]

set -uo pipefail
export LC_ALL=C

INTERVAL="${DOCKER_MONITOR_INTERVAL:-5}"
RUN_ONCE=0
COLOR_ENABLED=1

usage() {
    cat <<'EOF'
Usage: docker_monitor.sh [OPTIONS]

  -i, --interval SECONDS  Refresh interval (default: 5)
      --once              Print one snapshot and exit
      --no-color          Disable terminal colors
  -h, --help              Show this help
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        -i|--interval)
            (($# >= 2)) || die "$1 requires a number of seconds"
            INTERVAL=$2
            shift 2
            ;;
        --once) RUN_ONCE=1; shift ;;
        --no-color) COLOR_ENABLED=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] ||
    die "refresh interval must be a positive whole number"
command -v docker >/dev/null 2>&1 || die "docker is not installed or is not in PATH"
docker info >/dev/null 2>&1 ||
    die "cannot connect to Docker (check the daemon and your user permissions)"

# Colors are disabled when output is redirected and when NO_COLOR is set.
if [[ ! -t 1 || -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then
    COLOR_ENABLED=0
fi

RESET='' BOLD='' DIM='' RED='' YELLOW='' GREEN='' CYAN='' MAGENTA=''
if ((COLOR_ENABLED)); then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[1;31m'
    YELLOW=$'\033[1;33m'
    GREEN=$'\033[1;32m'
    CYAN=$'\033[1;36m'
    MAGENTA=$'\033[1;35m'
fi

# Docker reports memory using binary units.
to_bytes() {
    awk -v value="$1" 'BEGIN {
        gsub(/[[:space:]]/, "", value)
        if (!match(value, /^[0-9]+([.][0-9]+)?/)) { print 0; exit }
        number = substr(value, RSTART, RLENGTH) + 0
        unit = substr(value, RLENGTH + 1)
        multiplier = 1
        if      (unit == "kB" || unit == "KB") multiplier = 1000
        else if (unit == "MB")  multiplier = 1000^2
        else if (unit == "GB")  multiplier = 1000^3
        else if (unit == "TB")  multiplier = 1000^4
        else if (unit == "KiB") multiplier = 1024
        else if (unit == "MiB") multiplier = 1024^2
        else if (unit == "GiB") multiplier = 1024^3
        else if (unit == "TiB") multiplier = 1024^4
        printf "%.0f\n", number * multiplier
    }'
}

human_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", units, " ")
        i = 1
        while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
        if (i == 1)             printf "%d B", bytes
        else if (bytes >= 100)  printf "%.0f %s", bytes, units[i]
        else if (bytes >= 10)   printf "%.1f %s", bytes, units[i]
        else                    printf "%.2f %s", bytes, units[i]
    }'
}

# Store CPU percentages as hundredths for exact integer aggregation in Bash.
pct_to_hundredths() {
    local value=${1%\%}
    awk -v value="${value:-0}" 'BEGIN { printf "%.0f\n", value * 100 }'
}

human_pct() {
    local value=${1:-0}
    printf '%d.%02d%%' "$((value / 100))" "$((value % 100))"
}

cpu_limit_hundredths() {
    local nano=$1 quota=$2 period=$3 cpuset=$4
    if [[ "$nano" =~ ^[0-9]+$ ]] && ((nano > 0)); then
        printf '%d\n' "$((nano / 100000))"
    elif [[ "$quota" =~ ^-?[0-9]+$ && "$period" =~ ^[0-9]+$ ]] &&
         ((quota > 0 && period > 0)); then
        printf '%d\n' "$((quota * 10000 / period))"
    elif [[ -n "$cpuset" && "$cpuset" != '<no value>' ]]; then
        awk -v set="$cpuset" 'BEGIN {
            count = 0
            n = split(set, entries, ",")
            for (i = 1; i <= n; i++) {
                if (entries[i] ~ /-/) {
                    split(entries[i], range, "-")
                    count += range[2] - range[1] + 1
                } else if (entries[i] != "") {
                    count++
                }
            }
            printf "%d\n", count * 10000
        }'
    else
        printf '0\n'
    fi
}

cpu_text() {
    if (($2 > 0)); then
        printf '%s / %s' "$(human_pct "$1")" "$(human_pct "$2")"
    else
        printf '%s / uncapped' "$(human_pct "$1")"
    fi
}

memory_text() {
    if (($2 > 0)); then
        printf '%s / %s' "$(human_bytes "$1")" "$(human_bytes "$2")"
    else
        printf '%s / uncapped' "$(human_bytes "$1")"
    fi
}

# Green below 50%, yellow at 50-79%, and red at 80% or above.
resource_color() {
    local used=$1 limit=$2
    if ((limit <= 0)); then
        printf '%s' "$CYAN"
    elif ((used * 100 >= limit * 80)); then
        printf '%s' "$RED"
    elif ((used * 100 >= limit * 50)); then
        printf '%s' "$YELLOW"
    else
        printf '%s' "$GREEN"
    fi
}

clip() {
    local text=$1 width=$2
    if ((${#text} > width)); then
        printf '%s...' "${text:0:width-3}"
    else
        printf '%s' "$text"
    fi
}

# Pad first and color second so ANSI escape sequences never break alignment.
print_cell() {
    local text=$1 width=$2 alignment=$3 color=${4:-}
    local clipped cell
    clipped=$(clip "$text" "$width")
    if [[ "$alignment" == right ]]; then
        printf -v cell "%${width}s" "$clipped"
    else
        printf -v cell "%-${width}s" "$clipped"
    fi
    if [[ -n "$color" ]]; then
        printf '%b%s%b' "$color" "$cell" "$RESET"
    else
        printf '%s' "$cell"
    fi
}

clear_terminal() { [[ -t 1 ]] && printf '\033[H\033[2J'; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h'; }
trap show_cursor EXIT
trap 'exit 0' INT TERM
[[ -t 1 ]] && printf '\033[?25l'

render_snapshot() {
    local -a ids metadata groups
    local stats_output inspect_output
    local line name cpu_raw mem_raw mem_used_raw
    local full_id stack swarm_stack mem_limit storage nano quota period cpuset
    local cpu_used cpu_limit mem_used current_stack=''
    local cpu_display mem_display cpu_color mem_color

    mapfile -t ids < <(docker ps -q)
    if ((${#ids[@]} == 0)); then
        clear_terminal
        printf '%bDocker Resource Monitor%b | %s | %s | refresh %ss\n\n' \
            "$BOLD$CYAN" "$RESET" "$(hostname)" \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$INTERVAL"
        printf 'No running containers.\n'
        return
    fi

    # A single stats call samples every container together.
    if ! stats_output=$(docker stats --no-stream \
        --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>&1); then
        clear_terminal
        printf 'Docker stats failed:\n%s\n' "$stats_output" >&2
        return
    fi

    # SizeRootFs is the logical root filesystem size: image plus writable layer.
    inspect_output=$(docker inspect --size \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.stack.namespace"}}|{{.HostConfig.Memory}}|{{.SizeRootFs}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.CpusetCpus}}' \
        "${ids[@]}" 2>/dev/null || true)
    [[ -n "$inspect_output" ]] || {
        clear_terminal
        printf 'Docker inspect returned no running containers.\n' >&2
        return
    }

    declare -A stat_cpu=() stat_mem=()
    while IFS='|' read -r name cpu_raw mem_raw; do
        [[ -n "$name" ]] || continue
        mem_used_raw=${mem_raw%% / *}
        stat_cpu["$name"]=$(pct_to_hundredths "$cpu_raw")
        stat_mem["$name"]=$(to_bytes "$mem_used_raw")
    done <<< "$stats_output"

    # Stable ordering prevents rows from jumping between refreshes.
    mapfile -t metadata < <(
        while IFS='|' read -r full_id name stack swarm_stack mem_limit storage nano quota period cpuset; do
            [[ -n "$full_id" ]] || continue
            name=${name#/}
            if [[ -z "$stack" || "$stack" == '<no value>' ]]; then
                stack=$swarm_stack
            fi
            [[ -n "$stack" && "$stack" != '<no value>' ]] || stack='(standalone)'
            [[ "$mem_limit" =~ ^[0-9]+$ ]] || mem_limit=0
            [[ "$storage" =~ ^[0-9]+$ ]] || storage=0
            cpu_limit=$(cpu_limit_hundredths "$nano" "$quota" "$period" "$cpuset")
            printf '%s|%s|%s|%s|%s|%s\n' \
                "$stack" "$name" "$full_id" "$mem_limit" "$storage" "$cpu_limit"
        done <<< "$inspect_output" | sort -t '|' -k1,1 -k2,2
    )

    declare -A group_seen=() group_count=() group_cpu=() group_cpu_limit=()
    declare -A group_cpu_uncapped=() group_mem=() group_mem_limit=()
    declare -A group_mem_uncapped=() group_storage=()
    local total_cpu=0 total_cpu_limit=0 total_cpu_uncapped=0
    local total_mem=0 total_mem_limit=0 total_mem_uncapped=0 total_storage=0

    for line in "${metadata[@]}"; do
        IFS='|' read -r stack name full_id mem_limit storage cpu_limit <<< "$line"
        cpu_used=${stat_cpu["$name"]:-0}
        mem_used=${stat_mem["$name"]:-0}

        if [[ -z ${group_seen["$stack"]+x} ]]; then
            group_seen["$stack"]=1
            groups+=("$stack")
        fi

        group_count["$stack"]=$(( ${group_count["$stack"]:-0} + 1 ))
        group_cpu["$stack"]=$(( ${group_cpu["$stack"]:-0} + cpu_used ))
        group_mem["$stack"]=$(( ${group_mem["$stack"]:-0} + mem_used ))
        group_storage["$stack"]=$(( ${group_storage["$stack"]:-0} + storage ))
        total_cpu=$((total_cpu + cpu_used))
        total_mem=$((total_mem + mem_used))
        total_storage=$((total_storage + storage))

        if ((cpu_limit > 0)); then
            group_cpu_limit["$stack"]=$(( ${group_cpu_limit["$stack"]:-0} + cpu_limit ))
            total_cpu_limit=$((total_cpu_limit + cpu_limit))
        else
            group_cpu_uncapped["$stack"]=1
            total_cpu_uncapped=1
        fi

        if ((mem_limit > 0)); then
            group_mem_limit["$stack"]=$(( ${group_mem_limit["$stack"]:-0} + mem_limit ))
            total_mem_limit=$((total_mem_limit + mem_limit))
        else
            group_mem_uncapped["$stack"]=1
            total_mem_uncapped=1
        fi
    done

    clear_terminal
    printf '%bDocker Resource Monitor%b | %s | %s | refresh %ss\n' \
        "$BOLD$CYAN" "$RESET" "$(hostname)" \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$INTERVAL"
    printf 'Running: %d container(s) in %d stack group(s)\n\n' \
        "${#metadata[@]}" "${#groups[@]}"

    printf '%b' "$BOLD"
    printf '%-34s | %21s | %-25s | %14s\n' \
        'CONTAINER' 'CPU USED / LIMIT' 'MEMORY USED / LIMIT' 'STORAGE USED*'
    printf '%b' "$RESET$DIM"
    printf '%s\n' \
        '-----------------------------------+-----------------------+---------------------------+----------------'
    printf '%b' "$RESET"

    for line in "${metadata[@]}"; do
        IFS='|' read -r stack name full_id mem_limit storage cpu_limit <<< "$line"
        if [[ "$stack" != "$current_stack" ]]; then
            [[ -z "$current_stack" ]] || printf '\n'
            printf '%b[stack: %s]%b\n' "$BOLD$MAGENTA" "$stack" "$RESET"
            current_stack=$stack
        fi

        cpu_used=${stat_cpu["$name"]:-0}
        mem_used=${stat_mem["$name"]:-0}
        cpu_display=$(cpu_text "$cpu_used" "$cpu_limit")
        mem_display=$(memory_text "$mem_used" "$mem_limit")
        cpu_color=$(resource_color "$cpu_used" "$cpu_limit")
        mem_color=$(resource_color "$mem_used" "$mem_limit")

        print_cell "$name" 34 left
        printf ' | '
        print_cell "$cpu_display" 21 right "$cpu_color"
        printf ' | '
        print_cell "$mem_display" 25 left "$mem_color"
        printf ' | '
        print_cell "$(human_bytes "$storage")" 14 right "$CYAN"
        printf '\n'
    done

    printf '\n%bSTACK TOTALS%b\n' "$BOLD$MAGENTA" "$RESET"
    printf '%b' "$BOLD"
    printf '%-30s | %5s | %21s | %-25s | %14s\n' \
        'STACK' 'COUNT' 'CPU USED / LIMIT' 'MEMORY USED / LIMIT' 'STORAGE USED*'
    printf '%b' "$RESET$DIM"
    printf '%s\n' \
        '-------------------------------+-------+-----------------------+---------------------------+----------------'
    printf '%b' "$RESET"

    for stack in "${groups[@]}"; do
        cpu_limit=${group_cpu_limit["$stack"]:-0}
        mem_limit=${group_mem_limit["$stack"]:-0}
        ((${group_cpu_uncapped["$stack"]:-0})) && cpu_limit=0
        ((${group_mem_uncapped["$stack"]:-0})) && mem_limit=0
        cpu_display=$(cpu_text "${group_cpu["$stack"]}" "$cpu_limit")
        mem_display=$(memory_text "${group_mem["$stack"]}" "$mem_limit")
        cpu_color=$(resource_color "${group_cpu["$stack"]}" "$cpu_limit")
        mem_color=$(resource_color "${group_mem["$stack"]}" "$mem_limit")

        print_cell "$stack" 30 left
        printf ' | '
        print_cell "${group_count["$stack"]}" 5 right
        printf ' | '
        print_cell "$cpu_display" 21 right "$cpu_color"
        printf ' | '
        print_cell "$mem_display" 25 left "$mem_color"
        printf ' | '
        print_cell "$(human_bytes "${group_storage["$stack"]}")" 14 right "$CYAN"
        printf '\n'
    done

    ((total_cpu_uncapped)) && total_cpu_limit=0
    ((total_mem_uncapped)) && total_mem_limit=0
    cpu_display=$(cpu_text "$total_cpu" "$total_cpu_limit")
    mem_display=$(memory_text "$total_mem" "$total_mem_limit")
    cpu_color=$(resource_color "$total_cpu" "$total_cpu_limit")
    mem_color=$(resource_color "$total_mem" "$total_mem_limit")

    printf '%b' "$DIM"
    printf '%s\n' \
        '-------------------------------+-------+-----------------------+---------------------------+----------------'
    printf '%b' "$RESET$BOLD"
    print_cell 'ALL RUNNING CONTAINERS' 30 left
    printf ' | '
    print_cell "${#metadata[@]}" 5 right
    printf ' | '
    print_cell "$cpu_display" 21 right "$cpu_color"
    printf ' | '
    print_cell "$mem_display" 25 left "$mem_color"
    printf ' | '
    print_cell "$(human_bytes "$total_storage")" 14 right "$CYAN"
    printf '%b\n' "$RESET"

    printf '\nLimit colors: %bGREEN <50%%%b  %bYELLOW 50-79%%%b  %bRED >=80%%%b  %bCYAN uncapped%b\n' \
        "$GREEN" "$RESET" "$YELLOW" "$RESET" "$RED" "$RESET" "$CYAN" "$RESET"
    printf '* Storage used = logical container root filesystem (image layers + writable layer).\n'
    printf '  Mounted volumes/bind mounts are excluded; shared image layers can be counted in more than one row.\n'
    printf '  Ctrl+C exits.\n'
}

while true; do
    render_snapshot
    ((RUN_ONCE)) && break
    sleep "$INTERVAL"
done
