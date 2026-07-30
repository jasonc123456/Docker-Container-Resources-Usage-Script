#!/usr/bin/env bash
# Interactive Docker resource monitor grouped by Compose/Swarm stack.

set -uo pipefail
export LC_ALL=C

DEFAULT_INTERVAL=5
INTERVAL="${DOCKER_MONITOR_INTERVAL:-$DEFAULT_INTERVAL}"
RUN_ONCE=0
COLOR_ENABLED=1

usage() {
    cat <<'EOF'
Usage: docker_monitor.sh [OPTIONS]

  -i, --interval SECONDS  Initial refresh interval (minimum/default: 1/5)
      --once              Print one full snapshot and exit
      --no-color          Disable terminal colors
  -h, --help              Show this help

Interactive keys:
  Up/Down       Select a stack
  Left/Right    Collapse/expand the selected stack
  Enter/Space   Toggle the selected stack
  Mouse click   Select and toggle a stack header
  c / e         Collapse all / expand all stacks
  + / -         Increase / decrease refresh interval (minimum 1 second)
  1..9          Set refresh interval directly
  0 / d         Reset refresh interval to the 5-second default
  r             Refresh now
  q             Quit
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

INTERACTIVE=0
if [[ -t 0 && -t 1 && $RUN_ONCE -eq 0 ]]; then
    INTERACTIVE=1
fi
if [[ ! -t 1 || -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then
    COLOR_ENABLED=0
fi

RESET='' BOLD='' DIM='' REVERSE='' RED='' YELLOW='' GREEN='' CYAN='' MAGENTA=''
if ((COLOR_ENABLED)); then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    REVERSE=$'\033[7m'
    RED=$'\033[1;31m'
    YELLOW=$'\033[1;33m'
    GREEN=$'\033[1;32m'
    CYAN=$'\033[1;36m'
    MAGENTA=$'\033[1;35m'
fi

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
                } else if (entries[i] != "") count++
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

# Green below 50%, yellow at 50-79%, red at 80%+, cyan when uncapped.
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
    if ((width < 1)); then
        return
    elif ((${#text} > width && width > 3)); then
        printf '%s...' "${text:0:width-3}"
    elif ((${#text} > width)); then
        printf '%s' "${text:0:width}"
    else
        printf '%s' "$text"
    fi
}

# Pad before adding ANSI sequences so colored columns stay aligned.
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

storage_text() {
    local text
    text=$(human_bytes "$1")
    if (($2 > 0)); then printf '%s+' "$text"; else printf '%s' "$text"; fi
}

# Host information is deliberately captured once, before the refresh loop.
CPU_MODEL=$(awk -F ': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
[[ -n "$CPU_MODEL" ]] || CPU_MODEL=$(uname -m)
CPU_CORES=$(nproc --all 2>/dev/null || printf '?')
RAM_TOTAL_BYTES=$(awk '/MemTotal:/{printf "%.0f", $2 * 1024; exit}' /proc/meminfo 2>/dev/null)
[[ "$RAM_TOTAL_BYTES" =~ ^[0-9]+$ ]] || RAM_TOTAL_BYTES=0
read -r ROOT_DISK_USED ROOT_DISK_TOTAL < <(
    df -B1 --output=used,size / 2>/dev/null | awk 'NR == 2 {print $1, $2}'
)
[[ "${ROOT_DISK_USED:-}" =~ ^[0-9]+$ ]] || ROOT_DISK_USED=0
[[ "${ROOT_DISK_TOTAL:-}" =~ ^[0-9]+$ ]] || ROOT_DISK_TOTAL=0
HOST_CPU_TEXT="CPU: $CPU_MODEL | $CPU_CORES logical cores"
HOST_CAPACITY_TEXT="RAM: $(human_bytes "$RAM_TOTAL_BYTES") total | Root disk: $(human_bytes "$ROOT_DISK_USED") / $(human_bytes "$ROOT_DISK_TOTAL") used"

declare -a META=() STACKS=()
declare -A STAT_CPU=() STAT_MEM=() COLLAPSED=()
declare -A GROUP_COUNT=() GROUP_CPU=() GROUP_CPU_LIMIT=() GROUP_CPU_UNCAPPED=()
declare -A GROUP_MEM=() GROUP_MEM_LIMIT=() GROUP_MEM_UNCAPPED=()
declare -A GROUP_STORAGE=() GROUP_STORAGE_UNKNOWN=()
declare -A ROW_TO_STACK=()
declare -A MOUNT_SIZE_CACHE=() MOUNT_KNOWN_CACHE=() VOLUME_SIZE=()
TOTAL_CPU=0 TOTAL_CPU_LIMIT=0 TOTAL_CPU_UNCAPPED=0
TOTAL_MEM=0 TOTAL_MEM_LIMIT=0 TOTAL_MEM_UNCAPPED=0
TOTAL_STORAGE=0 TOTAL_STORAGE_UNKNOWN=0
SNAPSHOT_TIME='' LAST_ERROR='' STATUS_MESSAGE='Ready'
SELECTED_INDEX=0 SCROLL_OFFSET=0 EXIT_REQUESTED=0 ACTION_REFRESH=0 UI_DIRTY=1
NEXT_REFRESH=0
ORIGINAL_STTY=''
FRAME_FILE='' CAPTURE_FILE=''
MOUNT_SCAN_INTERVAL=30 LAST_MOUNT_SCAN=-1

clear_snapshot_data() {
    META=() STACKS=()
    STAT_CPU=() STAT_MEM=()
    GROUP_COUNT=() GROUP_CPU=() GROUP_CPU_LIMIT=() GROUP_CPU_UNCAPPED=()
    GROUP_MEM=() GROUP_MEM_LIMIT=() GROUP_MEM_UNCAPPED=()
    GROUP_STORAGE=() GROUP_STORAGE_UNKNOWN=()
    TOTAL_CPU=0 TOTAL_CPU_LIMIT=0 TOTAL_CPU_UNCAPPED=0
    TOTAL_MEM=0 TOTAL_MEM_LIMIT=0 TOTAL_MEM_UNCAPPED=0
    TOTAL_STORAGE=0 TOTAL_STORAGE_UNKNOWN=0
}

# Run a potentially slow command in the background while the foreground shell
# continues to process keyboard and mouse events. The completed command output
# is assigned to the variable named by the first argument.
capture_command() {
    local output_name=$1 captured_text status pid
    shift

    if ((!INTERACTIVE)); then
        captured_text=$("$@" 2>&1)
        status=$?
        printf -v "$output_name" '%s' "$captured_text"
        return "$status"
    fi

    "$@" >"$CAPTURE_FILE" 2>&1 < /dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        service_ui 0.05
        if ((EXIT_REQUESTED)); then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            printf -v "$output_name" ''
            return 130
        fi
    done
    wait "$pid"
    status=$?
    captured_text=$(<"$CAPTURE_FILE")
    printf -v "$output_name" '%s' "$captured_text"
    return "$status"
}

refresh_mount_cache_if_due() {
    local output volume size
    if ((LAST_MOUNT_SCAN >= 0 && SECONDS - LAST_MOUNT_SCAN < MOUNT_SCAN_INTERVAL)); then
        return
    fi
    MOUNT_SIZE_CACHE=() MOUNT_KNOWN_CACHE=() VOLUME_SIZE=()
    if ! capture_command output docker system df -v \
        --format '{{range .Volumes}}{{println .Name "|" .Size}}{{end}}'; then
        output=''
    fi
    ((EXIT_REQUESTED)) && return 1
    while IFS='|' read -r volume size; do
        volume=${volume//[[:space:]]/}
        size=${size//[[:space:]]/}
        [[ -n "$volume" ]] || continue
        VOLUME_SIZE["$volume"]=$(to_bytes "$size")
    done <<< "$output"
    LAST_MOUNT_SCAN=$SECONDS
}

# Sets MEASURED_MOUNT_BYTES, MEASURED_MOUNT_UNKNOWN and MEASURED_MOUNT_KEYS.
# Nested bind mounts are counted through their parent, and host Docker-control
# mounts are excluded because they are not data owned by the container.
measure_container_mounts() {
    local container=$1 spec=$2 entry type volume source destination key result size known
    local other other_type other_volume other_source other_destination skip
    local -a entries=()
    local -A seen=()
    MEASURED_MOUNT_BYTES=0 MEASURED_MOUNT_UNKNOWN=0 MEASURED_MOUNT_KEYS=''
    IFS='^' read -ra entries <<< "$spec"

    for entry in "${entries[@]}"; do
        [[ -n "$entry" ]] || continue
        IFS='~' read -r type volume source destination <<< "$entry"
        [[ -n "$source" && -n "$destination" ]] || continue
        if [[ "$source" == /var/run/docker.sock || "$source" == /var/lib/docker ||
              "$source" == /var/lib/docker/* ]]; then
            continue
        fi

        skip=0
        if [[ "$type" == bind ]]; then
            for other in "${entries[@]}"; do
                [[ -n "$other" && "$other" != "$entry" ]] || continue
                IFS='~' read -r other_type other_volume other_source other_destination <<< "$other"
                if [[ "$other_type" == bind && "$source" == "$other_source"/* ]]; then
                    skip=1
                    break
                fi
            done
        fi
        ((skip)) && continue

        if [[ "$type" == volume && -n "$volume" && "$volume" != '<no value>' ]]; then
            key="volume:$volume"
        else
            key="bind:$source"
        fi
        [[ -z ${seen["$key"]+x} ]] || continue
        seen["$key"]=1

        if [[ -n ${MOUNT_KNOWN_CACHE["$key"]+x} ]]; then
            size=${MOUNT_SIZE_CACHE["$key"]:-0}
            known=${MOUNT_KNOWN_CACHE["$key"]}
        else
            size=0 known=0
            if [[ "$type" == volume && -n ${VOLUME_SIZE["$volume"]+x} ]]; then
                size=${VOLUME_SIZE["$volume"]}
                known=1
            elif capture_command result du -sb -- "$source"; then
                size=${result%%[[:space:]]*}
                [[ "$size" =~ ^[0-9]+$ ]] && known=1
            elif capture_command result docker exec -u 0 "$container" du -sb "$destination"; then
                size=${result%%[[:space:]]*}
                [[ "$size" =~ ^[0-9]+$ ]] && known=1
            fi
            ((EXIT_REQUESTED)) && return 1
            [[ "$size" =~ ^[0-9]+$ ]] || size=0
            MOUNT_SIZE_CACHE["$key"]=$size
            MOUNT_KNOWN_CACHE["$key"]=$known
        fi

        MEASURED_MOUNT_BYTES=$((MEASURED_MOUNT_BYTES + size))
        ((known)) || MEASURED_MOUNT_UNKNOWN=$((MEASURED_MOUNT_UNKNOWN + 1))
        MEASURED_MOUNT_KEYS+="$key~$size~$known^"
    done
    return 0
}

collect_snapshot() {
    local -a ids raw_meta measured_meta
    local -A next_cpu=() next_mem=()
    local ps_output stats_output inspect_output
    local name cpu_raw mem_raw mem_used_raw
    local full_id stack swarm_stack mem_limit rootfs storage nano quota period cpuset cpu_limit mounts
    local line cpu_used mem_used mount_entry mount_key mount_size mount_known mount_unknown

    LAST_ERROR=''
    STATUS_MESSAGE='Collecting snapshot...'

    if ! capture_command ps_output docker ps -q; then
        ((EXIT_REQUESTED)) && return 1
        LAST_ERROR="Docker ps failed: $ps_output"
        STATUS_MESSAGE=$LAST_ERROR
        UI_DIRTY=1
        return 1
    fi
    while IFS= read -r full_id; do
        [[ -n "$full_id" ]] && ids+=("$full_id")
    done <<< "$ps_output"

    if ((${#ids[@]} == 0)); then
        clear_snapshot_data
        SELECTED_INDEX=0 SCROLL_OFFSET=0
        SNAPSHOT_TIME=$(date '+%H:%M:%S')
        STATUS_MESSAGE='No running containers'
        return 0
    fi

    if ! capture_command stats_output docker stats --no-stream \
        --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}'; then
        ((EXIT_REQUESTED)) && return 1
        LAST_ERROR="Docker stats failed: $stats_output"
        STATUS_MESSAGE=$LAST_ERROR
        UI_DIRTY=1
        return 1
    fi

    if ! capture_command inspect_output docker inspect --size \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.stack.namespace"}}|{{.HostConfig.Memory}}|{{.SizeRootFs}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.CpusetCpus}}|{{range .Mounts}}{{printf "%s~%s~%s~%s^" .Type (index . "Name") .Source .Destination}}{{end}}' \
        "${ids[@]}"; then
        ((EXIT_REQUESTED)) && return 1
        LAST_ERROR="Docker inspect failed: $inspect_output"
        STATUS_MESSAGE=$LAST_ERROR
        UI_DIRTY=1
        return 1
    fi
    if [[ -z "$inspect_output" ]]; then
        LAST_ERROR='Docker inspect returned no running containers'
        STATUS_MESSAGE=$LAST_ERROR
        UI_DIRTY=1
        return 1
    fi

    while IFS='|' read -r name cpu_raw mem_raw; do
        [[ -n "$name" ]] || continue
        mem_used_raw=${mem_raw%% / *}
        next_cpu["$name"]=$(pct_to_hundredths "$cpu_raw")
        next_mem["$name"]=$(to_bytes "$mem_used_raw")
    done <<< "$stats_output"

    mapfile -t raw_meta < <(
        while IFS='|' read -r full_id name stack swarm_stack mem_limit rootfs nano quota period cpuset mounts; do
            [[ -n "$full_id" ]] || continue
            name=${name#/}
            if [[ -z "$stack" || "$stack" == '<no value>' ]]; then stack=$swarm_stack; fi
            [[ -n "$stack" && "$stack" != '<no value>' ]] || stack='(standalone)'
            [[ "$mem_limit" =~ ^[0-9]+$ ]] || mem_limit=0
            [[ "$rootfs" =~ ^[0-9]+$ ]] || rootfs=0
            cpu_limit=$(cpu_limit_hundredths "$nano" "$quota" "$period" "$cpuset")
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$stack" "$name" "$full_id" "$mem_limit" "$rootfs" "$cpu_limit" "$mounts"
        done <<< "$inspect_output" | sort -t '|' -k1,1 -k2,2
    )

    refresh_mount_cache_if_due || return 1
    measured_meta=()
    for line in "${raw_meta[@]}"; do
        IFS='|' read -r stack name full_id mem_limit rootfs cpu_limit mounts <<< "$line"
        measure_container_mounts "$name" "$mounts" || return 1
        storage=$((rootfs + MEASURED_MOUNT_BYTES))
        measured_meta+=("$stack|$name|$full_id|$mem_limit|$storage|$cpu_limit|$MEASURED_MOUNT_UNKNOWN|$rootfs|$MEASURED_MOUNT_KEYS")
    done

    # Commit only after every slow command has completed. Until this point the
    # prior snapshot remains intact and can be redrawn for any UI action.
    clear_snapshot_data
    for name in "${!next_cpu[@]}"; do
        STAT_CPU["$name"]=${next_cpu["$name"]}
        STAT_MEM["$name"]=${next_mem["$name"]}
    done

    declare -A seen=() group_mount_seen=() total_mount_seen=()
    for line in "${measured_meta[@]}"; do
        IFS='|' read -r stack name full_id mem_limit storage cpu_limit mount_unknown rootfs mounts <<< "$line"
        META+=("$stack|$name|$full_id|$mem_limit|$storage|$cpu_limit|$mount_unknown")
        cpu_used=${STAT_CPU["$name"]:-0}
        mem_used=${STAT_MEM["$name"]:-0}
        if [[ -z ${seen["$stack"]+x} ]]; then
            seen["$stack"]=1
            STACKS+=("$stack")
            [[ -n ${COLLAPSED["$stack"]+x} ]] || COLLAPSED["$stack"]=0
        fi
        GROUP_COUNT["$stack"]=$(( ${GROUP_COUNT["$stack"]:-0} + 1 ))
        GROUP_CPU["$stack"]=$(( ${GROUP_CPU["$stack"]:-0} + cpu_used ))
        GROUP_MEM["$stack"]=$(( ${GROUP_MEM["$stack"]:-0} + mem_used ))
        GROUP_STORAGE["$stack"]=$(( ${GROUP_STORAGE["$stack"]:-0} + rootfs ))
        TOTAL_CPU=$((TOTAL_CPU + cpu_used))
        TOTAL_MEM=$((TOTAL_MEM + mem_used))
        TOTAL_STORAGE=$((TOTAL_STORAGE + rootfs))

        IFS='^' read -ra mount_entries <<< "$mounts"
        for mount_entry in "${mount_entries[@]}"; do
            [[ -n "$mount_entry" ]] || continue
            IFS='~' read -r mount_key mount_size mount_known <<< "$mount_entry"
            if [[ -z ${group_mount_seen["$stack::$mount_key"]+x} ]]; then
                group_mount_seen["$stack::$mount_key"]=1
                GROUP_STORAGE["$stack"]=$(( ${GROUP_STORAGE["$stack"]:-0} + mount_size ))
                ((mount_known)) || GROUP_STORAGE_UNKNOWN["$stack"]=$(( ${GROUP_STORAGE_UNKNOWN["$stack"]:-0} + 1 ))
            fi
            if [[ -z ${total_mount_seen["$mount_key"]+x} ]]; then
                total_mount_seen["$mount_key"]=1
                TOTAL_STORAGE=$((TOTAL_STORAGE + mount_size))
                ((mount_known)) || TOTAL_STORAGE_UNKNOWN=$((TOTAL_STORAGE_UNKNOWN + 1))
            fi
        done

        if ((cpu_limit > 0)); then
            GROUP_CPU_LIMIT["$stack"]=$(( ${GROUP_CPU_LIMIT["$stack"]:-0} + cpu_limit ))
            TOTAL_CPU_LIMIT=$((TOTAL_CPU_LIMIT + cpu_limit))
        else
            GROUP_CPU_UNCAPPED["$stack"]=1
            TOTAL_CPU_UNCAPPED=1
        fi
        if ((mem_limit > 0)); then
            GROUP_MEM_LIMIT["$stack"]=$(( ${GROUP_MEM_LIMIT["$stack"]:-0} + mem_limit ))
            TOTAL_MEM_LIMIT=$((TOTAL_MEM_LIMIT + mem_limit))
        else
            GROUP_MEM_UNCAPPED["$stack"]=1
            TOTAL_MEM_UNCAPPED=1
        fi
    done

    ((${#STACKS[@]} == 0)) && SELECTED_INDEX=0
    ((${#STACKS[@]} > 0 && SELECTED_INDEX >= ${#STACKS[@]})) &&
        SELECTED_INDEX=$((${#STACKS[@]} - 1))
    ((TOTAL_CPU_UNCAPPED)) && TOTAL_CPU_LIMIT=0
    ((TOTAL_MEM_UNCAPPED)) && TOTAL_MEM_LIMIT=0
    SNAPSHOT_TIME=$(date '+%H:%M:%S')
    STATUS_MESSAGE="Snapshot $SNAPSHOT_TIME | mount sizes cached ${MOUNT_SCAN_INTERVAL}s"
    return 0
}

terminal_size() {
    local size
    size=$(stty size 2>/dev/null || true)
    read -r TERM_ROWS TERM_COLS <<< "$size"
    [[ "${TERM_ROWS:-}" =~ ^[0-9]+$ ]] || TERM_ROWS=24
    [[ "${TERM_COLS:-}" =~ ^[0-9]+$ ]] || TERM_COLS=120
}

set_column_widths() {
    if ((TERM_COLS >= 105)); then
        NAME_W=34 CPU_W=21 MEM_W=25 STORAGE_W=14
    elif ((TERM_COLS >= 90)); then
        CPU_W=20 MEM_W=22 STORAGE_W=12
        NAME_W=$((TERM_COLS - CPU_W - MEM_W - STORAGE_W - 10))
    else
        CPU_W=18 MEM_W=19 STORAGE_W=10
        NAME_W=$((TERM_COLS - CPU_W - MEM_W - STORAGE_W - 10))
    fi
}

print_table_row() {
    local first=$1 cpu=$2 memory=$3 storage=$4
    local first_color=${5:-} cpu_color=${6:-} mem_color=${7:-} storage_color=${8:-}
    print_cell "$first" "$NAME_W" left "$first_color"
    printf ' | '
    print_cell "$cpu" "$CPU_W" right "$cpu_color"
    printf ' | '
    print_cell "$memory" "$MEM_W" left "$mem_color"
    printf ' | '
    print_cell "$storage" "$STORAGE_W" right "$storage_color"
    printf '\n'
}

build_dashboard() {
    local -a row_types=() row_stacks=() row_names=()
    local line stack name full_id mem_limit storage storage_unknown cpu_limit cpu_used mem_used
    local cpu_limit_display mem_limit_display cpu_display mem_display
    local cpu_color mem_color first label i j selected_line=0
    local viewport content_count screen_row footer overall

    terminal_size
    ROW_TO_STACK=()
    if ((TERM_ROWS < 12 || TERM_COLS < 76)); then
        printf '%bDocker Resource Monitor%b\n' "$BOLD$CYAN" "$RESET"
        printf 'Terminal is too small: %sx%s. Minimum: 76 columns x 12 rows.\n' \
            "$TERM_COLS" "$TERM_ROWS"
        printf 'Resize the SSH terminal, or press q to quit.'
        UI_DIRTY=0
        return
    fi

    set_column_widths
    printf '%bDocker Resource Monitor%b | %s | refresh %ss | snapshot %s\n' \
        "$BOLD$CYAN" "$RESET" "$(hostname)" "$INTERVAL" "${SNAPSHOT_TIME:---:--:--}"
    printf '%s\n' "$(clip "$HOST_CPU_TEXT" "$((TERM_COLS - 1))")"
    printf '%s\n' "$(clip "$HOST_CAPACITY_TEXT" "$((TERM_COLS - 1))")"
    overall="Running ${#META[@]} | CPU $(human_pct "$TOTAL_CPU") | RAM $(human_bytes "$TOTAL_MEM") | Storage $(storage_text "$TOTAL_STORAGE" "$TOTAL_STORAGE_UNKNOWN")"
    printf '%b%s%b\n' "$BOLD" "$(clip "$overall" "$((TERM_COLS - 1))")" "$RESET"
    printf '%s\n' "$(clip 'Keys: arrows select/collapse | Enter/mouse toggle | +/- or 1..9 interval | 0/d default 5s | c/e all | r refresh | q quit' "$((TERM_COLS - 1))")"
    printf '%b' "$BOLD"
    print_table_row 'STACK / CONTAINER' 'CPU USED / LIMIT' 'MEMORY USED / LIMIT' 'STORAGE USED*'
    printf '%b' "$RESET$DIM"
    printf '%s\n' "$(clip '---------------------------------------------------------------------------------------------------------------' "$((TERM_COLS - 1))")"
    printf '%b' "$RESET"

    for stack in "${STACKS[@]}"; do
        row_types+=(stack)
        row_stacks+=("$stack")
        row_names+=('')
        if ((${COLLAPSED["$stack"]:-0} == 0)); then
            for line in "${META[@]}"; do
                IFS='|' read -r first name full_id mem_limit storage cpu_limit storage_unknown <<< "$line"
                [[ "$first" == "$stack" ]] || continue
                row_types+=(container)
                row_stacks+=("$stack")
                row_names+=("$name")
            done
        fi
    done
    if ((${#row_types[@]} == 0)); then
        row_types+=(message)
        row_stacks+=('')
        row_names+=("${LAST_ERROR:-No running containers}")
    fi

    if ((${#STACKS[@]} > 0)); then
        stack=${STACKS[$SELECTED_INDEX]}
        for ((i=0; i<${#row_types[@]}; i++)); do
            if [[ ${row_types[$i]} == stack && ${row_stacks[$i]} == "$stack" ]]; then
                selected_line=$i
                break
            fi
        done
    fi

    viewport=$((TERM_ROWS - 8))
    content_count=${#row_types[@]}
    ((selected_line < SCROLL_OFFSET)) && SCROLL_OFFSET=$selected_line
    ((selected_line >= SCROLL_OFFSET + viewport)) && SCROLL_OFFSET=$((selected_line - viewport + 1))
    ((SCROLL_OFFSET < 0)) && SCROLL_OFFSET=0
    ((SCROLL_OFFSET > content_count - viewport && content_count > viewport)) &&
        SCROLL_OFFSET=$((content_count - viewport))
    ((content_count <= viewport)) && SCROLL_OFFSET=0

    for ((j=0; j<viewport; j++)); do
        i=$((SCROLL_OFFSET + j))
        screen_row=$((8 + j))
        if ((i >= content_count)); then
            printf '\n'
            continue
        fi
        stack=${row_stacks[$i]}
        case ${row_types[$i]} in
            message)
                printf '%b%s%b\n' "$YELLOW" "$(clip "${row_names[$i]}" "$((TERM_COLS - 1))")" "$RESET"
                ;;
            stack)
                ROW_TO_STACK["$screen_row"]=$stack
                cpu_limit_display=${GROUP_CPU_LIMIT["$stack"]:-0}
                mem_limit_display=${GROUP_MEM_LIMIT["$stack"]:-0}
                ((${GROUP_CPU_UNCAPPED["$stack"]:-0})) && cpu_limit_display=0
                ((${GROUP_MEM_UNCAPPED["$stack"]:-0})) && mem_limit_display=0
                cpu_display=$(cpu_text "${GROUP_CPU["$stack"]}" "$cpu_limit_display")
                mem_display=$(memory_text "${GROUP_MEM["$stack"]}" "$mem_limit_display")
                cpu_color=$(resource_color "${GROUP_CPU["$stack"]}" "$cpu_limit_display")
                mem_color=$(resource_color "${GROUP_MEM["$stack"]}" "$mem_limit_display")
                if [[ ${STACKS[$SELECTED_INDEX]:-} == "$stack" ]]; then first='>'; else first=' '; fi
                if ((${COLLAPSED["$stack"]:-0})); then label='[+]'; else label='[-]'; fi
                first="$first $label $stack (${GROUP_COUNT["$stack"]})"
                print_table_row "$first" "$cpu_display" "$mem_display" \
                    "$(storage_text "${GROUP_STORAGE["$stack"]}" "${GROUP_STORAGE_UNKNOWN["$stack"]:-0}")" \
                    "$BOLD$MAGENTA" "$cpu_color" "$mem_color" "$CYAN"
                ;;
            container)
                name=${row_names[$i]}
                for line in "${META[@]}"; do
                    IFS='|' read -r first stack full_id mem_limit storage cpu_limit storage_unknown <<< "$line"
                    [[ "$stack" == "$name" ]] && break
                done
                cpu_used=${STAT_CPU["$name"]:-0}
                mem_used=${STAT_MEM["$name"]:-0}
                print_table_row "    $name" "$(cpu_text "$cpu_used" "$cpu_limit")" \
                    "$(memory_text "$mem_used" "$mem_limit")" "$(storage_text "$storage" "$storage_unknown")" \
                    '' "$(resource_color "$cpu_used" "$cpu_limit")" \
                    "$(resource_color "$mem_used" "$mem_limit")" "$CYAN"
                ;;
        esac
    done

    footer="Stack $((SELECTED_INDEX + 1))/${#STACKS[@]} | rows $((SCROLL_OFFSET + 1))-$((SCROLL_OFFSET + viewport < content_count ? SCROLL_OFFSET + viewport : content_count))/$content_count | refresh every ${INTERVAL}s | $STATUS_MESSAGE"
    printf '%b%s%b' "$REVERSE" "$(clip "$footer" "$((TERM_COLS - 1))")" "$RESET"
    UI_DIRTY=0
}

# Calculate the full frame before touching the screen, then submit it in one
# terminal write. This avoids row-by-row rendering over slower SSH links.
render_dashboard() {
    local frame
    build_dashboard > "$FRAME_FILE"
    frame=$(<"$FRAME_FILE")
    printf '\033[?2026h\033[H%s\033[J\033[?2026l' "$frame"
}

render_full_report() {
    local line stack name full_id mem_limit storage storage_unknown cpu_limit cpu_used mem_used
    printf '%bDocker Resource Monitor%b | %s | snapshot %s\n' "$BOLD$CYAN" "$RESET" "$(hostname)" "$SNAPSHOT_TIME"
    printf '%s\n%s\n' "$HOST_CPU_TEXT" "$HOST_CAPACITY_TEXT"
    printf 'Running: %d | CPU: %s | RAM: %s | Container storage: %s\n\n' \
        "${#META[@]}" "$(human_pct "$TOTAL_CPU")" "$(human_bytes "$TOTAL_MEM")" "$(storage_text "$TOTAL_STORAGE" "$TOTAL_STORAGE_UNKNOWN")"
    printf '%-34s | %21s | %-25s | %14s\n' 'STACK / CONTAINER' 'CPU USED / LIMIT' 'MEMORY USED / LIMIT' 'STORAGE USED*'
    printf '%s\n' '-----------------------------------+-----------------------+---------------------------+----------------'
    stack=''
    for line in "${META[@]}"; do
        IFS='|' read -r full_id name _ mem_limit storage cpu_limit storage_unknown <<< "$line"
        if [[ "$full_id" != "$stack" ]]; then
            stack=$full_id
            printf '[stack: %s] CPU %s | RAM %s | Storage %s\n' "$stack" \
                "$(human_pct "${GROUP_CPU["$stack"]}")" "$(human_bytes "${GROUP_MEM["$stack"]}")" \
                "$(storage_text "${GROUP_STORAGE["$stack"]}" "${GROUP_STORAGE_UNKNOWN["$stack"]:-0}")"
        fi
        cpu_used=${STAT_CPU["$name"]:-0}
        mem_used=${STAT_MEM["$name"]:-0}
        printf '  %-32s | %21s | %-25s | %14s\n' "$name" \
            "$(cpu_text "$cpu_used" "$cpu_limit")" "$(memory_text "$mem_used" "$mem_limit")" \
            "$(storage_text "$storage" "$storage_unknown")"
    done
    printf '\n* Storage = root filesystem plus mounted local data. Shared mounts are deduplicated in stack/host totals.\n'
    printf '  A trailing + means at least one mount could not be measured. Remote backups are not local storage.\n'
}

selected_stack() {
    ((${#STACKS[@]} > 0)) && printf '%s' "${STACKS[$SELECTED_INDEX]}"
}

toggle_selected() {
    local stack
    stack=$(selected_stack)
    [[ -n "$stack" ]] || return
    if ((${COLLAPSED["$stack"]:-0})); then COLLAPSED["$stack"]=0; else COLLAPSED["$stack"]=1; fi
    STATUS_MESSAGE="Toggled $stack"
    UI_DIRTY=1
}

select_delta() {
    local delta=$1 count=${#STACKS[@]}
    ((count > 0)) || return
    SELECTED_INDEX=$((SELECTED_INDEX + delta))
    ((SELECTED_INDEX < 0)) && SELECTED_INDEX=0
    ((SELECTED_INDEX >= count)) && SELECTED_INDEX=$((count - 1))
    UI_DIRTY=1
}

set_interval() {
    local value=$1
    ((value < 1)) && value=1
    INTERVAL=$value
    NEXT_REFRESH=$((SECONDS + INTERVAL))
    STATUS_MESSAGE="Refresh interval set to ${INTERVAL}s"
    UI_DIRTY=1
}

handle_mouse() {
    local body=$1 terminator=$2 button column row stack i
    [[ "$terminator" == M ]] || return
    IFS=';' read -r button column row <<< "$body"
    if [[ "$button" == 64 ]]; then
        select_delta -1
    elif [[ "$button" == 65 ]]; then
        select_delta 1
    elif [[ "$button" == 0 && -n ${ROW_TO_STACK["${row:-0}"]+x} ]]; then
        stack=${ROW_TO_STACK["$row"]}
        for ((i=0; i<${#STACKS[@]}; i++)); do
            if [[ ${STACKS[$i]} == "$stack" ]]; then SELECTED_INDEX=$i; break; fi
        done
        toggle_selected
    fi
}

handle_key() {
    local key=$1 second third char body terminator stack
    if [[ "$key" == $'\033' ]]; then
        IFS= read -rsn1 -t 0.05 second || return
        [[ "$second" == '[' ]] || return
        IFS= read -rsn1 -t 0.05 third || return
        case "$third" in
            A) select_delta -1 ;;
            B) select_delta 1 ;;
            C)
                stack=$(selected_stack); [[ -n "$stack" ]] && COLLAPSED["$stack"]=0
                UI_DIRTY=1
                ;;
            D)
                stack=$(selected_stack); [[ -n "$stack" ]] && COLLAPSED["$stack"]=1
                UI_DIRTY=1
                ;;
            '<')
                body=''
                while IFS= read -rsn1 -t 0.05 char; do
                    if [[ "$char" == M || "$char" == m ]]; then terminator=$char; break; fi
                    body+=$char
                    ((${#body} >= 40)) && break
                done
                handle_mouse "$body" "${terminator:-}"
                ;;
        esac
        return
    fi

    case "$key" in
        q|Q) EXIT_REQUESTED=1 ;;
        ''|' ') toggle_selected ;;
        c|C)
            for stack in "${STACKS[@]}"; do COLLAPSED["$stack"]=1; done
            STATUS_MESSAGE='Collapsed all stacks'; UI_DIRTY=1
            ;;
        e|E)
            for stack in "${STACKS[@]}"; do COLLAPSED["$stack"]=0; done
            STATUS_MESSAGE='Expanded all stacks'; UI_DIRTY=1
            ;;
        +|=) set_interval "$((INTERVAL + 1))" ;;
        -|_) set_interval "$((INTERVAL - 1))" ;;
        [1-9]) set_interval "$key" ;;
        0|d|D) set_interval "$DEFAULT_INTERVAL" ;;
        r|R) LAST_MOUNT_SCAN=-1; ACTION_REFRESH=1; STATUS_MESSAGE='Refreshing now'; UI_DIRTY=1 ;;
    esac
}

service_ui() {
    local timeout=${1:-0.20} key
    ((INTERACTIVE)) || return 0
    ((UI_DIRTY)) && render_dashboard
    if IFS= read -rsn1 -t "$timeout" key; then
        handle_key "$key"
        # Redraw in the same input cycle so navigation and collapse actions do
        # not wait for either the polling timeout or the snapshot interval.
        ((UI_DIRTY)) && render_dashboard
    fi
}

cleanup_terminal() {
    if ((INTERACTIVE)); then
        printf '\033[?1000l\033[?1006l\033[?25h\033[?1049l'
        [[ -n "$ORIGINAL_STTY" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || true
        if [[ "$FRAME_FILE" == /tmp/docker-monitor-frame.* ]]; then
            rm -f -- "$FRAME_FILE"
        fi
        if [[ "$CAPTURE_FILE" == /tmp/docker-monitor-command.* ]]; then
            rm -f -- "$CAPTURE_FILE"
        fi
    fi
}
trap cleanup_terminal EXIT
trap 'EXIT_REQUESTED=1; exit 0' INT TERM
trap 'UI_DIRTY=1' WINCH

if ((!INTERACTIVE)); then
    while true; do
        collect_snapshot || true
        render_full_report
        ((RUN_ONCE)) && break
        sleep "$INTERVAL"
    done
    exit 0
fi

# Alternate-screen mode prevents dashboard refreshes from filling scrollback.
ORIGINAL_STTY=$(stty -g 2>/dev/null || true)
stty -echo -icanon min 0 time 0 2>/dev/null || true
FRAME_FILE=$(mktemp /tmp/docker-monitor-frame.XXXXXX)
CAPTURE_FILE=$(mktemp /tmp/docker-monitor-command.XXXXXX)
printf '\033[?1049h\033[?25l\033[?1000h\033[?1006h\033[H\033[2J'
printf '%bDocker Resource Monitor%b\nCollecting the first snapshot...' "$BOLD$CYAN" "$RESET"
UI_DIRTY=0

while ((EXIT_REQUESTED == 0)); do
    ACTION_REFRESH=0
    collect_snapshot || true
    ((EXIT_REQUESTED)) && break
    NEXT_REFRESH=$((SECONDS + INTERVAL))
    UI_DIRTY=1

    while ((EXIT_REQUESTED == 0 && ACTION_REFRESH == 0 && SECONDS < NEXT_REFRESH)); do
        service_ui 0.20
    done
done

exit 0
