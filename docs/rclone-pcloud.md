# pCloud rclone Remote Setup and Token Refresh

> How to configure rclone for pCloud EU, obtain a token on a headless server, and refresh it when it expires.

---

## Initial Setup

### 1. Install rclone inside CT204

```bash
# Inside CT204 (rclone-sync):
curl https://rclone.org/install.sh | bash

# Verify:
rclone version
```

### 2. Configure pCloud remote (headless method)

On a **headless** Proxmox LXC you cannot open a browser, so use the `--auth-no-open-browser` + remote authorization flow.

```bash
# Step 1: Start the config wizard on CT204
rclone config

# Select: n (new remote)
# Name: pcloud
# Storage type: 38 (pCloud)
# client_id: (leave blank)
# client_secret: (leave blank)
# Edit advanced config: n
# Use web browser to authenticate: n  ← IMPORTANT on headless
# → rclone prints a URL and waits
```

```
Please go to the following link: https://www.pcloud.com/oauth2/authorize?...
Log in and authorize rclone, then paste the result below:
```

```bash
# Step 2: On a Windows/Mac/Linux machine with a browser, run:
rclone authorize "pcloud"
# → Opens browser → log in → paste the token string back to CT204
```

### 3. Set pCloud EU endpoint

pCloud has two datacenters. EU users must set the hostname explicitly:

```bash
rclone config show pcloud
# If hostname is not set, edit:
rclone config update pcloud hostname eapi.pcloud.com
```

Verify connectivity:

```bash
rclone about pcloud:
# Total: 500G, Used: 265G, Free: 235G
```

---

## Token Structure

pCloud uses a bearer token (not OAuth refresh token). It does **not expire** by default.

```json
{
  "access_token": "YOUR_ACCESS_TOKEN",
  "token_type": "bearer",
  "expiry": "0001-01-01T00:00:00Z"
}
```

The `expiry: 0001-01-01` is **expected and normal** for pCloud bearer tokens. It does not indicate an error.

The rclone config is stored in `/root/.rclone.conf` inside CT204. **Never commit this file** — it contains your access token.

---

## Token Refresh (if connection breaks)

If rclone suddenly fails with authentication errors:

```bash
# Inside CT204:
rclone config reconnect pcloud:
# → Select: y (yes, refresh)
# → Select: n (no browser available)
# → Copy the displayed URL

# On a desktop machine:
rclone authorize "pcloud"
# → Opens browser → authorize → copy the output token

# Paste the token back into the CT204 session
```

---

## DNS Configuration

pCloud EU (`eapi.pcloud.com`) may not resolve via the default MikroTik DNS. Set CT204 to use public DNS:

```bash
# On the Proxmox host:
pct set 204 --nameserver "8.8.8.8 1.1.1.1"

# Verify inside CT204:
pct exec 204 -- bash -c "cat /etc/resolv.conf"
# nameserver 8.8.8.8
# nameserver 1.1.1.1

pct exec 204 -- bash -c "host eapi.pcloud.com"
# eapi.pcloud.com has address 194.62.174.X
```

---

## Verifying the Remote

```bash
# List top-level folders:
rclone lsd pcloud:

# List PBS backup folder:
rclone ls pcloud:Proxmox/PBS-backup | wc -l

# Check storage usage:
rclone about pcloud:

# Dry-run sync (no changes made):
rclone sync /mnt/pbs-backup pcloud:Proxmox/PBS-backup \
  --dry-run --log-level INFO 2>&1 | tail -20
```

---

## Security Notes

- `/root/.rclone.conf` contains the raw bearer token — protect it with `chmod 600 /root/.rclone.conf`
- CT204 has a read-only bind-mount of the PBS datastore — rclone **cannot** corrupt or delete PBS data from the source side
- The sync script uses `--delete-after` on the pCloud destination: if CT204's source mount is empty (bind-mount failure), it **will delete pCloud content**. The safety guard in `pbs-backup-sync.sh` prevents this — verify it is in place
- Consider `rclone sync ... --immutable` on the pCloud target once the initial sync is verified, to prevent accidental overwrites

---

## Useful rclone Commands

```bash
# Show remote config (masked):
rclone config show pcloud

# Test connection:
rclone about pcloud:

# Count objects in backup folder:
rclone size pcloud:Proxmox/PBS-backup

# List recent files:
rclone ls pcloud:Proxmox/PBS-backup | sort | tail -20

# Delete a specific namespace (recovery of accidental sync):
# rclone delete pcloud:Proxmox/PBS-backup/ns/vm/101 --dry-run
```

---

*Tested on: rclone 1.67, pCloud EU (eapi.pcloud.com), Proxmox LXC Debian 12*
