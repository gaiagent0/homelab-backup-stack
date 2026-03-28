# README-pbs-rclone-backup
<!-- TARTALOM HIÁNYZIK — másolja be ide a claude.ai projektből -->
# PBS + rclone-sync Backup Stratégia – Homelab

> **Dátum:** 2026-02-26  
> **Érintett node:** pve-02  
> **CT-k:** 201 (pbs-server), 204 (rclone-sync)  
> **Felhő:** pCloud EU (eapi.pcloud.com)

---

## TL;DR – Gyors összefoglaló

A homelab backup stratégia két rétegből áll: **PBS** (Proxmox Backup Server) lokálisan tárolja a VM/LXC snapshotokat deduplikálva, az **rclone-sync** LXC pedig napi egyszer feltölti a PBS datastoreot pCloudba. A teljes pipeline automatikus, napi 02:00-kor fut.

```
PVE VM-ek/LXC-k → PBS (CT201, 10.10.40.14) → rclone-sync (CT204) → pCloud
                   lokális backup             napi sync             felhő offsite
```

---

## 1. Architektúra

| Komponens | CT ID | IP | Node | Szerepkör |
|-----------|-------|----|------|-----------|
| PBS Server | 201 | 10.10.40.14/24 | pve-02 | Lokális backup tárolás + deduplikáció |
| rclone-sync | 204 | 10.10.40.204/24 | pve-02 | pCloud feltöltés |

### Adatfolyam

```
CT201 (PBS)
  └─ /var/lib/proxmox-backup/backups/   ← PBS datastore (lokális, ~6 GB)
       │
       │  loop mount (pve-02 hoston)
       ▼
  /mnt/pbs-datastore/var/lib/proxmox-backup/backups/
       │
       │  bind mount (read-only)
       ▼
CT204 (rclone-sync)
  └─ /mnt/pbs-backup/                   ← read-only nézet a PBS datastoreba
       │
       │  rclone sync (napi 02:00)
       ▼
  pCloud: Proxmox/PBS-backup/           ← offsite felhő backup
```

---

## 2. PBS Konfiguráció (CT201)

### Datastore

```
Név:   local
Path:  /var/lib/proxmox-backup/backups
```

### Retention Policy

```
keep-last:    2
keep-daily:   7
keep-weekly:  4
keep-monthly: 3
keep-yearly:  0
```

### Prune Job

```bash
# Manuális futtatás:
proxmox-backup-manager prune-job run default-backups-d461461b-5cd8-4a

# Prune job listázás:
proxmox-backup-manager prune-job list
```

### Garbage Collection

```bash
# GC futtatása (prune után kötelező a hely felszabadításához):
proxmox-backup-manager garbage-collection start local

# Méret ellenőrzés:
du -sh /var/lib/proxmox-backup/backups/
```

### Backup statisztikák

| Metrika | Érték |
|---------|-------|
| On-Disk méret | ~5.9 GB |
| Eredeti adatméret | ~129 GB |
| Deduplikációs faktor | 23x |
| Átlagos chunk méret | 1.17 MiB |

---

## 3. Loop Mount + Bind Mount (pve-02 host)

A CT204-nek read-only hozzáférésre van szüksége a PBS datastorehoz. Mivel a CT201 raw disk image-t használ (`vm-201-disk-0.raw`), loop mounton keresztül érhető el.

### Loop Mount (pve-02-n)

```bash
# Kézi mount (ha nem aktív):
losetup -r /dev/loop5 /var/lib/vz/images/201/vm-201-disk-0.raw
mount -o ro,noload /dev/loop5 /mnt/pbs-datastore

# Ellenőrzés:
ls /mnt/pbs-datastore/var/lib/proxmox-backup/backups/
```

### /etc/fstab bejegyzés (perzisztencia)

```
/var/lib/vz/images/201/vm-201-disk-0.raw /mnt/pbs-datastore ext4 loop,ro,noload,nofail 0 0
```

### CT204 Bind Mount

```bash
# Beállítás (egyszeri, már konfigurálva):
pct set 204 -mp0 /mnt/pbs-datastore/var/lib/proxmox-backup/backups,mp=/mnt/pbs-backup,ro=1
```

### CT204 pct config releváns sorai

```
net0: name=eth0,bridge=vmbr0,tag=40,ip=10.10.40.204/24,gw=10.10.40.1,type=veth
mp0: /mnt/pbs-datastore/var/lib/proxmox-backup/backups,mp=/mnt/pbs-backup,ro=1
```

---

## 4. rclone Konfiguráció (CT204)

### pCloud Remote

```ini
[pcloud]
type = pcloud
token = {"access_token":"...","token_type":"bearer","expiry":"0001-01-01T00:00:00Z"}
hostname = eapi.pcloud.com
```

> **Megjegyzés:** Az `expiry: 0001-01-01` normális pCloud bearer tokennél – nem jár le.

### DNS Beállítás

A CT204-ben a DNS `8.8.8.8`-ra van állítva (a MikroTik DNS nem oldja fel az `eapi.pcloud.com`-ot):

```bash
cat /etc/resolv.conf
# nameserver 8.8.8.8
# nameserver 1.1.1.1
```

Perzisztens beállítás pve-02-n:
```bash
pct set 204 --nameserver "8.8.8.8 1.1.1.1"
```

### pCloud tárhelyzet

| Metrika | Érték |
|---------|-------|
| Teljes tárhely | 500 GB |
| Foglalt (összes) | ~265 GB |
| PBS backup mappa | Proxmox/PBS-backup/ |
| Szabad (becsült) | ~235 GB |

---

## 5. rclone Sync Script

**Helye:** `/usr/local/bin/pbs-backup-sync.sh` (CT204-ben)

```bash
#!/bin/bash

LOG="/var/log/pbs-rclone-sync.log"
SOURCE="/mnt/pbs-backup"
DEST="pcloud:Proxmox/PBS-backup"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] Sync started" >> "$LOG"

rclone sync "$SOURCE" "$DEST" \
  --transfers 2 \
  --checkers 4 \
  --bwlimit 5M \
  --log-file "$LOG" \
  --log-level INFO \
  --stats 60s \
  --retries 3 \
  --retries-sleep 30s

EXIT=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync finished, exit code: $EXIT" >> "$LOG"
```

### Paraméterek magyarázata

| Paraméter | Érték | Leírás |
|-----------|-------|--------|
| `--transfers` | 2 | Párhuzamos feltöltések száma |
| `--checkers` | 4 | Párhuzamos fájlellenőrzők |
| `--bwlimit` | 5M | Sávszélesség limit (5 MB/s) |
| `--retries` | 3 | Újrapróbálkozás hibánál |
| `--log-level` | INFO | Log részletesség |

---

## 6. Systemd Timer (CT204)

### Service fájl

```ini
# /etc/systemd/system/pbs-rclone-sync.service
[Unit]
Description=PBS rclone sync to pCloud
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pbs-backup-sync.sh
```

### Timer fájl

```ini
# /etc/systemd/system/pbs-rclone-sync.timer
[Unit]
Description=PBS rclone sync timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Timer kezelés

```bash
# Állapot ellenőrzés:
systemctl list-timers pbs-rclone-sync*
systemctl status pbs-rclone-sync.timer

# Manuális futtatás (teszt):
systemctl start pbs-rclone-sync.service

# Log figyelés:
tail -f /var/log/pbs-rclone-sync.log
```

---

## 7. Ellenőrző Parancsok

### PBS státusz

```bash
# CT201-ben:
proxmox-backup-manager datastore list
du -sh /var/lib/proxmox-backup/backups/
proxmox-backup-manager prune-job list
```

### rclone státusz

```bash
# CT204-ben:
rclone about pcloud: 2>&1
rclone size pcloud:Proxmox/PBS-backup 2>&1
tail -20 /var/log/pbs-rclone-sync.log
```

### Loop mount ellenőrzés (pve-02-n)

```bash
losetup -l
mount | grep pbs-datastore
ls /mnt/pbs-datastore/var/lib/proxmox-backup/backups/
```

### Bind mount ellenőrzés (CT204-ben)

```bash
ls /mnt/pbs-backup
df -h /mnt/pbs-backup
```

---

## 8. Reboot Utáni Helyreállítás

Ha pve-02 reboot után a loop mount vagy bind mount nem jön vissza automatikusan:

```bash
# pve-02-n – loop mount kézi visszaállítás:
losetup -r /dev/loop5 /var/lib/vz/images/201/vm-201-disk-0.raw
mount -o ro,noload /dev/loop5 /mnt/pbs-datastore

# CT204 újraindítás (bind mountot automatikusan betölti):
pct restart 204

# Ellenőrzés CT204-ben:
pct enter 204
ls /mnt/pbs-backup
```

> **Megjegyzés:** Az fstab bejegyzés gondoskodik az automatikus loop mountról reboot után. Ha mégsem működne, a fenti kézi parancsok segítenek.

---

## 9. pCloud Token Megújítás

Ha az rclone elveszíti a pCloud kapcsolatot:

```bash
# CT204-ben:
rclone config reconnect pcloud:
# → y (refresh)
# → n (headless gép)
# Kimásolja a parancsot → Windows gépen futtatni:
# .\rclone.exe authorize "pcloud" "<token>"
# → Visszamásolni az eredményt CT204-be
```

---

## 10. Ismert Problémák és Megoldásaik

| Probléma | Ok | Megoldás |
|----------|----|----------|
| `rclone: Could not resolve eapi.pcloud.com` | MikroTik DNS nem oldja fel | `echo "nameserver 8.8.8.8" > /etc/resolv.conf` |
| Loop mount sikertelen reboot után | fstab timing | Kézi `losetup + mount` parancs |
| PBS prune `no such datastore 'backups'` | Hibás datastore név a prune jobban | `prune-job update ... --store local` |
| CT204 nem indul (mp0 hiba) | Loop mount még nem aktív | Előbb loop mount, utána `pct start 204` |
| pCloud `expiry: 0001-01-01` | pCloud bearer token sajátossága | Normális, nem jelent problémát |
| `pvesm set pbs-server --server` sikertelen | Fixált paraméter | Direktben szerkeszteni: `nano /etc/pve/storage.cfg` |

---

*Dokumentálva: 2026-02-26 | homelab pve-02 | PBS + rclone pCloud offsite backup*
