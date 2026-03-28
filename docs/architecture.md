# README-pbs-rclone-mount-fix
<!-- TARTALOM HIÁNYZIK — másolja be ide a claude.ai projektből -->
# PBS + rclone-sync Mount Probléma és Megoldás

> **Dátum:** 2026-02-27  
> **Érintett node:** pve-02  
> **CT-k:** 201 (pbs-server), 204 (rclone-sync)  
> **Probléma:** Loop mount alapú PBS datastore elérés nem működött → rclone üres forrásból szinkronizált

---

## TL;DR – Gyors összefoglaló

A CT204 (rclone-sync) a PBS adatait loop mount + bind mount kombináción keresztül próbálta elérni. Ez azért nem működött, mert a futó CT201 (PBS) már foglalta a `/dev/loop0` eszközt a saját rootfs-eként — nem lehetett kétszer mountolni. A megoldás: a PBS datastore-t egy **host szintű shared mappába** (`/mnt/pbs-data/`) migráltuk, ahonnan mind CT201, mind CT204 közvetlenül eléri.

---

## 1. Eredeti Architektúra (Hibás)

```
CT201 (PBS)
  rootfs: /dev/loop0 ← vm-201-disk-0.raw
  /var/lib/proxmox-backup/backups/

pve-02 host:
  /dev/loop0 → foglalt, CT201 rootfs!
  /mnt/pbs-datastore ← üres, mount sikertelen

CT204 (rclone-sync):
  /mnt/pbs-backup ← üres (bind mount forrása üres volt)
  → rclone üres forrásból szinkronizált!
```

### Miért nem működött a loop mount?

A CT201 `local` storage típuson tárol (`/var/lib/vz/images/201/vm-201-disk-0.raw`). Amikor a CT201 fut, a Proxmox automatikusan loop device-ra mountolja ezt a raw fájlt a saját rootfs-eként. Ugyanazt a loop device-t (`/dev/loop0`) nem lehet egyidejűleg másodszor is mountolni.

```bash
# Ez volt a tünet:
mount -o ro,noload /dev/loop0 /mnt/pbs-datastore
# mount: /mnt/pbs-datastore: /dev/loop0 already mounted or mount point busy.
# mount warning: loop0: Can't mount, would change RO state
```

---

## 2. A Veszélyes Szituáció

A 2026-02-27 06:34-es automatikus timer futásakor:

```
CT204 bind mount: /mnt/pbs-backup = üres (loop mount nem volt aktív)
rclone sync üres forrás → pcloud:Proxmox/PBS-backup
→ TÖRLÉSI VESZÉLY!
```

A rclone `--delete-after` flag miatt az üres forrásból szinkronizálva **törölhette volna** a pCloud tartalmát (8381 fájl). A `pkill rclone` időben megállította.

**A pCloud tartalma megmaradt: 8381 → 8556 fájl (javítás után)** ✅

---

## 3. Diagnosztika

```bash
# Loop device státusz
losetup -l
# NAME       SIZELIMIT OFFSET AUTOCLEAR RO BACK-FILE
# /dev/loop0         0      0         1  0 /var/lib/vz/images/201/vm-201-disk-0.raw

# Mount ellenőrzés
mount | grep loop0
# (üres - nincs mountolva /mnt/pbs-datastore-ra)

# CT204 bind mount
pct exec 204 -- ls -lh /mnt/pbs-backup
# total 0  ← üres!

# Raw fájl típusa (CT201 leállítva)
file /var/lib/vz/images/201/vm-201-disk-0.raw
# Linux rev 1.0 ext4 filesystem data (direkt ext4, partíció nélkül)
```

---

## 4. Megoldás – Host Shared Mappa

### 4.1 Mappa létrehozás

```bash
mkdir -p /mnt/pbs-data
```

### 4.2 CT201 leállítás és adat kimentés

```bash
pct stop 201
sleep 10

# Loop mount (most már sikerül, CT201 nem fut)
mount -o ro,noload /var/lib/vz/images/201/vm-201-disk-0.raw /mnt/pbs-datastore

# Adat átmásolás host mappába (~11GB, ~30 másodperc)
rsync -av --progress /mnt/pbs-datastore/var/lib/proxmox-backup/backups/ /mnt/pbs-data/

# Ellenőrzés
du -sh /mnt/pbs-data/
# 11G    /mnt/pbs-data/
```

### 4.3 Bind mountok beállítása

```bash
# CT201 bind mount (rw - PBS ír)
pct set 201 -mp0 /mnt/pbs-data,mp=/var/lib/proxmox-backup/backups

# CT204 bind mount (ro - rclone csak olvas)
pct set 204 -mp0 /mnt/pbs-data,mp=/mnt/pbs-backup,ro=1
```

### 4.4 fstab cleanup

```bash
# Régi loop mount bejegyzés kikommentezése (már nem szükséges)
sed -i '/vm-201-disk-0.raw/s/^/#/' /etc/fstab
```

### 4.5 CT201 visszaindítás

```bash
pct start 201
sleep 20

# Ellenőrzés - PBS látja az adatokat?
pct exec 201 -- ls -lh /var/lib/proxmox-backup/backups/
pct exec 201 -- proxmox-backup-manager datastore list
```

### 4.6 CT204 indítás és sync

```bash
pct start 204
sleep 15

# Bind mount él?
pct exec 204 -- ls -lh /mnt/pbs-backup/ | head -5

# Éles sync
pct exec 204 -- /usr/local/bin/pbs-backup-sync.sh
```

---

## 5. Új Architektúra (Működő)

```
pve-02 host:
  /mnt/pbs-data/           ← fizikai host mappa (91GB szabad)
       │
       ├─── bind mount (rw) ──→ CT201 PBS
       │                        /var/lib/proxmox-backup/backups/
       │                        → PBS ír/olvas
       │
       └─── bind mount (ro) ──→ CT204 rclone-sync
                                /mnt/pbs-backup/
                                → rclone olvas, pCloudba tölt

CT201 rootfs:
  /dev/loop0 → vm-201-disk-0.raw (saját rootfs, érintetlen)
```

### Adatfolyam

```
PVE VM-ek/LXC-k
    ↓ backup job
CT201 PBS → /var/lib/proxmox-backup/backups/ (= /mnt/pbs-data host-on)
    ↓ bind mount (ro)
CT204 rclone-sync → /mnt/pbs-backup/
    ↓ napi 02:00 systemd timer
pCloud: Proxmox/PBS-backup/
```

---

## 6. Miért Jobb Ez?

| Szempont | Régi (loop mount) | Új (host mappa) |
|----------|-------------------|-----------------|
| CT201 fut közben | ❌ Loop foglalt | ✅ Bind mount működik |
| Reboot utáni stabilitás | ❌ Loop mount timing | ✅ Automatikus |
| Komplexitás | ❌ Loop + offset + noload | ✅ Egyszerű directory |
| Adat biztonság | ⚠️ Üres sync veszély | ✅ Mindig él a mount |

---

## 7. Ellenőrző Parancsok

### pve-02 hoston

```bash
# Host mappa méret
du -sh /mnt/pbs-data/

# CT201 bind mount él?
pct exec 201 -- df -h /var/lib/proxmox-backup/backups/

# CT204 bind mount él?
pct exec 204 -- ls -lh /mnt/pbs-backup/ | head -5

# PBS datastore státusz
pct exec 201 -- proxmox-backup-manager datastore list

# Legutóbbi sync log
pct exec 204 -- tail -20 /var/log/pbs-rclone-sync.log

# Timer státusz
pct exec 204 -- systemctl list-timers pbs-rclone-sync*

# pCloud fájlszám
pct exec 204 -- rclone ls pcloud:Proxmox/PBS-backup | wc -l
```

---

## 8. Reboot Utáni Viselkedés

A `/mnt/pbs-data/` host szintű fizikai mappa — **nem törlődik reboot után**.

A bind mountok a CT-k indításakor automatikusan aktiválódnak (a CT konfigban tárolódnak):

```bash
# CT201 config ellenőrzés
pct config 201 | grep mp0
# mp0: /mnt/pbs-data,mp=/var/lib/proxmox-backup/backups

# CT204 config ellenőrzés
pct config 204 | grep mp0
# mp0: /mnt/pbs-data,mp=/mnt/pbs-backup,ro=1
```

**Nincs szükség fstab bejegyzésre** — a Proxmox maga kezeli a bind mountokat CT indításkor.

---

## 9. Ismert Problémák és Megoldásaik

| Probléma | Ok | Megoldás |
|----------|----|----------|
| `/mnt/pbs-backup` üres CT204-ben | Host mappa nem létezik | `mkdir -p /mnt/pbs-data` majd `pct restart 204` |
| CT204 nem indul (`mp0 error`) | `/mnt/pbs-data` hiányzik | Mappa létrehozás: `mkdir -p /mnt/pbs-data` |
| PBS nem ír (`permission denied`) | Jogosultság probléma | `chown -R 100034:100034 /mnt/pbs-data` |
| rclone üres forrásból szinkronizál | CT204 nem fut / bind mount üres | `pct exec 204 -- ls /mnt/pbs-backup` ellenőrzés |
| pCloud törlési veszély | `--delete-after` flag üres forrással | `pkill -f rclone` azonnal! |

---

## 10. Sync Eredmények

| Időpont | Esemény | pCloud fájlszám |
|---------|---------|-----------------|
| 2026-02-25 02:04 | Első sikeres sync (régi architektúra) | 8381 |
| 2026-02-27 06:34 | Üres sync (loop mount nem aktív) | 8381 (pkill megmentette) |
| 2026-02-27 07:18 | Javítás utáni első éles sync | 8556 (+175 fájl) |

---

*Dokumentálva: 2026-02-27 | homelab pve-02 | PBS loop mount → host shared mappa migráció*
