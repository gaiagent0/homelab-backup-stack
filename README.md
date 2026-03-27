# homelab-backup-stack

> **3-2-1 backup pipeline for Proxmox homelab: PBS (local deduplicated snapshots) + rclone → pCloud (offsite).**  
> Architecture: host-directory bind-mount shared between PBS LXC and rclone-sync LXC — no loop devices, no race conditions.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PBS](https://img.shields.io/badge/Proxmox_Backup_Server-3.x-orange)](https://www.proxmox.com/en/proxmox-backup-server)

---

## Architecture

```
PVE VMs/LXCs  ──backup──►  CT201 PBS-Server           CT204 rclone-sync
                             /var/lib/proxmox-backup/   /mnt/pbs-backup/ (RO)
                                       │                       │
                                       └───── both bind-mount ──┘
                                              /mnt/pbs-store/      ← pve-02 host dir
                                                    │
                                                    └── rclone sync (nightly 02:00)
                                                              │
                                                        pCloud EU (eapi.pcloud.com)
                                                        Proxmox/PBS-backup/
```

### Why host-directory bind-mount (not loop mount)

| Approach | Problem |
|---|---|
| Loop mount `/dev/loop0` | CT201 already holds loop0 as its rootfs — double-mount impossible while CT runs |
| NFS server on LXC | `rpc-svcgssd` Kerberos dependency crashes on Proxmox LXC — unfixable |
| **Host bind-mount** ✓ | Simple directory, no device allocation, reboot-safe, RW for PBS / RO for rclone |

---

## Prerequisites

- Proxmox VE 8.x, two LXCs on pve-02:
  - **CT201** `pbs-server` (IP: configurable)
  - **CT204** `rclone-sync` (IP: configurable)
- rclone configured with a remote (`pcloud`, `b2`, `s3`, etc.)
- AppArmor bind-mount rules added (see [docs/apparmor.md](docs/apparmor.md))

---

## Quick Start

```bash
# On pve-02 host:
cp configs/env.example configs/env && nano configs/env

bash scripts/setup-host-dir.sh          # creates /mnt/pbs-store, sets ownership
bash scripts/setup-bind-mounts.sh       # configures CT201 (RW) and CT204 (RO) mp0
bash scripts/setup-rclone-timer.sh      # installs systemd service + timer in CT204

# Verify
pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.test && echo OK && rm /var/lib/proxmox-backup/backups/.test'
pct exec 204 -- ls /mnt/pbs-backup | head -5
```

---

## Repository Structure

```
homelab-backup-stack/
├── README.md
├── docs/
│   ├── architecture.md       — Detailed bind-mount design and data flow
│   ├── apparmor.md           — LXC AppArmor rules for bind-mount paths
│   ├── pbs-retention.md      — Retention policy configuration (PBS 3.x API)
│   ├── rclone-pcloud.md      — pCloud remote setup and token refresh
│   └── disaster-recovery.md  — Full restore procedure from pCloud
├── scripts/
│   ├── setup-host-dir.sh     — Create /mnt/pbs-store, set UID 100034 ownership
│   ├── setup-bind-mounts.sh  — pct set for CT201 (RW) and CT204 (RO)
│   ├── setup-rclone-timer.sh — Install sync service + timer into CT204
│   └── pbs-backup-sync.sh    — rclone sync script (runs inside CT204)
├── templates/
│   ├── systemd/
│   │   ├── pbs-rclone-sync.service
│   │   └── pbs-rclone-sync.timer
│   └── apparmor/
│       └── lxc-default-cgns-pbs.patch
└── configs/
    └── env.example
```

---

## Key Configuration Parameters

| Variable | Default | Description |
|---|---|---|
| `PBS_HOST_DIR` | `/mnt/pbs-store` | Host backing directory |
| `PBS_CT_ID` | `201` | PBS server LXC ID |
| `RCLONE_CT_ID` | `204` | rclone-sync LXC ID |
| `PBS_PBS_UID` | `100034` | host UID for CT PBS daemon (100000 + 34) |
| `RCLONE_REMOTE` | `pcloud:Proxmox/PBS-backup` | rclone destination |
| `RCLONE_BWLIMIT` | `5M` | upload bandwidth cap |
| `SYNC_TIME` | `02:00:00` | nightly sync time (avoid PBS backup window) |

---

## Security Notes

- **rclone token** is stored in `/root/.rclone.conf` inside CT204 — exclude from any LXC template exports.
- CT204 mount is explicitly `ro=1` — rclone cannot modify PBS data, eliminating accidental deletion risk.
- PBS datastore path is owned `100034:100034` — no other LXC or process has write access.
- Consider `--immutable` on pCloud destination once backup is verified, to prevent ransomware overwrites.

---

## UnPlanned Deletion Prevention

The rclone script uses `sync` (not `copy`) — this deletes files at destination that no longer exist at source. If CT204 bind-mount is empty (mount failure), this **will delete your pCloud backup**.

The script includes a pre-flight guard:

```bash
SOURCE_COUNT=$(find "$SOURCE" -maxdepth 1 | wc -l)
if [ "$SOURCE_COUNT" -lt 5 ]; then
    echo "[ERROR] Source appears empty ($SOURCE_COUNT entries) — aborting sync!" | tee -a "$LOG"
    exit 1
fi
```

---

*Tested on: Proxmox VE 8.3, PBS 3.2, rclone 1.67, pCloud EU*
