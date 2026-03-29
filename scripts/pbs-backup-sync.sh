#!/bin/bash
# ============================================================
# pbs-backup-sync.sh — PBS → rclone offsite sync
# Runs inside CT204 (rclone-sync LXC) via systemd timer.
# Source: https://github.com/gaiagent0/homelab-backup-stack
# ============================================================

set -uo pipefail

LOG="/var/log/pbs-rclone-sync.log"
SOURCE="/mnt/pbs-backup"
DEST="${RCLONE_REMOTE:-pcloud:Proxmox/PBS-backup}"
BWLIMIT="${RCLONE_BWLIMIT:-5M}"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] === Sync started ===" >> "$LOG"

# ---- Safety guard: abort if source looks empty ----
SOURCE_COUNT=$(find "$SOURCE" -maxdepth 1 2>/dev/null | wc -l)
if [ "$SOURCE_COUNT" -lt 5 ]; then
    echo "[$DATE] [ERROR] Source appears empty ($SOURCE_COUNT entries at $SOURCE) — bind mount may be down. Aborting." | tee -a "$LOG"
    exit 1
fi
echo "[$DATE] Source check OK ($SOURCE_COUNT entries)" >> "$LOG"

# ---- Run sync ----
rclone sync "$SOURCE" "$DEST" \
    --transfers 2 \
    --checkers 4 \
    --bwlimit "$BWLIMIT" \
    --log-file "$LOG" \
    --log-level INFO \
    --stats 60s \
    --retries 3 \
    --retries-sleep 30s \
    --delete-after

EXIT=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Sync finished, exit code: $EXIT ===" >> "$LOG"

if [ "$EXIT" -ne 0 ]; then
    logger -t pbs-rclone-sync "Sync FAILED with exit code $EXIT — check $LOG"
fi

exit $EXIT
