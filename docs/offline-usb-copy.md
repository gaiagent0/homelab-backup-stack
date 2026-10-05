# Offline USB copy (the "1" in 3-2-1-1)

The PBS -> rclone -> pCloud chain is a **mirror** (`rclone sync --delete-after`): a wrongly pruned or corrupted PBS datastore is propagated to the cloud on the next night. A periodically connected, encrypted USB drive adds an **offline, versionless-by-design copy** that no sync can overwrite.

## What goes on the drive
- monthly full logical dumps (`pg_dump -Fc`) of the application databases and the archives of dropped time-series partitions (zstd dumps),
- exports of daily aggregates, the backup/restore configs and a `SHA256SUMS` manifest.

## Rules
- Encrypt the volume (BitLocker To Go) and keep the drive **disconnected** except while copying (ransomware-safe).
- Pull from the database host over SSH, never push from it; verify every file with `sha256sum` on both sides before trusting a copy.
- Prefer a **resumable SSH stream** over `scp` for multi-GB files: measured 2026-10-03 on a 4.56 GB dump over Wi-Fi, `scp` ran at 24 MB/s but restarts from zero after a drop; an `ssh ... tail -c +OFFSET` stream resumed an interrupted 1 GiB transfer and produced an identical SHA-256.
- Restore-test one archive per month into a scratch database.

A reference puller (resume loop + checksum manifest) lives in the Agata repo: `docs/04-technikai-setup/db-karbantartas/tools/usb_pull.sh`.
