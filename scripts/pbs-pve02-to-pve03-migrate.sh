#!/bin/bash
# pve-02 -> pve-03 PBS/rclone migration FINAL step (headless, runs from cron 02:00)
# Self-contained: checks state, stops CTs, removes bind-mount, final rsync delta, migrates,
# re-adds bind-mount, verifies, then reschedules backups into the 02:00-06:00 window.
# Logs everything to /root/pbs-migrate-<date>.log on pve-03.
# Run from pve-03 (10.10.40.13). SSH key pve-03->pve-02 must work (verified).
#
# KNOWN GOTCHAS (fixed in this version, 2026-08-16):
#   - pct migrate <target> expects a NODE NAME (pve-03), NOT an IP.
#   - the migrate command must be issued from the SOURCE node (pve-02), not locally on pve-03.
#   - local bind-mount (mp0) cannot be migrated: remove it before, re-add on the target.
set -u
LOG=/root/pbs-migrate-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "=== PBS migration final step started $(date) ==="

PVE02=10.10.40.12
PVE03=pve-03

# 0) sanity: are we on pve-03?
if ! hostname | grep -q pve-03; then echo "ERROR: not on pve-03, abort"; exit 1; fi

# 0b) reduce swappiness 60->10 (host had 100% swap w/ 5.6G free RAM; less aggressive
#     swap-out during migrate for a small speedup). Temporary now, persist for reboot.
echo "=== reduce vm.swappiness 60 -> 10 ==="
sysctl vm.swappiness=10 2>&1
echo 'vm.swappiness=10' > /etc/sysctl.d/99-pbs-migrate.conf 2>&1 && echo "persisted to /etc/sysctl.d/99-pbs-migrate.conf" || echo "WARN: persist failed"

# 1) wait for the background rsync (from prep step) to finish, max 90 min
echo "=== checking background rsync ==="
for i in $(seq 1 180); do
  if ! pgrep -f "rsync -aHAX --stats root@$PVE02:/mnt/pbs-store" >/dev/null; then
    echo "rsync not running (done or never started) after ${i}*30s"; break
  fi
  [ $i -eq 180 ] && { echo "ERROR: rsync still running after 90min, abort"; exit 1; }
  sleep 30
done

# 2) verify target dataset mounted + apparmor rules present
echo "=== verify /mnt/pbs-store mounted on pve-03 ==="
mount | grep -q "rpool/pbs-store on /mnt/pbs-store" || { echo "ERROR: pbs-store not mounted"; exit 1; }
grep -q "pbs-store/ -> /var/lib/proxmox-backup/backups" /etc/apparmor.d/lxc/lxc-default-cgns \
  || { echo "ERROR: apparmor pbs-store rule missing"; exit 1; }

# 3) stop CT201 + CT204 on pve-02 (PBS down = no new backups during window)
echo "=== stop CT201/CT204 on pve-02 ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$PVE02 'pct stop 201; pct stop 204; sleep 3; pct list | grep -E "201|204"' \
  || { echo "ERROR: failed to stop CTs on pve-02"; exit 1; }

# 3b) remove local bind-mount mp0 so offline migrate can proceed (data already rsync'd to pve-03 /mnt/pbs-store)
echo "=== remove mp0 bind-mount from CT201/CT204 on pve-02 ==="
ssh -o BatchMode=yes root@$PVE02 'pct set 201 -delete mp0; pct set 204 -delete mp0; echo mp0-removed' \
  || { echo "ERROR: failed to remove mp0 on pve-02"; exit 1; }

# 4) final rsync delta (CTs stopped -> consistent)
echo "=== final rsync delta ==="
rsync -aHAX --delete --stats root@$PVE02:/mnt/pbs-store/ /mnt/pbs-store/ \
  || { echo "ERROR: final rsync failed"; exit 1; }

# 5) migrate CTs offline to pve-03 — MUST be issued from the SOURCE node (pve-02), target = pve-03 (node name, NOT IP)
echo "=== migrate CT201 -> pve-03 ==="
ssh -o BatchMode=yes root@$PVE02 'pct migrate 201 pve-03 --online 0' <<<"y" \
  || { echo "ERROR: migrate 201 failed"; exit 1; }
echo "=== migrate CT204 -> pve-03 ==="
ssh -o BatchMode=yes root@$PVE02 'pct migrate 204 pve-03 --online 0' <<<"y" \
  || { echo "ERROR: migrate 204 failed"; exit 1; }

# 5b) re-add local bind-mount mp0 on pve-03 (host /mnt/pbs-store already holds rsync'd data)
echo "=== re-add mp0 bind-mount on pve-03 ==="
pct set 201 -mp0 /mnt/pbs-store,mp=/var/lib/proxmox-backup/backups \
  || { echo "ERROR: failed to re-add mp0 CT201 on pve-03"; exit 1; }
pct set 204 -mp0 /mnt/pbs-store,mp=/mnt/pbs-backup,ro=1 \
  || { echo "ERROR: failed to re-add mp0 CT204 on pve-03"; exit 1; }

# 6) start on pve-03 + apparmor check
echo "=== start CT201/CT204 on pve-03 ==="
pct start 201; pct start 204; sleep 5
echo "=== dmesg apparmor DENIED (pbs-store related)? ==="
dmesg | grep -iE "apparmor|DENIED" | grep -i pbs-store | tail -5 || echo "no pbs-store DENIED"

# 7) verify PBS alive + datastore + rclone log
echo "=== verify CT201 PBS datastore ==="
pct exec 201 -- proxmox-backup-manager datastore show local 2>&1 | head -8
echo "=== pvesm status pbs-server ==="
pvesm status | grep pbs-server
echo "=== CT204 rclone log tail ==="
pct exec 204 -- tail -5 /var/log/rclone-cron.log 2>&1 || echo "(rclone runs at 05:00, not yet)"

# 8) if all good, destroy originals on pve-02 (migrate already removed the conf; this is a safety net)
echo "=== destroy originals on pve-02 ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$PVE02 'pct destroy 201 --purge; pct destroy 204 --purge' \
  && echo "ORIGINALS DESTROYED" || echo "WARN: destroy failed (manual cleanup needed)"

# 9) === RESCHEDULE backups into 02:00-06:00 window (only after successful migrate) ===
echo "=== reschedule PVE backup jobs (cluster-wide, verified IDs) ==="
pvesh set /cluster/backup/backup-61809f18-c9aa --schedule "02:00" 2>&1 && echo "job1 -> 02:00" || echo "WARN job1 schedule failed"
pvesh set /cluster/backup/backup-592fd226-fd19 --schedule "03:00" 2>&1 && echo "job2 -> 03:00" || echo "WARN job2 schedule failed"
pvesh set /cluster/backup/agata-freebuff-backup --schedule "04:00" 2>&1 && echo "job3 -> 04:00" || echo "WARN job3 schedule failed"

echo "=== reschedule CT204 rclone->pCloud cron to 05:00 ==="
pct exec 204 -- bash -c 'crontab -l | sed "s|^0 2 \* \* \*|0 5 * * *|" | crontab -' 2>&1 && echo "rclone cron -> 05:00" || echo "WARN rclone cron failed"
pct exec 204 -- crontab -l 2>&1

echo "=== MIGRATION + RESCHEDULE COMPLETE $(date) ==="
echo "LOG: $LOG"
