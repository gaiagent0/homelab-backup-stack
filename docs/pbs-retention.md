# PBS Retention Policy Configuration

> How to configure and manage Proxmox Backup Server retention policies via the API and UI.

---

## Default Retention Settings

This repo uses the following retention policy on the PBS datastore (`local`):

| Keep parameter | Value | Effect |
|---|---|---|
| `keep-last` | 2 | Always keep the 2 most recent backups |
| `keep-daily` | 7 | Keep 1 backup per day for the last 7 days |
| `keep-weekly` | 4 | Keep 1 backup per week for the last 4 weeks |
| `keep-monthly` | 3 | Keep 1 backup per month for the last 3 months |
| `keep-yearly` | 0 | No yearly retention |

These settings provide ~2 months of recovery points while keeping the datastore at ~6–12 GB for a typical 3-node homelab.

---

## Viewing Current Retention

```bash
# Inside CT201 (PBS server):
proxmox-backup-manager datastore show local

# Or via the PBS web UI:
# https://<pbs-ip>:8007 → Datastore → local → Options → Prune Options
```

---

## Applying Retention via CLI

```bash
# Inside CT201:
proxmox-backup-manager datastore update local \
  --keep-last 2 \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --keep-yearly 0

# Verify:
proxmox-backup-manager datastore show local | grep -A 10 "prune"
```

---

## Prune Jobs

Prune jobs enforce the retention policy by removing snapshots that fall outside the keep windows. They do **not** free disk space by themselves — run garbage collection afterward.

### List prune jobs

```bash
proxmox-backup-manager prune-job list
```

### Run prune manually

```bash
# Get the prune job ID from the list above
proxmox-backup-manager prune-job run <job-id>
```

### Create a scheduled prune job (daily at 03:00)

```bash
proxmox-backup-manager prune-job create daily-prune \
  --store local \
  --schedule "03:00" \
  --keep-last 2 \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3
```

---

## Garbage Collection

Pruning removes index references but the actual chunk data is only freed during garbage collection (GC). GC should run after every prune.

```bash
# Inside CT201:
proxmox-backup-manager garbage-collection start local

# Monitor GC progress:
proxmox-backup-manager task list | head -5

# Check freed space:
du -sh /var/lib/proxmox-backup/backups/
```

### Schedule GC automatically

Add a cron job inside CT201 (runs at 03:30, after the 03:00 prune job):

```bash
echo "30 3 * * * root proxmox-backup-manager garbage-collection start local >> /var/log/pbs-gc.log 2>&1" \
  >> /etc/cron.d/pbs-maintenance
```

---

## Datastore Statistics

View deduplication efficiency and storage usage:

```bash
# Inside CT201:
proxmox-backup-manager datastore show local

# Example output:
# total:          131072.0 MiB
# used:           5984.3   MiB
# avail:          125087.7 MiB
# dedup-factor:   23.1x
# chunk-count:    5201
```

A dedup factor of 20–30x is typical for VM/LXC backups that share a base OS image.

---

## Retention Sizing Guide

| Homelab size | keep-last | keep-daily | keep-weekly | keep-monthly | Est. datastore size |
|---|---|---|---|---|---|
| Small (1–3 VMs) | 2 | 7 | 4 | 3 | 5–15 GB |
| Medium (5–10 VMs) | 2 | 7 | 4 | 2 | 20–60 GB |
| Large (10+ VMs) | 1 | 5 | 2 | 1 | 50–150 GB |

Adjust `keep-*` parameters based on your available storage. The rclone offsite sync should always complete before the next backup job runs — set `SYNC_TIME` in `configs/env` to avoid overlap.

---

*Tested on: Proxmox Backup Server 3.2, PBS API v2*
