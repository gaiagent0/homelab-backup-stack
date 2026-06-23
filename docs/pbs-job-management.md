# PBS Backup Job Kezelés
*Utolsó frissítés: 2026-06-22*

## Jelenlegi backup job-ok

### Job 1 — Fontos szolgáltatások (`backup-592fd226-fd19`)
- **Ütemezés:** 02:30
- **CT-k:** 150, 203, 208, 302, 303, 304, 305, 306
- **Prune:** keep-last=3, keep-daily=7, keep-weekly=4, keep-monthly=3
- **Mód:** snapshot

### Job 2 — Kritikus CT-k (`backup-61809f18-c9aa`)
- **Ütemezés:** 00:30
- **CT-k:** 101, 105, 106, 107, 204
- **Prune:** keep-last=3, keep-daily=7, keep-weekly=4, keep-monthly=3
- **Mód:** snapshot

---

## Job módosítása

```bash
# Job lista
pvesh get /cluster/backup

# Job részletei
pvesh get /cluster/backup/<job-id> --output-format json

# CT-k hozzáadása job-hoz
pvesh set /cluster/backup/<job-id> --vmid "101,102,103" --comment "Leírás"
```

---

## Manuális backup indítása

```bash
# pve-01-es CT-k (pve-01-ről)
pvesh create /nodes/pve-01/vzdump --vmid 150 --storage pbs-server --mode snapshot

# pve-03-as CT-k (SSH-val pve-03-ra)
ssh pve-03 "vzdump 304 305 306 --storage pbs-server --mode snapshot"

# pve-02-es CT-k (SSH-val pve-02-re)
ssh pve-02 "vzdump 208 --storage pbs-server --mode snapshot"
```

**FONTOS:** A `pvesh create /nodes/pve-01/vzdump` csak pve-01-en lévő CT-kre működik!
Cross-node backuphoz mindig SSH-val kell a megfelelő node-ra menni.

---

## Backup tartalom lekérése

```bash
# Összes backup listája CT-nként
pvesh get /nodes/pve-01/storage/pbs-server/content --output-format json | python3 -c "
import json, sys
data = json.load(sys.stdin)
by_vm = {}
for item in data:
    vmid = item['vmid']
    if vmid not in by_vm:
        by_vm[vmid] = []
    by_vm[vmid].append(item['volid'])
for vmid in sorted(by_vm):
    print(f'CT{vmid}: {len(by_vm[vmid])} backup')
    for v in sorted(by_vm[vmid]):
        print(f'  {v}')
"
```

---

## Backup task ellenőrzése

```bash
# pve-01 task-ok
pvesh get /nodes/pve-01/tasks --typefilter vzdump --limit 10

# pve-02 task-ok
pvesh get /nodes/pve-02/tasks --typefilter vzdump --limit 10

# pve-03 task-ok
pvesh get /nodes/pve-03/tasks --typefilter vzdump --limit 10
```
