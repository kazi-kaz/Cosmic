# Save sync (WebDAV)

Keeps the saves of non-Steam games in step between devices (an iPad and an iPhone, say) through a
WebDAV server you run. Steam games keep using Steam Cloud. Code: `app/Madeira/WebDAVSaveSync.swift`.

## How it works

* Play first compares this device with the server and fetches whatever is newer. When the game
  ends, what changed is sent. Settings › Saves › Save sync has a Sync now button too.
* What is synced is what Settings › Saves › Back up saves covers: every Windows user's
  Documents, Saved Games and AppData under `C:\users` (caches left out), files up to 64 MB. The
  registry and the rest of the Wine prefix are never synced.
* The server keeps `manifest.json` and `blobs/<sha256>`. Blobs are never overwritten or deleted by
  the app, so every earlier version of a save is still on the server until you prune it.
* Each file is compared three ways (this device, the server, and what both agreed on last time).
  One side changed: it wins. Both changed: the newer file wins, the older stays on the server
  (and a local copy goes to Files › Cosmic › Save Sync Conflicts).
* A file deleted on one device comes back at the next sync: deletes are not synced.
* Both devices must use the same Windows user name in the prefix (the paths include it).
* The address must be `https://`: the app has no App Transport Security exception for plain http.

## Server

Needs: WebDAV on a folder, behind HTTPS. A sketch with rclone and Tailscale Serve:

```yaml
# docker-compose.yml
services:
  cosmic-saves:
    image: rclone/rclone:latest
    restart: unless-stopped
    command: serve webdav /data --addr :8090 --user cosmic --pass CHANGE_ME
    ports: ["127.0.0.1:8090:8090"]
    volumes: ["/srv/cosmic-saves:/data"]
```

```sh
mkdir -p /srv/cosmic-saves && docker compose up -d
# HTTPS needs "HTTPS Certificates" turned on in the Tailscale admin console (DNS page).
tailscale serve --bg --https=8443 http://127.0.0.1:8090
tailscale serve status        # shows https://<host>.<tailnet>.ts.net:8443
```

In Cosmic: address `https://<host>.<tailnet>.ts.net:8443`, user `cosmic`, the password from the
compose file. Both devices need the Tailscale app connected. Any WebDAV server works (Apache
`mod_dav` honours If-Match on the manifest; the rclone server may not, which only matters if two
devices finish a sync at the same second).

## Pruning old versions

Blobs the manifest no longer names are old saves. This keeps them for 30 days, then deletes them:

```sh
python3 - <<'PY'
import json, os, time
root = "/srv/cosmic-saves"
keep = {e["sha"] for e in json.load(open(f"{root}/manifest.json"))["files"].values()}
cut = time.time() - 30 * 86400
for name in os.listdir(f"{root}/blobs"):
    p = f"{root}/blobs/{name}"
    if name not in keep and os.path.getmtime(p) < cut:
        os.remove(p)
PY
```
