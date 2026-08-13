# pbs-rclone-backup.md — Live rclone sync (CT204 cron)

> Documents the **production** offsite sync script running inside CT204 (`rclone-sync`).
> This is what actually runs nightly — distinct from the retired `scripts/pbs-backup-sync.sh`
> systemd template (which wrote to a duplicate `pcloud:Proxmox/PBS-backup` folder and was
> removed on 2026-08-13 to eliminate 2x duplication).

## What runs

- **Cron** (CT204, `root` crontab): `0 2 * * * /usr/local/bin/backup-to-pcloud.sh >> /var/log/rclone-cron.log 2>&1`
- The systemd `pbs-rclone-sync.timer` / `pbs-rclone-sync.service` units were **disabled and deleted**.
- Single destination: **`pcloud:homelab/pbs-backups`** (pCloud EU, `eapi.pcloud.com`).

## Live script: `/usr/local/bin/backup-to-pcloud.sh` (CT204)

```bash
#!/bin/bash
BACKUP_SOURCE="/mnt/pbs-backup"
PCLOUD_DEST="pcloud:homelab/pbs-backups"
LOG_FILE="/var/log/rclone-backup.log"
MAX_RETRIES=3
echo "=======================================" >> "$LOG_FILE"
echo "$(date +%Y-%m-%d\ %H:%M:%S): Backup sync STARTED" >> "$LOG_FILE"
echo "Source: $BACKUP_SOURCE | Dest: $PCLOUD_DEST" >> "$LOG_FILE"
if [ ! -d "$BACKUP_SOURCE" ]; then
  echo "$(date +%Y-%m-%d\ %H:%M:%S): ERROR: Source not mounted" >> "$LOG_FILE"
  exit 1
fi
CHUNK_COUNT=$(find "$BACKUP_SOURCE/.chunks" -type f 2>/dev/null | wc -l)
SOURCE_SIZE=$(du -sh "$BACKUP_SOURCE" 2>/dev/null | cut -f1)
echo "$(date +%Y-%m-%d\ %H:%M:%S): Chunks: $CHUNK_COUNT | Size: $SOURCE_SIZE" >> "$LOG_FILE"
RETRY=0
until [ $RETRY -ge $MAX_RETRIES ]; do
  echo "$(date +%Y-%m-%d\ %H:%M:%S): Attempt $((RETRY+1))/$MAX_RETRIES" >> "$LOG_FILE"
  rclone sync "$BACKUP_SOURCE" "$PCLOUD_DEST" \
    --delete-after \
    --transfers 4 --checkers 8 \
    --timeout 60m --retries 3 \
    --log-file="$LOG_FILE" --log-level INFO
  if [ $? -eq 0 ]; then
    echo "$(date +%Y-%m-%d\ %H:%M:%S): Sync SUCCESSFUL" >> "$LOG_FILE"
    break
  fi
  RETRY=$((RETRY+1))
  [ $RETRY -lt $MAX_RETRIES ] && sleep 120
done
[ $RETRY -ge $MAX_RETRIES ] && echo "$(date +%Y-%m-%d\ %H:%M:%S): SYNC FAILED" >> "$LOG_FILE" && exit 1
echo "$(date +%Y-%m-%d\ %H:%M:%S): COMPLETED" >> "$LOG_FILE"
```

## Key facts

- **`rclone sync --delete-after`** (not `copy`): pCloud is a mirror of the PBS datastore.
  Pruning on PBS → next sync removes the offsite copies too. This is the intended 3-2-1
  behaviour; the PBS **prune job** (`keep-last=2` + `keep-monthly=1`) is the single source
  of truth for retention on both sides.
- **Pre-flight guard**: aborts if `/mnt/pbs-backup` is not mounted (prevents wiping pCloud
  when the RO bind-mount is down).
- **No age-based deletion** on pCloud — PBS deduplication means chunk mtimes are upload times,
  so `rclone delete --min-age` would corrupt backups. Rely on prune + `--delete-after`.

## Changing the destination / retention

1. Edit `PCLOUD_DEST` in `backup-to-pcloud.sh` (currently `pcloud:homelab/pbs-backups`).
2. Retention is set on CT201: `proxmox-backup-manager prune-job update prune-all --keep-last 2 --keep-monthly 1`.
3. After any prune-job change, run GC: `proxmox-backup-manager garbage-collection start local`.

## Rollback

Old scripts are kept in CT204 as `.bak-<timestamp>` (e.g. `backup-to-pcloud.sh.bak-20260813-134438`).
The retired `scripts/pbs-backup-sync.sh` in this repo is the former systemd template.
