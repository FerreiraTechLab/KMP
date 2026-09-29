# KDownloader PM v0.2.16

PortMaster app for discovering and installing redistributable homebrews through
BitTorrent. The targets are PortMaster-compatible `aarch64` firmwares,
including DarkOS, Rocknix, and immutable systems such as AurNix.

The persistent seeding and signed distributed catalogue design for the next
milestone is documented in [ARCHITECTURE-v0.2.md](ARCHITECTURE-v0.2.md).
Product priorities, open client gaps, and the deferred KMP Publisher plan are
tracked in [ROADMAP.md](ROADMAP.md).

The package includes the official mirror list and Ed25519 public key. The app
discovers the newest signed head, downloads its single-file catalogue through
the persistent aria2 daemon, atomically activates it, and keeps the torrent
available for seeding. The signed head embeds the torrent metadata and the
torrent includes GitHub web seeds, so a first peer can bootstrap without an
existing console seeder.

## Setup on a handheld

1. Put the PortMaster files in the Ports directory: `KMP.sh` and `KMP/`.
2. Open KMP from the Ports menu. It connects to its bundled `aria2c`
   daemon, which restores downloads and seeds from the previous session. The
   default total upload limit is 100 KiB/s. No package manager is required.

Versioned PortMaster packages are stored in `dists/`. The current preview is
`dists/KMP-v0.2.16.zip`; its contents match the layout in `KMP/port.json`.

The portable dependency policy and reproducible download procedure are in
`docs/PORTABLE-RUNTIME.md`.

Catalogue key rotation, offline backup, and recovery procedures are documented
in `docs/CATALOG-KEYS.md`.

The machine-readable catalogue contracts are in `schemas/`. Catalogues from
sequence 3 require `packageSha256`, which is checked again before installation.

The trust screen probes every configured catalogue mirror and reports healthy
versus configured endpoints. During downloads the UI identifies peer or HTTPS
web-seed traffic and gives separate errors for missing metadata, unavailable
mirrors, and peers blocked by NAT or firewall rules.

Reproducible network captures use `KMP/network_metrics.py`; the five-scenario
procedure and recorded fields are documented in `docs/NETWORK-MATRIX.md`.

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
python3 tests/catalog_security.py
python3 tests/catalog_sync.py
bash tests/daemon.sh
luac -p KMP/game/*.lua
bash -n KMP.sh
```

The signed catalogue integration still needs testing on the R36H and a second
peer. The `demo/` files provide a real test torrent.

The `demo/` folder contains a small public-domain package, its torrent, and a
matching catalogue. To regenerate it:

```sh
python3 tools/make-demo-torrent.py demo \
  --tracker http://192.168.0.26:6969/announce
```

The output contains `kmp-demo.zip`, `kmp-demo.torrent`, and `catalog-v1.json`.
Start the development tracker and seed the torrent from a computer with two
terminals:

```sh
python3 tools/dev-tracker.py --port 6969
```

```sh
aria2c --check-integrity --bt-enable-lpd=true --seed-ratio=0 --seed-time=120 \
  --listen-port=6881 --dht-listen-port=6881 \
  -d "$PWD/demo" "$PWD/demo/kmp-demo.torrent"
```

The preview package already includes the demo catalogue. Its torrent uses the
development tracker on `192.168.0.26:6969`, allowing aria2 to rediscover the
seeder after completing the separate magnet metadata task. Keep the demo ZIP
off the R36H before the test. Both peers should be on the same LAN. Run
`hostname -I` on the seeding computer and create
`/roms/ports/KMP/peer.txt` on the R36H containing its LAN address and port, for
example `192.168.1.100:6881`. The app adds this direct peer to the magnet and
also keeps local peer discovery enabled. The second portable can use the same
preview package.
