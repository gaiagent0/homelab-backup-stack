# Disaster Recovery — Full Restore from pCloud

> Step-by-step procedure to recover the Proxmox homelab backup chain from pCloud offsite storage. Use this when both the local PBS datastore and the host directory (`/mnt/pbs-data`) are lost.

---

## Recovery Scenarios

| Scenario | Recovery path |
|---|---|
| PBS LXC (CT201) corrupted, host data intact | Recreate CT201, re-attach bind-mount |
| Host data (`/mnt/pbs-data`) lost, rclone LXC intact | Download from pCloud → restore host dir |
| Full pve-02 failure, new hardware | Full restore: new PVE install → download from pCloud → recreate CTs |
| Accidental rclone `sync` with empty source | Check pCloud trash/versioning; restore from there |

---

## Prerequisites

- A running Proxmox VE 8.x node (pve-02 or replacement)
- Access to CT204 (rclone-sync) or ability to create a new LXC with rclone
- pCloud credentials (token in `/root/.rclone.conf` — stored in CT204)
- At least `~15 GB` free disk space for the PBS datastore restore

---

## Full Restore Procedure

### Step 1 — Prepare the host directory

```bash
# On pve-02 host:
mkdir -p /mnt/pbs-data
# Adjust storage if needed (e.g. ZFS dataset):
# zfs create rpool/pbs-data && zfs set mountpoint=/mnt/pbs-data rpool/pbs-data
```

### Step 2 — Create a temporary rclone LXC (if CT204 is lost)

```bash
# Create a minimal Debian 12 LXC for rclone download:
pct create 299 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname rclone-restore \
  --memory 512 --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --storage local-zfs --rootfs local-zfs:8 \
  --unprivileged 1 --onboot 0

pct start 299
pct exec 299 -- bash -c "curl https://rclone.org/install.sh | bash"
```

Copy the rclone config from backup (if available), or re-authorize:

```bash
pct push 299 /path/to/.rclone.conf /root/.rclone.conf
# Or: pct exec 299 -- rclone config  (re-authorize manually)
```

### Step 3 — Download from pCloud

```bash
# Bind-mount the restore target into the LXC:
pct set 299 -mp0 /mnt/pbs-data,mp=/mnt/restore

pct exec 299 -- bash -c "
  rclone sync pcloud:Proxmox/PBS-backup /mnt/restore \
    --transfers 4 \
    --checkers 8 \
    --bwlimit 50M \
    --progress \
    --log-level INFO \
    --retries 5 \
    --retries-sleep 30s
"
```

Download time estimate: ~6 GB at 5 MB/s ≈ ~20 minutes. Adjust `--bwlimit` based on your connection.

### Step 4 — Verify downloaded data

```bash
# On host:
ls -lh /mnt/pbs-data/
du -sh /mnt/pbs-data/
# Expected: namespace dirs, datastore.cfg, chunks/

# Count backup chunks (should match pCloud count):
find /mnt/pbs-data -name "*.fidx" -o -name "*.didx" | wc -l
```

### Step 5 — Recreate PBS LXC (CT201)

```bash
# Create PBS LXC from template:
pct create 201 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname pbs-server \
  --memory 1024 --cores 2 \
  --net0 name=eth0,bridge=vmbr0,tag=40,ip=10.10.40.14/24,gw=10.10.40.1 \
  --storage local-zfs --rootfs local-zfs:32 \
  --unprivileged 1 --onboot 1 --startup order=10,up=30

# Set the bind-mount:
pct set 201 -mp0 /mnt/pbs-data,mp=/var/lib/proxmox-backup/backups

pct start 201

# Install PBS inside CT201:
pct exec 201 -- bash -c "
  echo 'deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription' \
    > /etc/apt/sources.list.d/pbs.list
  wget -q https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
    -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
  apt-get update -q
  apt-get install -y proxmox-backup-server
"
```

### Step 6 — Verify PBS sees the restored datastore

```bash
pct exec 201 -- proxmox-backup-manager datastore list
# Expected: local datastore with the restored backups

pct exec 201 -- proxmox-backup-manager datastore show local
# Should show chunk count, dedup factor, used space

# List available backup snapshots:
pct exec 201 -- proxmox-backup-client snapshot list --repository 10.10.40.14:local
```

### Step 7 — Restore a VM/LXC backup

```bash
# From any PVE node, restore via PBS:
# PVE UI → Backup → Restore (select PBS datastore)
# Or CLI:
qmrestore 'pbs:backup/vm/101/2026-03-01T02:00:00Z' 101 --storage local-zfs
```

---

## Accidental pCloud Overwrite Recovery

If rclone synced an empty source to pCloud and deleted files:

1. Check pCloud trash (web UI → Trash) — pCloud keeps deleted files for 30 days (Free) or 180 days (Premium)
2. Restore from trash via pCloud web UI or `rclone` with `--backup-dir` if configured

To prevent this scenario, the `pbs-backup-sync.sh` script includes a source-count guard:

```bash
SOURCE_COUNT=$(find "$SOURCE" -maxdepth 1 | wc -l)
if [ "$SOURCE_COUNT" -lt 5 ]; then
    echo "[ERROR] Source appears empty — aborting sync!"
    exit 1
fi
```

---

## Cleanup (after restore)

```bash
# Stop and destroy the temporary restore LXC:
pct stop 299
pct destroy 299

# Recreate CT204 (rclone-sync) with the same config as before:
# See README.md Quick Start section
```

---

*Tested recovery scenario: pve-02 disk replaced, full restore from pCloud in ~45 minutes (6 GB datastore, 50 Mbps connection)*
