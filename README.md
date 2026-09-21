# KDownloader PM v0.1

PortMaster app for discovering and installing redistributable homebrews through
BitTorrent. The target is R36H with DarkOS based on Debian 13 (`aarch64`).

## Setup on the R36H

1. Install the Debian torrent client: `sudo apt install aria2`.
2. Put the PortMaster files in `/roms/ports/`: `KMP.sh` and the `KMP/` folder.
3. The preview opens its bundled demo catalogue. For a different catalogue,
   create `/roms/ports/KMP/catalog-url.txt` with **one HTTPS URL**. A local
   `file://` URL is also supported for tests. See
   [the catalogue contract](ARCHITECTURE-v0.1.md).
4. Open KMP from the Ports menu. The app starts its own local `aria2c` process
   and stops it when the app closes. It limits total upload to 100 KiB/s.

`KMP.zip` in the repository is the preview package for PortMaster. Its files
match the layout in `KMP/port.json`.

The catalogue contains a **single-file torrent** whose only file is the ZIP
named by `packageFile`. The ZIP must contain exactly the declared `install.paths`
and their contents. Use an actual redistributable homebrew and a working swarm
for the first end-to-end test. The example in the architecture document has a
placeholder hash and cannot be downloaded.

The old static Google Drive/Pixeldrain catalogue is not read by this version.
The last valid version 1 catalogue is cached for temporary network outages.
Downloaded packages remain under `/roms/ports/.kmp/torrents/` (or SD2) so that
aria2 can resume and seed them during the session. Installed files are tracked
in `.kmp/manifests/`; the uninstaller only removes managed files. Existing
ports without a manifest must be removed manually.

## Development

Source files for the LÖVE app live in `KMP/game/`. Rebuild `KMP/game.love` from
that folder after editing them:

```sh
cd KMP/game
zip -r ../game.love .
```

Local checks from the repository root:

```sh
lua tests/catalog.lua
lua tests/torrent.lua
lua tests/aria2_rpc.lua
lua tests/main_smoke.lua
python3 tests/install.py
python3 tests/rpc_http.py
luac -p KMP/game/*.lua
bash -n KMP.sh
```

The integration still needs testing on the R36H and a second peer. The
development machine does not have LÖVE or aria2 installed, so the graphical
and swarm flow has not run here. The `demo/` files provide a real test torrent.

The `demo/` folder contains a small public-domain package, its torrent, and a
matching catalogue. To regenerate it:

```sh
python3 tools/make-demo-torrent.py demo
```

The output contains `kmp-demo.zip`, `kmp-demo.torrent`, and `catalog-v1.json`.
Seed the torrent from a computer with:

```sh
aria2c --check-integrity --bt-enable-lpd=true --seed-ratio=0 --seed-time=120 \
  -d "$PWD/demo" "$PWD/demo/kmp-demo.torrent"
```

The preview package already includes the demo catalogue. Keep the demo ZIP off
the R36H before the test. Both peers should be on the same LAN; the app enables
local peer discovery. The second portable can use the same preview package.
