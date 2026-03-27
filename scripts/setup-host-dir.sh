#!/bin/bash
# Creates the PBS backing host directory with correct ownership.
# Run on the Proxmox HOST (pve-02), not inside a CT.
# Usage: bash scripts/setup-host-dir.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../configs/env" 2>/dev/null || true

PBS_HOST_DIR=${PBS_HOST_DIR:-/mnt/pbs-store}
PBS_PBS_UID=${PBS_PBS_UID:-100034}

mkdir -p "$PBS_HOST_DIR"
chown -R "${PBS_PBS_UID}:${PBS_PBS_UID}" "$PBS_HOST_DIR"
echo "[OK] $PBS_HOST_DIR created, ownership: ${PBS_PBS_UID}:${PBS_PBS_UID}"
