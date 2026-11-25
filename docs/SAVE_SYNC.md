# Save sync (WebDAV)

Keeps the saves of non-Steam games in step between devices (an iPad and an iPhone, say) through a
WebDAV server you run. Steam games keep using Steam Cloud. Code: `app/Madeira/WebDAVSaveSync.swift`.

## How it works

* Cosmic finds a game's save files by watching what it changes: it scans the save folders (the ones
  Settings › Saves › Back up saves covers: Documents, Saved Games and AppData under `C:\users`,
  caches left out) before a game starts and again when it ends. The files that changed are that
  game's. The list is kept per game, here and on the server, so a second device that has never run
  the game knows what to fetch. A game is therefore synced from its first session on.
* Play first brings the game's files up to date from the server. When the game ends, what changed
  is sent. Settings › Saves › Save sync has a Sync now button for every game this device knows.
* Two switches: the global one (Settings › Saves) and one per game (Game details › Save sync, shown
  for games that are not Steam games). Steam games keep using Steam Cloud and are never synced.
* A game that rewrites a settings or log file on every run adds that file to its list. It is
  harmless, only a few extra kilobytes.
* Files over 64 MB are skipped. The registry and the rest of the Wine prefix are never synced.
* The server keeps `manifest.json` (every synced file, and each game's file list) and
  `blobs/<sha256>`. Blobs are never overwritten or deleted by the app, so every earlier version of a
  save is still on the server until you prune it.
* Each file is compared three ways (this device, the server, and what both agreed on last time).
  One side changed: it wins. Both changed: the newer file wins, the older stays on the server
  (and a local copy goes to Files › Cosmic › Save Sync Conflicts).
* A file deleted on one device comes back at the next sync: deletes are not synced.
* Both devices must use the same Windows user name in the prefix (the paths include it).
* JIT needs LocalDevVPN, and iOS allows one VPN at a time, so Tailscale cannot be on while you play.
  LocalDevVPN only loops back to the device, so Wi-Fi and the home network keep working. At home,
  use the server's home-network address. Away from home the sync fails quietly and the game starts
  anyway; it catches up the next time you play at home (or Sync now with Tailscale on and LocalDevVPN off).
* The address may be `http://` only for a home-network address (192.168.x.x, 10.x, a `.local` or
  one-word name): Info.plist has `NSAllowsLocalNetworking` and nothing broader. Anything else must be
  `https://`. Plain http sends the password unencrypted, which on your own Wi-Fi is the usual trade.

## Server

Needs: a WebDAV server on a folder, reachable from the home network. With rclone in Docker:

```yaml
# docker-compose.yml
services:
  cosmic-saves:
    image: rclone/rclone:latest
    restart: unless-stopped
    command: serve webdav /data --addr :8090 --user cosmic --pass CHANGE_ME
    ports: ["8090:8090"]
    volumes: ["/srv/cosmic-saves:/data"]
```

```sh
mkdir -p /srv/cosmic-saves && docker compose up -d
curl -u cosmic:CHANGE_ME -X MKCOL http://localhost:8090/blobs/   # optional check
```

In Cosmic: address `http://<server LAN IP>:8090` (give the server a fixed address or DHCP
reservation in your router), user `cosmic`, the password from the file. The first iOS "local network"
prompt must be allowed. For use away from home, put it behind your own HTTPS (a Cloudflare Tunnel
or a reverse proxy) and use that `https://` address instead; use a long password.
The rclone server may ignore If-Match on the manifest, which only matters if two devices finish
a sync at the same second; Apache `mod_dav` honours it.

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
