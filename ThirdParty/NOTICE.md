# Third-party notices

TunnelOne is an independent project, not affiliated with WireGuard LLC or
MetaCubeX. The TunnelOne modifications and new code are GPL-3.0-or-later.

## WireGuard for Apple platforms

Sources/Shared, Sources/WireGuardApp, Sources/WireGuardKit,
Sources/WireGuardKitC, Sources/WireGuardKitGo and
Sources/WireGuardNetworkExtension originate from WireGuard/wireguard-apple.
The pinned upstream revision is in wireguard-revision.txt.
Original copyright notices and the MIT license are retained in source files
and WireGuard-LICENSE. TunnelOne modifies the macOS application, its branding,
configuration persistence, and network extension to add proxy lifecycle support.
The upstream sources also include minizip/zlib, whose notices remain in
Sources/WireGuardApp/ZipArchive/3rdparty/minizip.

## Mihomo

The separate bundled Mihomo executable is unmodified upstream v1.19.34,
commit 0455d0d28c4526937380505153e65a843d8612e8, licensed under GPL-3.0.
See Mihomo-LICENSE and scripts/dependencies.lock.json for exact binary inputs
and SHA-256 digests. Releases distribute matching source and the upstream
vendored dependency archive alongside the application, plus upstream build
scripts. See docs/third-party.md for source rebuild instructions.

## YAML v3

The core launcher uses gopkg.in/yaml.v3 v3.0.1, under the MIT and Apache-2.0
licenses. See YAML-v3-LICENSE.

## WireGuard Go backend

The backend and transitive Go modules are pinned in
Sources/WireGuardKitGo/go.mod and go.sum. Their corresponding source and
license files are included in the release's source bundle. Original
wireguard-go licensing is retained; see its source for the applicable MIT
license and component notices.

## Lucide

The interactive design prototype uses a vendored Lucide 0.468.0 browser build.
It is covered by the ISC license; see Lucide-LICENSE.
