#!/bin/bash
# ============================================================
# setup-rclone-timer.sh
# Installs the pbs-rclone-sync systemd service + timer into CT204.
# Run on the Proxmox HOST (pve-02) as root.
#
# Usage: bash scripts/setup-rclone-timer.sh
# Source: https://github.com/gaiagent0/homelab-backup-stack
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../configs/env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: configs/env not found. Copy configs/env.example to configs/env and edit."
    exit 1
fi
source "$ENV_FILE"

RCLONE_CT_ID=${RCLONE_CT_ID:-204}
SYNC_TIME=${SYNC_TIME:-"*-*-* 02:00:00"}
RCLONE_REMOTE=${RCLONE_REMOTE:-pcloud:Proxmox/PBS-backup}
RCLONE_BWLIMIT=${RCLONE_BWLIMIT:-5M}

SCRIPT_DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR_REPO}/../templates/systemd"
SYNC_SCRIPT="${SCRIPT_DIR_REPO}/pbs-backup-sync.sh"

echo "[1/5] Copying pbs-backup-sync.sh to CT${RCLONE_CT_ID}..."
pct push "$RCLONE_CT_ID" "$SYNC_SCRIPT" /usr/local/bin/pbs-backup-sync.sh
pct exec "$RCLONE_CT_ID" -- chmod +x /usr/local/bin/pbs-backup-sync.sh
echo "      OK: /usr/local/bin/pbs-backup-sync.sh"

echo "[2/5] Injecting environment variables into CT${RCLONE_CT_ID}..."
pct exec "$RCLONE_CT_ID" -- bash -c "cat > /etc/pbs-rclone-sync.env <<EOF
RCLONE_REMOTE=${RCLONE_REMOTE}
RCLONE_BWLIMIT=${RCLONE_BWLIMIT}
EOF"
pct exec "$RCLONE_CT_ID" -- chmod 600 /etc/pbs-rclone-sync.env
echo "      OK: /etc/pbs-rclone-sync.env"

echo "[3/5] Installing systemd service into CT${RCLONE_CT_ID}..."
pct push "$RCLONE_CT_ID" "${TEMPLATE_DIR}/pbs-rclone-sync.service" /etc/systemd/system/pbs-rclone-sync.service
echo "      OK: /etc/systemd/system/pbs-rclone-sync.service"

echo "[4/5] Installing systemd timer into CT${RCLONE_CT_ID} (schedule: ${SYNC_TIME})..."
# Inject the actual schedule into the timer file
pct exec "$RCLONE_CT_ID" -- bash -c "cat > /etc/systemd/system/pbs-rclone-sync.timer <<EOF
[Unit]
Description=PBS rclone offsite sync timer
Requires=pbs-rclone-sync.service

[Timer]
OnCalendar=${SYNC_TIME}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF"
echo "      OK: /etc/systemd/system/pbs-rclone-sync.timer"

echo "[5/5] Enabling and starting timer in CT${RCLONE_CT_ID}..."
pct exec "$RCLONE_CT_ID" -- systemctl daemon-reload
pct exec "$RCLONE_CT_ID" -- systemctl enable pbs-rclone-sync.timer
pct exec "$RCLONE_CT_ID" -- systemctl start pbs-rclone-sync.timer
echo "      OK: timer enabled and started"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Verify:"
echo "  pct exec ${RCLONE_CT_ID} -- systemctl list-timers pbs-rclone-sync*"
echo "  pct exec ${RCLONE_CT_ID} -- systemctl status pbs-rclone-sync.timer"
echo ""
echo "Test sync manually (dry-run first):"
echo "  pct exec ${RCLONE_CT_ID} -- rclone ls /mnt/pbs-backup | head -5"
echo "  pct exec ${RCLONE_CT_ID} -- systemctl start pbs-rclone-sync.service"
echo "  pct exec ${RCLONE_CT_ID} -- tail -f /var/log/pbs-rclone-sync.log"
