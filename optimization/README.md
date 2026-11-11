# Optimization Scripts

A collection of standalone scripts for system tuning and optimization.

- **status.sh**: Full system status, no root needed and changes nothing. Shows OS, CPU, memory, disks, GPU, network (latency, live TCP connection stats, retransmissions, conntrack) and power, plus every tweak supertune knows about:
  - green ✓ = set by the toolkit, cyan ✓ = already good without it, red ✗ = Full Supertune can improve it, no mark = info only.
  - `--bufferbloat` adds a ~10s lag-under-load test, `--no-ping` skips all network checks.

- **installscx.sh**: Installs the SCX Schedulers & Loader.
- **run_p2dq.sh**: Starts the low-latency SCX P2DQ scheduler.
- **setup-hugepages.sh**: Pre-allocates 2MB huge pages for optimal JVM performance.
- **install_psycachy.sh**: Installs the custom Psycachy low-latency kernel (Debian/Ubuntu only).
- **supertune.sh**: Adaptive system-wide low-latency tuning. It detects the machine (desktop, laptop, server, VM/VPS, Proxmox host, container) and only applies what helps there: memory/ZRAM, disk schedulers, CPU, IRQs, network, open-file limits and system settings. It never overrides values you set in your own `/etc/sysctl.d` files, and it respects an existing zram-generator setup.
  - `--dry-run` shows every change without making it (no root needed), `--status` shows the current state, `--report` prints a machine-readable state of every tweak (used by status.sh).
  - `--undo` restores the original values saved before the first run.
  - `--profile NAME` forces a profile, `--only`/`--skip` pick modules (`memory disk cpu irq network limits system`).
  - Also cleans up files left by older supertune, tcptune and ramtune versions.
- **tcptune.sh**: Network-only tuning (runs `supertune.sh --only network`).
- **ramtune.sh**: ZRAM and memory tuning only (runs `supertune.sh --only memory`).
- **undosupertune.sh**: Reverts supertune (runs `supertune.sh --undo`).
- **amd_gaming_tune.sh**: Dedicated AMD Ryzen CPU & Radeon GPU gaming tuning (locks DPM clocks, enables EPP performance, disables deep C-states for zero wake latency; desktop with cooling recommended).
