# PBS CT Újratelepítés Runbook
*Utolsó frissítés: 2026-06-22 — valós incidens alapján*

## Probléma
A PBS CT (CT201, pbs-server, pve-02) nem indul el mert a root filesystem (local storage) megtelt, és a disk fájl törlődött vagy megsérült.

---

## 1. Disk újralétrehozása

```bash
mkdir -p /var/lib/vz/images/201
pvesm alloc local 201 vm-201-disk-0.raw 100G
```

**FONTOS:** Ne formázd meg kézzel (`mkfs.ext4`) — a `pct create` maga kezeli.

---

## 2. CT konfig törlése (ha szükséges)

Ha a CT konfig megmaradt de a disk hiányzik:
```bash
# Ellenőrzés
find /etc/pve -name "201.conf" 2>/dev/null

# Ha ragadt destroy process van:
kill -9 $(pgrep -f "destroy.*201") 2>/dev/null
rm -f /run/lock/lxc/pve-config-201.lock

# Konfig törlése
rm -f /etc/pve/nodes/pve-02/lxc/201.conf

# pmxcfs restart ha D-state processek vannak
systemctl restart pve-cluster
```

---

## 3. CT újralétrehozása

Ne add meg a meglévő diskot — hagyd a `pct create`-et magát allokálni:

```bash
pct create 201 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname pbs-server \
  --memory 512 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,gw=10.10.40.1,ip=10.10.40.14/24,tag=40,type=veth \
  --rootfs local:100 \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --timezone Europe/Budapest \
  --swap 2048 \
  --onboot 1 \
  --startup order=10,up=60
```

**FONTOS:** Az `--mp0` mountot NE add meg most — csak az első sikeres start után!

---

## 4. CT elindítása és PBS telepítése

```bash
pct start 201
pct exec 201 -- bash -c "apt-get update && apt-get install -y gnupg wget"

pct exec 201 -- bash -c "
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg &&
echo 'deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription' > /etc/apt/sources.list.d/pbs.list &&
apt-get update &&
apt-get install -y proxmox-backup-server
"
```

---

## 5. Backup store mountolása

```bash
pct set 201 --mp0 /mnt/pbs-store,mp=/var/lib/proxmox-backup/backups
pct restart 201
```

---

## 6. PBS bejelentkezési konfiguráció

Ez a legkritikusabb lépés — ezek nélkül nem lehet bejelentkezni a web UI-ra.

### Root jelszó beállítása
```bash
pct exec 201 -- passwd root
```

### user.cfg létrehozása (helyes formátum!)
```bash
pct exec 201 -- bash -c "printf 'user: root@pam\n\tenable 1\n\tcomment Superuser\n' > /etc/proxmox-backup/user.cfg"
```

**KRITIKUS formátum szabályok:**
- Property nevek után **NEM kell kettőspont** (helyes: `enable 1`, hibás: `enable: 1`)
- Sorok **TAB-bal** vannak indentálva

### acl.cfg létrehozása
```bash
pct exec 201 -- bash -c "echo 'acl:1:/:root@pam:Admin' > /etc/proxmox-backup/acl.cfg"
```

### datastore.cfg létrehozása
```bash
pct exec 201 -- bash -c "printf 'datastore: local\n\tpath /var/lib/proxmox-backup/backups\n' > /etc/proxmox-backup/datastore.cfg"
```

### Fájl jogosultságok javítása
```bash
pct exec 201 -- bash -c "
chown root:backup /etc/proxmox-backup/user.cfg &&
chown root:backup /etc/proxmox-backup/acl.cfg &&
chown root:backup /etc/proxmox-backup/datastore.cfg &&
chmod 640 /etc/proxmox-backup/user.cfg &&
chmod 640 /etc/proxmox-backup/acl.cfg &&
chmod 640 /etc/proxmox-backup/datastore.cfg &&
systemctl restart proxmox-backup
"
```

**KRITIKUS:** Minden config fájl tulajdonosa `root:backup` kell legyen!

---

## 7. Bejelentkezés

URL: `https://10.10.40.14:8007`
- **Username:** `root`
- **Realm:** Linux PAM standard authentication
- **Jelszó:** amit a `passwd root`-tal beállítottál

**Hibák és megoldásuk:**

| Hibaüzenet | Ok | Megoldás |
|-----------|-----|----------|
| `user account disabled or expired` | user.cfg hiányzik vagy hibás | user.cfg újraírása `enable 1`-gyel |
| `Permission denied (os error 13)` | rossz ownership | `chown root:backup` |
| `wrong number of items` | hibás acl.cfg formátum | `acl:1:/:root@pam:Admin` (5 mező, kettőspont elválasztó) |
| `authentication error - SUCCESS (0)` | PAM OK de acl.cfg hiányzik | acl.cfg létrehozása |
| `root@pam@pam` | dupla realm a UI-ban | Username mezőbe csak `root`, Realm legördülőből PAM |

---

## 8. Datastore ellenőrzése

```bash
pct exec 201 -- proxmox-backup-manager datastore list
pct exec 201 -- bash -c "ls /var/lib/proxmox-backup/backups/ct/"
```

---

## 9. Proxmox storage fingerprint és jelszó frissítése

Új PBS telepítés után új TLS cert generálódik — frissíteni kell a PVE storage konfigban.

```bash
# Új fingerprint lekérése
pct exec 201 -- proxmox-backup-manager cert info | grep Fingerprint

# Frissítés (pve-01-ről futtatva, cluster-wide)
pvesh set /storage/pbs-server --fingerprint "xx:xx:..."
pvesh set /storage/pbs-server --password 'a_root_jelszó'

# Ellenőrzés mindhárom node-on
pvesh get /nodes/pve-01/storage/pbs-server/status
pvesh get /nodes/pve-02/storage/pbs-server/status
pvesh get /nodes/pve-03/storage/pbs-server/status
```

**Sikeres állapot:** `active: 1` mindhárom node-on.

---

## Tárhelykezelés — amit megelőzhetett volna ezt az incidenst

A katasztrófa oka: a `rpool/ROOT/pve-1` megtelt mert a `/mnt/pbs-data` (régi, felesleges PBS store) 26GB-ot foglalt.

```bash
# Rendszeres ellenőrzés
zfs list
du --max-depth=2 /mnt 2>/dev/null | sort -rn | head -10

# Ha /mnt alatt nagy felesleges könyvtár van:
rm -rf /mnt/pbs-data &
```

**Backup store helyek pve-02-n:**
- `/mnt/pbs-store` — a valódi PBS store (ZFS: `rpool/pbs-store`), **SOHA NE TÖRÖLD**
- `/mnt/pbs-store-new` — ugyanaz, másik mountpoint
- `/mnt/pbs-data` — régi/elavult store volt, törölhető
