# AppArmor Bind-Mount Rules for PBS LXC

> Proxmox LXC containers running under AppArmor require explicit path entries to allow bind-mount access to host directories outside the default LXC rootfs paths.

---

## Why This Is Needed

Proxmox uses the `lxc-default-cgns` AppArmor profile for unprivileged containers. By default it denies mounts to arbitrary host paths. When you configure `mp0: /mnt/pbs-data,...` in an LXC config, AppArmor may block the mount at CT startup with a cryptic `mount denied` or silent failure.

Check if AppArmor is blocking:

```bash
# On the Proxmox host:
dmesg | grep -i apparmor | tail -20
journalctl -k | grep "apparmor" | grep "DENIED" | tail -10
```

---

## Applying the Patch

The patch adds `/mnt/pbs-data/` to the allowed mount paths in the LXC AppArmor profile.

**File:** `templates/apparmor/lxc-default-cgns-pbs.patch`

Apply on the **Proxmox host** (pve-02):

```bash
# Backup the original profile
cp /etc/apparmor.d/lxc/lxc-default-cgns /etc/apparmor.d/lxc/lxc-default-cgns.bak

# Apply the patch
patch /etc/apparmor.d/lxc/lxc-default-cgns < templates/apparmor/lxc-default-cgns-pbs.patch

# Reload AppArmor profiles
apparmor_parser -r /etc/apparmor.d/lxc/lxc-default-cgns

# Verify (no output = success)
apparmor_status | grep lxc
```

---

## Manual Alternative (without patch)

If you prefer not to use the patch, add these lines manually to `/etc/apparmor.d/lxc/lxc-default-cgns`:

```
# PBS host bind-mount paths
mount options=(ro, rw) /mnt/pbs-data/ -> /var/lib/proxmox-backup/backups/,
mount options=(ro) /mnt/pbs-data/ -> /mnt/pbs-backup/,
```

Place these lines inside the `profile lxc-default-cgns` block, after the existing `mount` rules.

---

## Unprivileged vs Privileged Containers

| Container Type | AppArmor | Bind-mount behavior |
|---|---|---|
| Unprivileged (`unprivileged: 1`) | Active, restricts mounts | Patch required for custom host paths |
| Privileged (`unprivileged: 0`) | Optional | Bind-mounts work without AppArmor changes |

CT201 (PBS) and CT204 (rclone-sync) in this repo are **unprivileged**. If you convert them to privileged, AppArmor bind-mount restrictions disappear but you lose the LXC user namespace isolation.

---

## Verifying the Bind Mounts Are Active

```bash
# After CT restart, verify mounts are live:
pct exec 201 -- df -h /var/lib/proxmox-backup/backups/
# Expected: filesystem = /mnt/pbs-data, not the CT rootfs

pct exec 204 -- ls -lh /mnt/pbs-backup/ | head -5
# Expected: PBS namespace files (namespaces/, datastore.cfg, etc.)

# If empty: AppArmor is likely blocking — check dmesg
dmesg | grep -E "apparmor|DENIED" | tail -20
```

---

## Rollback

```bash
# Restore original AppArmor profile
cp /etc/apparmor.d/lxc/lxc-default-cgns.bak /etc/apparmor.d/lxc/lxc-default-cgns
apparmor_parser -r /etc/apparmor.d/lxc/lxc-default-cgns
```

---

*Reference: [Proxmox wiki — Linux Container AppArmor](https://pve.proxmox.com/wiki/Linux_Container#pct_apparmor)*
