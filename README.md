# homelab-backup-stack

> **3-2-1 backup pipeline for Proxmox homelab: PBS (local deduplicated snapshots) + rclone → pCloud (offsite).**
> Architecture: host-directory bind-mount shared between PBS LXC and rclone-sync LXC — no loop devices, no race conditions.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PBS](https://img.shields.io/badge/Proxmox_Backup_Server-4.x-orange)](https://www.proxmox.com/en/proxmox-backup-server)

---

## Architecture

```
PVE VMs/LXCs  ──backup──►  CT201 PBS-Server           CT204 rclone-sync
                             /var/lib/proxmox-backup/   /mnt/pbs-backup/ (RO)
                                       │                       │
                                       └───── both bind-mount ──┘
                                              /mnt/pbs-store/      ← pve-03 host dir (2026-08-16 migration óta)
                                                    │
                                                    └── rclone sync --delete-after (cron 02:00)
                                                              │
                                                        pCloud EU (eapi.pcloud.com)
                                                        homelab/pbs-backups/   ← SINGLE archive (PBS mirror)
```

**Single-sync design (consolidated 2026-08-13):** only ONE rclone job runs — a cron-driven
`/usr/local/bin/backup-to-pcloud.sh` inside CT204, using `rclone sync --delete-after` to
`pcloud:homelab/pbs-backups`. The earlier duplicate systemd timer (`pbs-rclone-sync`) that
wrote to a second folder (`pcloud:Proxmox/PBS-backup`) was **removed** to eliminate the
2x duplication. pCloud is now a true mirror of the PBS datastore; the PBS **prune job**
(retention policy) is the single source of truth for what is kept on both sides.

### Why host-directory bind-mount (not loop mount)

| Approach | Problem |
|---|---|
| Loop mount `/dev/loop0` | CT201 already holds loop0 as its rootfs — double-mount impossible while CT runs |
| NFS server on LXC | `rpc-svcgssd` Kerberos dependency crashes on Proxmox LXC — unfixable |
| **Host bind-mount** ✓ | Simple directory, no device allocation, reboot-safe, RW for PBS / RO for rclone |

---

## Current deployment (pve-03)

> **2026-08-16:** CT201/CT204 **átköltöztetve pve-02 → pve-03**. Lásd
> [docs/pbs-pve02-to-pve03-migration.md](https://github.com/gaiagent0/homelab-backup-stack/blob/main/docs/pbs-pve02-to-pve03-migration.md)
> a teljes runbookért (3 Proxmox-buktató + pve-02 takarítás). pve-02 azóta üres quorum/standby node.

| Container | Role | Node | IP | Notes |
|---|---|---|---|---|
| **CT201** `pbs-server` | Proxmox Backup Server 4.2 | **pve-03** (10.10.40.13) | **10.10.40.14** | datastore `local` → `/var/lib/proxmox-backup/backups` (host `/mnt/pbs-store`, RW) |
| **CT204** `rclone-sync` | rclone → pCloud | **pve-03** | 10.10.40.204 | mounts `/mnt/pbs-store` **RO** at `/mnt/pbs-backup`; runs the nightly sync (05:00) |

> Reachability: CT201/CT204 live on the `10.10.40.0/24` VLAN, **on pve-03 (10.10.40.13)**. From a
> laptop on a different subnet (e.g. `10.10.20.x`) SSH to them directly fails — jump via the pve-03
> node (`10.10.40.13`) with `pct exec 201 -- …` / `pct exec 204 -- …`. (A `10.10.40.14` IP a CT201
> belső IP-je, maradt változatlan a migráció során — a cluster `pbs-server` storage erre mutat.)

### Retention policy (CT201 prune job `prune-all`)

| Parameter | Value | Effect |
|---|---|---|
| `keep-last` | **2** | keep the 2 most recent snapshots per group |
| `keep-monthly` | **1** | keep 1 monthly snapshot |
| `keep-daily` / `keep-weekly` / `keep-yearly` | — | removed (minimal local footprint) |
| schedule | `daily` | prune runs every night |

Pruning removes index references; run **garbage collection** after prune to free chunk space:
`proxmox-backup-manager garbage-collection start local`.

Because the pCloud sync uses `--delete-after`, the **same retention is enforced offsite**:
after each nightly sync, pCloud mirrors exactly what PBS keeps locally (2 recent + 1 monthly).
This is the "monthly cleanup" — there is no separate pCloud pruning step.

---

## Prerequisites

- Proxmox VE 8.x/9.x, two LXCs (2026-08-16 óta **pve-03-on**):
  - **CT201** `pbs-server` (IP **10.10.40.14**)
  - **CT204** `rclone-sync` (IP 10.10.40.204)
- rclone configured with a `pcloud` remote (EU endpoint `eapi.pcloud.com`)
- AppArmor bind-mount rules added (see [docs/apparmor.md](docs/apparmor.md))

---

## Quick Start

```bash
# On pve-03 host (2026-08-16 migration óta):
cp configs/env.example configs/env && nano configs/env

bash scripts/setup-host-dir.sh          # creates /mnt/pbs-store, sets ownership
bash scripts/setup-bind-mounts.sh       # configures CT201 (RW) and CT204 (RO) mp0
bash scripts/setup-rclone-timer.sh      # installs systemd service + timer in CT204

# Verify
pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.test && echo OK && rm /var/lib/proxmox-backup/backups/.test'
pct exec 204 -- ls /mnt/pbs-backup | head -5
```

> **NOTE:** the sync used in production is the cron-driven `backup-to-pcloud.sh` (destination
> `pcloud:homelab/pbs-backup`**`s`**), NOT the repo's `pbs-backup-sync.sh` systemd template
> (which wrote to `pcloud:Proxmox/PBS-backup` and was retired to avoid duplication). See
> [docs/pbs-rclone-backup.md](docs/pbs-rclone-backup.md) for the live script.

---

## Repository Structure

```
homelab-backup-stack/
├── README.md
├── docs/
│   ├── architecture.md       — Detailed bind-mount design and data flow
│   ├── apparmor.md           — LXC AppArmor rules for bind-mount paths
│   ├── pbs-retention.md      — Retention policy configuration (PBS API)
│   ├── rclone-pcloud.md      — pCloud remote setup and token refresh
│   ├── pbs-rclone-backup.md  — Live rclone sync script (CT204 cron)
│   ├── pbs-job-management.md — prune / GC job management via API
│   ├── pbs-ct-reinstall-runbook.md — CT201/CT204 reinstall procedure
│   ├── pbs-pve02-to-pve03-migration.md — 2026-08-16 CT201/CT204 migration pve-02->pve-03 + cleanup
│   └── disaster-recovery.md  — Full restore procedure from pCloud
├── scripts/
│   ├── setup-host-dir.sh     — Create /mnt/pbs-store, set UID 100034 ownership
│   ├── setup-bind-mounts.sh  — pct set for CT201 (RW) and CT204 (RO)
│   ├── setup-rclone-timer.sh — Install sync service + timer into CT204
│   ├── pbs-backup-sync.sh    — (retired template) rclone sync script — see docs/pbs-rclone-backup.md
│   └── pbs-pve02-to-pve03-migrate.sh — final-step migration script (node-name target, mp0 remove/re-add)
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
| `PBS_CT_ID` | `201` | PBS server LXC ID (CT201, IP 10.10.40.14) |
| `RCLONE_CT_ID` | `204` | rclone-sync LXC ID (CT204, IP 10.10.40.204) |
| `PBS_PBS_UID` | `100034` | host UID for CT PBS daemon (100000 + 34) |
| `RCLONE_REMOTE` | `pcloud:homelab/pbs-backups` | **single** rclone destination |
| `RCLONE_BWLIMIT` | `5M` | upload bandwidth cap |
| `SYNC_TIME` | `02:00:00` | nightly sync time (cron, avoids PBS backup window) |

---

## Security Notes

- **rclone token** is stored in `/root/.rclone.conf` inside CT204 — exclude from any LXC template exports.
- CT204 mount is explicitly `ro=1` — rclone cannot modify PBS data, eliminating accidental deletion risk on the source side.
- PBS datastore path is owned `100034:100034` — no other LXC or process has write access.
- The pCloud destination is a **mirror** (`sync --delete-after`): pruning on PBS automatically
  removes the corresponding offsite copies on the next sync. This is intended (3-2-1 offsite
  copy that follows the local retention) — do NOT treat pCloud as an independent long-term
  archive unless you switch to `rclone copy` + a separate pCloud retention step.
- Consider `--immutable` on pCloud destination once backup is verified, to prevent ransomware overwrites.

---

## UnPlanned Deletion Prevention

The rclone sync uses `--delete-after` — this deletes files at the pCloud destination that no
longer exist at the PBS source. If CT204's bind-mount is empty (mount failure), the sync
**will delete your pCloud backup**.

The live script (`backup-to-pcloud.sh`) guards against an empty source by checking the mount
is present before syncing; additionally, PBS chunk data is shared across snapshots, so the
retention policy (not file dates) drives what is kept. **Do not run `rclone delete` / age-based
cleanup on the pCloud folder** — the deduplicated chunks' mtimes are upload times, not backup
times, so age-based deletion corrupts recoverability. Rely on PBS prune + `--delete-after` instead.

---

*Tested on: Proxmox VE 8.3 → 9.2, PBS 4.2.5, rclone 1.67+, pCloud EU*
