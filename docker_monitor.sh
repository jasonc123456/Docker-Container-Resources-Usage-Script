#!/usr/bin/env bash
# Live Docker resource monitor, grouped by Docker Compose project/stack.
# Usage: docker_monitor.sh [--interval SECONDS] [--once]

set -uo pipefail
export LC_ALL=C

INTERVAL="${DOCKER_MONITOR_INTERVAL:-5}"
RUN_ONCE=0

usage() {
    cat <<'EOF'
Usage: docker_monitor.sh [OPTIONS]

  -i, --interval SECONDS  Refresh interval (default: 5)
      --once              Print one snapshot and exit
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
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] ||
    die "refresh interval must be a positive whole number"
command -v docker >/dev/null 2>&1 || die "docker is not installed or is not in PATH"
docker info >/dev/null 2>&1 ||
    die "cannot connect to Docker (check the daemon and your user permissions)"

# Docker uses binary units for memory and decimal units for block I/O.
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
        if (i == 1)         printf "%d B", bytes
        else if (bytes >= 100) printf "%.0f %s", bytes, units[i]
        else if (bytes >= 10)  printf "%.1f %s", bytes, units[i]
        else                   printf "%.2f %s", bytes, units[i]
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

memory_text() {
    if (($2 > 0)); then
        printf '%s / %s' "$(human_bytes "$1")" "$(human_bytes "$2")"
    else
        printf '%s / uncapped' "$(human_bytes "$1")"
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

clear_terminal() { [[ -t 1 ]] && printf '\033[H\033[2J'; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h'; }
trap show_cursor EXIT
trap 'exit 0' INT TERM
[[ -t 1 ]] && printf '\033[?25l'

render_snapshot() {
    local -a ids metadata groups
    local stats_output inspect_output
    local line name cpu_text mem_text io_text mem_used_text io_read_text io_write_text
    local full_id stack swarm_stack mem_limit writable cpu_value mem_used io_read io_write
    local current_stack=''

    mapfile -t ids < <(docker ps -q)
    if ((${#ids[@]} == 0)); then
        clear_terminal
        printf 'Docker Resource Monitor | %s | %s | refresh %ss\n\n' \
            "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$INTERVAL"
        printf 'No running containers.\n'
        return
    fi

    # A single call samples all containers together. The old per-field,
    # per-container calls made the display populate one container at a time.
    if ! stats_output=$(docker stats --no-stream \
        --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}' 2>&1); then
        clear_terminal
        printf 'Docker stats failed:\n%s\n' "$stats_output" >&2
        return
    fi

    # SizeRw is current writable-layer usage. A container that exits between
    # ps and inspect is harmless; valid remaining inspect rows are retained.
    inspect_output=$(docker inspect --size \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.stack.namespace"}}|{{.HostConfig.Memory}}|{{.SizeRw}}' \
        "${ids[@]}" 2>/dev/null || true)
    [[ -n "$inspect_output" ]] || {
        clear_terminal
        printf 'Docker inspect returned no running containers.\n' >&2
        return
    }

    declare -A stat_cpu=() stat_mem=() stat_read=() stat_write=()
    while IFS='|' read -r name cpu_text mem_text io_text; do
        [[ -n "$name" ]] || continue
        mem_used_text=${mem_text%% / *}
        io_read_text=${io_text%% / *}
        io_write_text=${io_text#* / }
        stat_cpu["$name"]=$(pct_to_hundredths "$cpu_text")
        stat_mem["$name"]=$(to_bytes "$mem_used_text")
        stat_read["$name"]=$(to_bytes "$io_read_text")
        stat_write["$name"]=$(to_bytes "$io_write_text")
    done <<< "$stats_output"

    # Stable ordering prevents rows from jumping around between refreshes.
    mapfile -t metadata < <(
        while IFS='|' read -r full_id name stack swarm_stack mem_limit writable; do
            [[ -n "$full_id" ]] || continue
            name=${name#/}
            if [[ -z "$stack" || "$stack" == '<no value>' ]]; then
                stack=$swarm_stack
            fi
            [[ -n "$stack" && "$stack" != '<no value>' ]] || stack='(standalone)'
            [[ "$mem_limit" =~ ^[0-9]+$ ]] || mem_limit=0
            [[ "$writable" =~ ^[0-9]+$ ]] || writable=0
            printf '%s|%s|%s|%s|%s\n' \
                "$stack" "$name" "$full_id" "$mem_limit" "$writable"
        done <<< "$inspect_output" | sort -t '|' -k1,1 -k2,2
    )

    declare -A group_seen=() group_count=() group_cpu=() group_mem=()
    declare -A group_limit=() group_uncapped=() group_writable=()
    declare -A group_read=() group_write=()
    local total_cpu=0 total_mem=0 total_limit=0 total_uncapped=0
    local total_writable=0 total_read=0 total_write=0

    for line in "${metadata[@]}"; do
        IFS='|' read -r stack name full_id mem_limit writable <<< "$line"
        cpu_value=${stat_cpu["$name"]:-0}
        mem_used=${stat_mem["$name"]:-0}
        io_read=${stat_read["$name"]:-0}
        io_write=${stat_write["$name"]:-0}

        if [[ -z ${group_seen["$stack"]+x} ]]; then
            group_seen["$stack"]=1
            groups+=("$stack")
        fi

        group_count["$stack"]=$(( ${group_count["$stack"]:-0} + 1 ))
        group_cpu["$stack"]=$(( ${group_cpu["$stack"]:-0} + cpu_value ))
        group_mem["$stack"]=$(( ${group_mem["$stack"]:-0} + mem_used ))
        group_writable["$stack"]=$(( ${group_writable["$stack"]:-0} + writable ))
        group_read["$stack"]=$(( ${group_read["$stack"]:-0} + io_read ))
        group_write["$stack"]=$(( ${group_write["$stack"]:-0} + io_write ))

        total_cpu=$((total_cpu + cpu_value))
        total_mem=$((total_mem + mem_used))
        total_writable=$((total_writable + writable))
        total_read=$((total_read + io_read))
        total_write=$((total_write + io_write))

        if ((mem_limit > 0)); then
            group_limit["$stack"]=$(( ${group_limit["$stack"]:-0} + mem_limit ))
            total_limit=$((total_limit + mem_limit))
        else
            group_uncapped["$stack"]=1
            total_uncapped=1
        fi
    done

    clear_terminal
    printf 'Docker Resource Monitor | %s | %s | refresh %ss\n' \
        "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$INTERVAL"
    printf 'Running: %d container(s) in %d stack group(s)\n\n' \
        "${#metadata[@]}" "${#groups[@]}"

    printf '%-34s | %9s | %-25s | %12s | %-25s\n' \
        'CONTAINER' 'CPU' 'MEMORY USED / LIMIT' 'WRITABLE' 'BLOCK I/O READ / WRITE'
    printf '%s\n' \
        '-----------------------------------+-----------+---------------------------+--------------+--------------------------'

    for line in "${metadata[@]}"; do
        IFS='|' read -r stack name full_id mem_limit writable <<< "$line"
        if [[ "$stack" != "$current_stack" ]]; then
            [[ -z "$current_stack" ]] || printf '\n'
            printf '[stack: %s]\n' "$stack"
            current_stack=$stack
        fi

        cpu_value=${stat_cpu["$name"]:-0}
        mem_used=${stat_mem["$name"]:-0}
        io_read=${stat_read["$name"]:-0}
        io_write=${stat_write["$name"]:-0}
        printf '%-34s | %9s | %-25s | %12s | %-25s\n' \
            "$(clip "$name" 34)" \
            "$(human_pct "$cpu_value")" \
            "$(memory_text "$mem_used" "$mem_limit")" \
            "$(human_bytes "$writable")" \
            "$(human_bytes "$io_read") / $(human_bytes "$io_write")"
    done

    printf '\nSTACK TOTALS\n'
    printf '%-30s | %5s | %9s | %-25s | %12s | %-25s\n' \
        'STACK' 'COUNT' 'CPU' 'MEMORY USED / LIMIT' 'WRITABLE' 'BLOCK I/O READ / WRITE'
    printf '%s\n' \
        '-------------------------------+-------+-----------+---------------------------+--------------+--------------------------'

    for stack in "${groups[@]}"; do
        mem_limit=${group_limit["$stack"]:-0}
        if ((${group_uncapped["$stack"]:-0})); then
            mem_text="$(human_bytes "${group_mem["$stack"]}") / uncapped"
        else
            mem_text="$(human_bytes "${group_mem["$stack"]}") / $(human_bytes "$mem_limit")"
        fi
        printf '%-30s | %5d | %9s | %-25s | %12s | %-25s\n' \
            "$(clip "$stack" 30)" \
            "${group_count["$stack"]}" \
            "$(human_pct "${group_cpu["$stack"]}")" \
            "$mem_text" \
            "$(human_bytes "${group_writable["$stack"]}")" \
            "$(human_bytes "${group_read["$stack"]}") / $(human_bytes "${group_write["$stack"]}")"
    done

    if ((total_uncapped)); then
        mem_text="$(human_bytes "$total_mem") / uncapped"
    else
        mem_text="$(human_bytes "$total_mem") / $(human_bytes "$total_limit")"
    fi
    printf '%s\n' \
        '-------------------------------+-------+-----------+---------------------------+--------------+--------------------------'
    printf '%-30s | %5d | %9s | %-25s | %12s | %-25s\n' \
        'ALL RUNNING CONTAINERS' "${#metadata[@]}" "$(human_pct "$total_cpu")" \
        "$mem_text" "$(human_bytes "$total_writable")" \
        "$(human_bytes "$total_read") / $(human_bytes "$total_write")"

    printf '\nWritable = current container writable-layer size; images, bind mounts, and volumes are excluded.\n'
    printf 'Block I/O = cumulative disk reads/writes since container start; it is activity, not allocated space.\n'
    printf 'Uncapped = at least one container in that row has no explicit memory limit. Ctrl+C exits.\n'
}

while true; do
    render_snapshot
    ((RUN_ONCE)) && break
    sleep "$INTERVAL"
done
