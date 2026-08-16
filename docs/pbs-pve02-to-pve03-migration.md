# PBS/rclone migráció pve-02 → pve-03 (és pve-02 takarítás)

*Dokumentálva: 2026-08-16 — valós, automatizált cron-futtatás alapján (4. kísérletre sikerrel).*

> **TL;DR:** A CT201 (`pbs-server`) és CT204 (`rclone-sync`) LXC-ket a pve-02 node-ról átköltöztettük
> pve-03-ra. A három korábbi kísérlet mind elbukott egy-egy Proxmox sajátosságon — ezeket a
> buktatókat dokumentáljuk, hogy legközelebb ne ismétlődjenek. Utána pve-02-n töröltük a
> redundáns 84 GB PBS másolatot (root 84% → 4%) és bekapcsoltuk a `local-zfs` storage-t új
> konténereknek. A 3-2-1 pipeline él: **helyi PBS pve-03-on + offsite pCloud**; a pve-02 második
> helyi másolat megszűnt (lokális redundancia 2→1).

---

## 1. Cél és előzmény

A `homelab-backup-stack` PBS + rclone CT-i eredetileg pve-02-n futottak. A cél: a backup-pipeline
áthelyezése pve-03-ra, hogy pve-02 üres quorum/standby node legyen (új workload befogadására).

**Előfeltétel (prep lépés, már megelőzően megvolt):** a pve-02 `/mnt/pbs-store` (82 GB PBS adat)
rsync-kel át lett másolva pve-03 `/mnt/pbs-store`-be (pve-03 `rpool/pbs-store` ZFS dataset), és az
apparmor szabályok (`/etc/apparmor.d/lxc/lxc-default-cgns`) a pbs-store bind-mountra be lettek
állítva. A "final step" script ezt feltételezi.

**Topológia után:**
```
pve-03 (10.10.40.13):  CT201 pbs-server  (10.10.40.14)  ← PBS datastore host /mnt/pbs-store
                        CT204 rclone-sync (10.10.40.204)  ← RO bind /mnt/pbs-backup
pve-02 (10.10.40.12):  üres cluster-node, quorum/standby, ~105 GB szabad lemez, local-zfs engedélyezve
```

---

## 2. A final-step script és a 3 buktató

A migrációt egy fej nélküli script hajtotta végre (`run-pbs-migrate-cron.sh` laptopról SSH-zik
pve-03-ra, ahol `/root/pbs-migrate-final.sh` fut). A script 4x futott, az első 3 elbukott:

| # | Idő (CEST) | Hiba | Ok |
|---|---|---|---|
| 1 | 02:04 | `400 Parameter verification failed. target: invalid format - value does not look like a valid node name` | `pct migrate` célja IP (`10.10.40.13`) volt — **node nevet** vár |
| 2 | 07:45 | `400 Parameter verification failed. target: target is local node.` | a migrate parancsot **pve-03-ról, lokálisan** adtuk ki, de a CT-k pve-02-n vannak (az a forrás) |
| 3 | 07:50 | `cannot migrate local bind mount point 'mp0'` | `pct migrate` nem viszi át a host **bind mount**-ot (`mp0`) |
| 4 | 07:50→08:09 | ✅ siker | a 3 javítás együtt |

### 2.1 Bug 1 — `pct migrate` IP helyett node nevet vár

`pct migrate <vmid> <target>` a `<target>` paraméterben **node nevet** (`pve-03`) vár, nem IP-címet.
IP átadásakor: `target: invalid format - value does not look like a valid node name`.

**Javítás:** a script tetején `PVE03=10.10.40.13` → `PVE03=pve-03`.

### 2.2 Bug 2 — a migrate parancsot a FORRÁS node-ról kell kiadni

A `pct migrate`-et a **forrás node** (ahol a CT konfigurációja él) shelljéből kell futtatni, célként
a célnode nevével. Mivel a CT-k pve-02-n voltak, a migrate parancsot pve-02-ről kell SSH-vel kiadni —
nem pve-03-ról "helyben". Helyben kiadva: `target is local node.` (pve-03 magára akarta migrálni).

**Javítás:** a migrate hívások átírása SSH-re pve-02 felé:
```bash
# rossz (pve-03-on lokálisan):
pct migrate 201 $PVE03 --online 0 <<<"y"
# jo (pve-02-rol ssh, cel = pve-03 node nev):
ssh -o BatchMode=yes root@$PVE02 'pct migrate 201 pve-03 --online 0' <<<"y"
```

### 2.3 Bug 3 — bind mount (`mp0`) nem migrálható offline sem

A `pct migrate` (még offline/`--online 0` módban is) megtagadja a host **bind mount** (`mp0`)
áthozatalát: `cannot migrate local bind mount point 'mp0'`. A PBS datastore (`/var/lib/proxmox-backup/backups`)
és a rclone RO mount (`/mnt/pbs-backup`) pont ilyen bind mount.

**Javítás — a bevált kerülő:** a migrate ELŐTT le kell venni `mp0`-t a forrás CT konfigjáról, migrálni,
majd a CÉL node-on (ahol az rsync-elt adat már ott van a host `/mnt/pbs-store`-ban) visszaadni:
```bash
# migrate elott (pve-02):
ssh -o BatchMode=yes root@$PVE02 'pct set 201 -delete mp0; pct set 204 -delete mp0'
# migrate utan (pve-03):
pct set 201 -mp0 /mnt/pbs-store,mp=/var/lib/proxmox-backup/backups
pct set 204 -mp0 /mnt/pbs-store,mp=/mnt/pbs-backup,ro=1
```
> A datastore kötet NEM a CT diszkén van, hanem a host `/mnt/pbs-store`-ban (rsync-kel már pve-03-on)
> — ezért a bind mount nélkül is ép marad az adat, csak a konfig "mutatóját" kell átrakni.

### 2.4 A végleges, működő script

Lásd `scripts/pbs-pve02-to-pve03-migrate.sh` — a 3 javítással ellátott változat. Főbb lépései:
0. sanity (hostname == pve-03), swappiness 60→10
1. várakozás a háttér rsync-re (max 90 perc)
2. `/mnt/pbs-store` mount + apparmor szabály ellenőrzése pve-03-on
3. CT201/CT204 leállítása pve-02-n
4. **mp0 levétele** pve-02-n
5. végső rsync delta (0 byte volt — az adat már megvolt)
6. CT201, majd CT204 migrate **pve-02-ről ssh**, cél `pve-03`
7. **mp0 visszaadása** pve-03-on
8. CT indítás + PBS datastore / `pvesm status` ellenőrzés
9. eredetik eltávolítása pve-02-ről (`pct destroy --purge` — migrate után már nincs conf, WARN a várt)
10. backup jobok átütemezése 02:00/03:00/04:00, rclone cron 05:00

---

## 3. Eredmény és verifikáció (4. futtatás, 2026-08-16 07:50→08:09)

```
=== migrate CT201 -> pve-03 ===
... successfully imported 'local:201/vm-201-disk-0.raw'
migration finished successfully (duration 00:16:39)     # 100G rootfs ~108 MB/s
=== migrate CT204 -> pve-03 ===
migration finished successfully (duration 00:00:43)      # 4G rootfs
=== re-add mp0 bind-mount on pve-03 ===   (sikeres, hiba nelkul)
=== verify CT201 PBS datastore ===
name: local | path: /var/lib/proxmox-backup/backups
=== pvesm status pbs-server ===
pbs-server   pbs   active   1081879040   87308160   994570880   8.07%
=== reschedule backup jobs === 02:00 / 03:00 / 04:00
=== reschedule rclone cron === 0 5 * * *
=== MIGRATION + RESCHEDULE COMPLETE ===   EXIT=0
```

**Ellenőrző parancsok (read-only, a migráció után):**
```bash
# pve-03: CT-k futnak?
pct list            # 201 pbs-server running, 204 rclone-sync running
pct config 201 | grep -E '^mp0|^net0'   # mp0 visszaadva; IP=10.10.40.14 (megmaradt!)
pct config 204 | grep -E '^mp0|^net0'   # mp0 ro=1; IP=10.10.40.204 (megmaradt!)
# pve-02: ures?
pct list            # (ures)
# cluster-wide PBS storage
pvesm status | grep pbs-server   # server 10.10.40.14, active 8.07%
```

**Fontos:** a CT IP-címek (`10.10.40.14`, `10.10.40.204`) **megmaradtak** a migráció során, így a
`pbs-server` storage (cluster-wide, `server 10.10.40.14`) és a kliens/konfigok nem törtek meg.

---

## 4. pve-02 takarítás (redundáns PBS másolat törlése)

A migráció után pve-02 gyökérlemeze **84%-on** volt — ezt a régi, már nem használt PBS másolat töltötte.

```bash
# pve-02-n:
rm -rf /mnt/pbs-store                              # 84 GB redundans PBS masolat (TOROLVE)
zfs destroy rpool/pbs-store                         # 3.61 GB elarvult dataset (/mnt/pbs-store-new)
rmdir /mnt/pbs-store-new                            # ures mountpont eltavolitva
```
**Eredmény:** root `84% → 4%` (88G → 4G használt, **105G szabad**). `zfs list` nem mutat `pbs-store`-t.

### 4.1 Storage engedélyezése új konténereknek
```bash
pvesm set local-zfs --disable 0                     # rpool/data ZFS bekapcsolasa
pvesh set /storage/local-zfs --nodes pve-01,pve-03,pve-02
```
- `local-zfs` (`rpool/data`): ✅ aktív, **109 GB szabad** → ide tedd az új CT-k rootfs-ét
- `tank`: ⚠️ **nem engedélyezhető** — a mögöttes `tank` ZFS pool **nem létezik pve-02-n** (csak pve-01
  scope-ban van). Bekapcsolni hibát dobott volna; létrehozni külön `zpool create` kell, ha kell.
- `local` (dir): maradt, de csak ~18 GB → ne ide tedd a CT-ket.
- **`/root/pve-watchdog.sh` érintetlenül hagyva** (cluster quorum őr, 5 percenként).

---

## 5. 3-2-1 trade-off (figyelem!)

A migráció előtt: PBS adat 2 helyi példányban (pve-02 élő + a pve-03 rsync másolat) + pCloud offsite.
A pve-02 másolat törlésével a **lokális redundancia 2→1-re csökkent**:

| Réteg | Migráció előtt | Migráció után |
|---|---|---|
| Helyi PBS (pve-03) | ✅ | ✅ |
| 2. helyi másolat (pve-02) | ✅ | ❌ törölve |
| Offsite pCloud | ✅ | ✅ |

Ez 3-2-1 szempontból még mindig elfogadható (1 helyi + 1 offsite + a PVE node-ok maguk), de a
*pure local* másodpéldány elveszett. Ha pve-03 PBS-meghibásodik, csak a pCloud marad — a restore
onnan lassabb. Ha kritikus, érdemes egy újabb helyi PBS replikát létrehozni (PBS sync job), de ez
nem része ennek a migrálásnak.

---

## 6. Ismert hiányosságok / TODO

- **Elmaradt hajnali mentés (2026-08-16):** a PBS (CT201) a migráció miatt **02:04–08:09** között
  állt, így a 02:00/03:00/04:00 backup ablak **nem futott le**. A legutolsó ép mentések:
  `101/105/106/107/204` → 2026-08-16 00:30, a többi CT → 2026-08-15 hajnal. Adatvesztés NINCS
  (régi snapshotok épek); a következő (ma esti) ablak pótol. Szükség esetén indíts manuális
  teljes mentést.
- **Retention:** a live `prune-all` még `keep-last=3` (a README célértéke `keep-last=2 + keep-monthly=1`).
  Szigorítás még nem történt meg — lásd `docs/pbs-retention.md`.
- **`rclone sync --delete-after`:** a CT204 cron továbbra is tükröző (`--delete-after`) módban fut
  (05:00). A skill javaslata szerint érdemes `rclone copy`-ra váltani a független 3-2-1 archívumhoz —
  még nincs megvalósítva.

---

## 7. Ellenőrző parancsok (összefoglaló)

```bash
# PBS datastore snapshot darab (pve-03 CT201-ben):
pct exec 201 -- proxmox-backup-manager snapshot list 2>/dev/null | wc -l
# vagy host-oldalrol a datastore konyvtarbol az utolso snapshot idok:
ls /mnt/pbs-store/ct/*/   # a snapshot dir neve tartalmazza a mentes idejet

# pve-02 maradek (üresnek kell lennie):
pct list; qm list; zfs list | grep pbs-store || echo "nincs pbs-store"

# lemez terfoglaltsag pve-02:
df -h /

# uj CT letrehozasa pve-02 local-zfs-re (nem a local-ba):
pct create <ID> local:vztmpl/... --storage local-zfs ...
```

*Kapcsolódó: `docs/pbs-ct-reinstall-runbook.md`, `docs/architecture.md`, `docs/pbs-retention.md`,
`scripts/pbs-pve02-to-pve03-migrate.sh`.*
