# Docker Container Resources Usage Script

An interactive terminal dashboard for monitoring resources used by running Docker containers. Containers are automatically grouped by Docker Compose project or Docker Swarm stack, with totals shown for every group.

The dashboard is designed for local terminals and SSH sessions. It uses a bounded alternate screen, responsive columns, keyboard navigation, and optional mouse controls without filling terminal scrollback on every refresh.

## Features

- CPU usage and configured CPU limits
- Memory usage and configured memory limits
- Local storage used by container root filesystems, bind mounts, and Docker volumes
- Per-stack CPU, memory, storage, and container totals
- Overall totals across all running containers
- Docker Compose and Docker Swarm stack detection
- Collapsible stack groups with keyboard and mouse controls
- Runtime-adjustable refresh interval, with a minimum of one second
- Color-coded resource usage based on configured limits
- CPU model, logical core count, total RAM, and root-disk capacity
- Full snapshot output for scripts, logs, or redirected output

Only running containers are displayed.

## Requirements

- Linux
- Bash 4 or newer
- Docker Engine and the Docker CLI
- Permission to access the Docker daemon
- Standard Linux utilities: `awk`, `df`, `du`, `nproc`, `sort`, `stty`, and `mktemp`
- For interactive mode: an ANSI-compatible terminal at least 76 columns by 12 rows

Confirm that Docker is available to your user:

```bash
docker info
```

If that command fails, fix Docker daemon access before running the monitor. Membership in the `docker` group is effectively root-level access; review Docker's security guidance before granting it.

## Installation

```bash
git clone https://github.com/jasonc123456/Docker-Container-Resources-Usage-Script.git
cd Docker-Container-Resources-Usage-Script
chmod +x docker_monitor.sh
```

## Usage

Start the interactive dashboard with the default five-second refresh interval:

```bash
./docker_monitor.sh
```

Start with a different interval:

```bash
./docker_monitor.sh --interval 10
```

The minimum supported interval is one second:

```bash
./docker_monitor.sh --interval 1
```

Print one complete snapshot and exit:

```bash
./docker_monitor.sh --once
```

Disable colors:

```bash
./docker_monitor.sh --no-color
```

The standard `NO_COLOR` environment variable is also supported:

```bash
NO_COLOR=1 ./docker_monitor.sh
```

You can set the initial interval through an environment variable:

```bash
DOCKER_MONITOR_INTERVAL=15 ./docker_monitor.sh
```

Command-line options take precedence over the environment value.

## Interactive controls

| Key or action | Function |
| --- | --- |
| `Up` / `Down` | Select the previous or next stack |
| `Left` / `Right` | Collapse or expand the selected stack |
| `Enter` / `Space` | Toggle the selected stack |
| Mouse click | Select and toggle a stack header |
| Mouse wheel | Select the previous or next stack |
| `c` / `e` | Collapse or expand all stacks |
| `+` / `-` | Increase or decrease the refresh interval |
| `1`–`9` | Set the refresh interval directly in seconds |
| `0` / `d` | Restore the default five-second interval |
| `r` | Refresh immediately, including mounted-storage measurements |
| `q` | Quit and restore the original terminal screen |

## SSH usage

When already connected to a server through SSH, run the script normally:

```bash
./docker_monitor.sh
```

When launching it as a direct SSH command, allocate a pseudo-terminal so keyboard and mouse controls work:

```bash
ssh -t user@example.com '/path/to/Docker-Container-Resources-Usage-Script/docker_monitor.sh'
```

Without a TTY, the script uses full-report output instead of the interactive dashboard. Use `--once` when collecting a single report through automation:

```bash
ssh user@example.com '/path/to/docker_monitor.sh --once'
```

## Understanding the values

### CPU

Docker CPU percentage uses `100%` per logical CPU. A container using two complete logical CPUs may therefore show approximately `200%`.

The script detects explicit limits configured through NanoCPUs, CPU quota/period, or CPU-set restrictions. Containers without an explicit limit display `uncapped`.

### Memory

Memory is displayed as current usage followed by the configured container limit:

```text
546 MiB / 768 MiB
```

Containers without an explicit Docker memory limit display `uncapped` rather than the host's total memory.

### Colors

| Color | Meaning |
| --- | --- |
| Green | Less than 50% of the configured limit |
| Yellow | 50% through 79% of the configured limit |
| Red | 80% or more of the configured limit |
| Cyan | No explicit limit is configured |

Colors apply to CPU and memory when a meaningful limit is available.

### Storage

Per-container storage includes:

- The logical container root filesystem, including its image and writable layer
- Local bind-mounted files and directories
- Docker volume data reported by the Docker daemon

Nested bind mounts are deduplicated within a container. Shared mount sources are also deduplicated in stack and overall totals. Image layers remain logical per-container values and may be represented in more than one container total.

Mounted-storage measurements are cached for 30 seconds to avoid repeatedly scanning large directories. Press `r` to force an immediate storage rescan.

A trailing `+` means at least one mount could not be measured, so the displayed value is a known minimum:

```text
12.9 GiB+
```

The script first measures bind mounts from the host. If permissions prevent that, it attempts a read-only `du` through `docker exec -u 0` inside the running container. Minimal container images without `du`, inaccessible mounts, or unusual storage drivers may produce a trailing `+`.

Docker control mounts such as `/var/run/docker.sock` and `/var/lib/docker` are excluded because they represent host-wide Docker state rather than data owned by one container. Remote files uploaded to cloud, FTP, SMB, or other external storage are not local container usage and cannot be included.

## Stack grouping

The monitor checks these Docker labels in order:

1. `com.docker.compose.project`
2. `com.docker.stack.namespace`

Containers without either label are placed in the `(standalone)` group.

Stack storage totals deduplicate shared local mount sources so, for example, the same website directory mounted by both an application and its backup container is not counted twice in that stack's total.

## Refresh behavior

The default refresh interval is five seconds. Keyboard and mouse actions are handled independently of that interval, including while the next Docker snapshot is being collected. The dashboard keeps showing the previous complete snapshot during collection, builds each changed frame off-screen, and sends it to the terminal in one update. It also uses the terminal's alternate screen, so normal shell scrollback is restored after quitting.

At a one-second setting, Docker's own statistics sampling and filesystem measurement time may make the effective interval longer than exactly one second on busy hosts.

Host CPU, core count, total RAM, and root-disk information are collected once at startup. CPU and memory container statistics update each refresh. Mounted-storage sizes are refreshed every 30 seconds or when `r` is pressed.

## Troubleshooting

### Cannot connect to Docker

```text
Error: cannot connect to Docker
```

Verify that Docker is running and your user can execute `docker info`.

### Interactive controls do not work

Ensure the process has a TTY. For direct SSH commands, use `ssh -t`. Mouse support also depends on the local terminal emulator supporting SGR mouse reporting.

### No colors are displayed

Check that `TERM` is set to a capable terminal type and that `NO_COLOR` is not present:

```bash
printf '%s\n' "$TERM"
env | grep '^NO_COLOR='
```

### The terminal is too small

Resize it to at least 76 columns by 12 rows. Wider terminals display longer container and stack names.

### Storage differs from an archive or remote backup

The dashboard reports data currently stored on the Docker host. A backup file that is uploaded and then deleted locally is not part of current local usage. Press `r` after creating or deleting large local files to force a new mount scan.

## Command reference

```text
Usage: docker_monitor.sh [OPTIONS]

  -i, --interval SECONDS  Initial refresh interval (minimum/default: 1/5)
      --once              Print one full snapshot and exit
      --no-color          Disable terminal colors
  -h, --help              Show this help
```
