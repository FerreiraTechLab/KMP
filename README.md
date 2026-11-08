# KDownloader PM v0.2.41

PortMaster app for discovering and installing redistributable homebrews through
BitTorrent. The targets are PortMaster-compatible `aarch64` firmwares,
including DarkOS, Rocknix, and immutable systems such as AurNix.

The persistent seeding and signed distributed catalogue design for the next
milestone is documented in [ARCHITECTURE-v0.2.md](ARCHITECTURE-v0.2.md).
Product priorities, open client gaps, and the deferred KMP Publisher plan are
tracked in [ROADMAP.md](ROADMAP.md).

The stable boundary between Publisher submissions, editorial review and the
Client catalogue is specified in
[docs/PUBLISHING-CONTRACT.md](docs/PUBLISHING-CONTRACT.md). Version 3 adds
immutable revisions, package variants, provenance, review records and signed
revocations while retaining catalogue v2 during migration.

Publisher packages can be checked without extraction or execution using
`tools/audit-package.py`. The automatic rejection rules, human-review warnings
and report format are documented in
[docs/PORT-SECURITY.md](docs/PORT-SECURITY.md).

The package includes the official mirror list and Ed25519 public key. The app
discovers the newest signed head, downloads its single-file catalogue through
the persistent BitTorrent daemon, atomically activates it, and keeps the torrent
available for seeding. The signed head embeds the torrent metadata and the
torrent includes GitHub web seeds, so a first peer can bootstrap without an
existing console seeder.

## Setup on a handheld

1. Put the PortMaster files in the Ports directory: `KMP.sh` and `KMP/`.
2. Open KMP from the Ports menu. It connects to its bundled `kmp-torrentd`
   daemon, which restores downloads and seeds from the previous session. The
   default total upload limit is 100 KiB/s. No package manager is required.

To validate a console-to-console transfer, open an uninstalled port's details
and press **X**. This test removes that package from the receiving console,
unregisters its previous torrent, and disables HTTPS web seeds for the new
transfer. It can then receive data only from BitTorrent peers discovered by a
direct peer setting, the local network, DHT, or trackers. Each test uses a new,
empty directory and caps the receiving speed at 1 MiB/s so its progress and
peer count remain visible on screen.

Versioned PortMaster packages are stored in `dists/`. The current preview is
`dists/KMP-v0.2.53.zip`; its contents match the layout in `KMP/port.json`.

When the BitTorrent daemon starts, the Client attempts to map its TCP and UDP
listen port through UPnP and then NAT-PMP. The lease is renewed while the
daemon remains active and removed when it stops. An accepted mapping improves
console-to-console transfers across networks; CGNAT can still prevent inbound
connections. The installed-port details and diagnostics report the negotiated
method and external address scope.

`kmp-torrentd` uses the anacrolix BitTorrent stack with TCP, uTP, DHT over
IPv4/IPv6, PEX and BEP 55 hole punching. Hole punching lets two peers behind
compatible NATs ask a mutually connected peer to coordinate a direct uTP
connection; package bytes still travel directly between peers. Router mapping
is attempted as an additional path and is not required when hole punching or a
public IPv6 path succeeds. aria2 remains a launcher fallback during migration.

The signed catalogue lists always-reachable public seed nodes in
`extensions["kmp.seed-nodes"]` (`IPv4:port`, see `deploy/kmp-seed`). The Client
adds each one to the package magnet as `x.pe`, so every download starts with a
reachable peer and a hole-punching rendezvous even before trackers or DHT
answer. Invalid entries are ignored and never block the catalogue.

Every new Client starts with **Nó comunitário** enabled and can disable or
enable it at any time in the options menu. The
optional `community_storage_mb=4096` setting controls its storage allowance.
It adds verified catalogue torrents to the existing daemon and
stores their packages under `KMP/conf/community/`. The storage limit is filled
with smaller packages first. Battery seed limits and the global upload limit
continue to apply.
On handhelds, aggregate BitTorrent downloads default to 1 MiB/s and each
torrent uses a bounded connection pool so community mirroring cannot starve
catalogue access or the rest of the system network.

The signed catalogue can publish a reserved `kmp-client` item. When its version
is newer, the options menu offers the Client update without listing it as a
port. KMP downloads the same ZIP through BitTorrent or HTTPS, verifies the
catalogue signature and package SHA-256, validates the archive, and stages it
outside the live application directory. The launcher applies it only after the
interface exits. A persistent journal restores the previous Client after an
interruption; catalogue state, settings, diagnostics and local peer settings
are preserved.

For support, open the options menu and select **Exportar diagnostico**. The
client writes a bounded, redacted ZIP inside the installed
`KMP/diagnostics` directory. Keeping diagnostics inside the application avoids
having the frontend interpret the directory as another port. RPC secrets,
authorization headers, passwords and URL tokens are removed; torrent session
files and secret files are never included.

The portable dependency policy and reproducible download procedure are in
`docs/PORTABLE-RUNTIME.md`.

Hardware results for aria2 session restoration and battery-aware seeding are
recorded in [docs/HARDWARE-VALIDATION.md](docs/HARDWARE-VALIDATION.md).

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
the daemon can resume and seed them during the session. Installed ports are tracked
in `.kmp/manifests/`. Ports without a manifest must be removed manually.
Removing a managed port is
deliberately complete: installed files, saves, settings, cached packages and
its BitTorrent session are deleted.

When the signed catalogue publishes a version different from the installed
manifest, the client shows both versions and offers an update. Updates replace
package-owned files, preserve user-created saves and settings, and use a
persistent journal to restore the previous version after an interruption.

Catalogue v3 items can provide multiple device variants. The launcher reports
the firmware, architecture, memory, controls, renderers and installed
PortMaster runtimes; the client selects exactly one compatible variant and
orders updates by the immutable integer `revision`. Installation manifests
record the selected variant and package SHA-256. Signed revocations can warn
about an installed package or block a compromised package from installation.

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
lua tests/main_controls.lua
KMP_TEST_MODE=1 lua tests/main_flows.lua
python3 tests/install.py
python3 tests/rpc_http.py
python3 tests/catalog_security.py
python3 tests/catalog_sync.py
python3 tests/self_update.py
bash tests/daemon.sh
(cd torrentd && go test ./...)
luac -p KMP/game/*.lua
bash -n KMP.sh
```

The signed catalogue, peer transfer, aria2 restoration and battery policy have
been validated on the R36H; results are recorded in
`docs/HARDWARE-VALIDATION.md`. The `demo/` files provide a reproducible test
torrent.

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
