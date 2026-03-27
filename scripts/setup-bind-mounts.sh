#!/bin/bash
# Configures bind mounts for CT201 (RW) and CT204 (RO).
# Run on the Proxmox HOST (pve-02).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../configs/env" 2>/dev/null || true

PBS_HOST_DIR=${PBS_HOST_DIR:-/mnt/pbs-store}
PBS_CT_ID=${PBS_CT_ID:-201}
RCLONE_CT_ID=${RCLONE_CT_ID:-204}

echo "Setting up bind mounts..."
pct set "$PBS_CT_ID"    -mp0 "${PBS_HOST_DIR},mp=/var/lib/proxmox-backup/backups"
pct set "$RCLONE_CT_ID" -mp0 "${PBS_HOST_DIR},mp=/mnt/pbs-backup,ro=1"
echo "[OK] CT${PBS_CT_ID}: ${PBS_HOST_DIR} → /var/lib/proxmox-backup/backups (RW)"
echo "[OK] CT${RCLONE_CT_ID}: ${PBS_HOST_DIR} → /mnt/pbs-backup (RO)"
echo ""
echo "Restart both CTs to activate mounts:"
echo "  pct restart ${PBS_CT_ID}"
echo "  pct restart ${RCLONE_CT_ID}"
