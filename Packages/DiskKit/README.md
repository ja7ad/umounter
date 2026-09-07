# DiskKit

The M0 spike from [the design proposal](../../docs/design/0001-umounter-proposal.md). It holds the disk layer of UMounter and has no UI.

| Type | What it does |
|---|---|
| `DiskArbitrationSession` | One `DASession` on a private queue. It provides a full disk listing (IOKit `IOMedia` + network mounts), live `events` (`AsyncStream`), and async `unmount` / `eject` / `mount` (including read-only) and `ejectSafely` (flush → unmount containers → unmount the physical disk → check that nothing is still mounted → eject or park). |
| `DiskInfo` | A `Sendable` snapshot of a disk. It includes `kind` and `physicalRootBSDName` (the device you actually unplug). |
| `BlockerScanner` | Finds processes using a volume with `proc_listpidspath` (`PATH_IS_VOLUME`, `EXCLUDE_EVTONLY`), and can list their open files. |
| `VolumeFlusher` | `sync_volume_np(FULLSYNC \| WAIT)`, run off the caller's thread. |
| `DiskError` | Typed `DADissenter` status. |

## Try it

```bash
swift build
.build/debug/diskkit-spike list            # --all to include internal disks
.build/debug/diskkit-spike watch
.build/debug/diskkit-spike blockers /Volumes/X --files
.build/debug/diskkit-spike eject /Volumes/X          # --park to unmount only
.build/debug/diskkit-spike mount disk7 --whole --readonly
```

A safe way to test without hardware:

```bash
hdiutil create -size 64m -fs APFS -volname DKTest /tmp/t.dmg && hdiutil attach /tmp/t.dmg
```

## Tests

On a machine that has only the Command Line Tools (no Xcode), SwiftPM does not find the Swift Testing macro plugin. Point it there explicitly:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

With Xcode installed, plain `swift test` works.

## M0 measurements (Apple silicon, macOS 27)

- `watch` while idle: **0.0 % CPU, 0 idle wakeups, 2 threads, 3.4 MB footprint**.
- Park of an APFS volume on a disk image: about 100–180 ms. Read-only remount: about 60–140 ms.

## Findings to carry into M1+

- An APFS container synthesized on a disk image reports `Virtual Interface` like the image itself. Classify it by IORegistry ancestry (an `IOMedia` above it), not by protocol.
- Unmounting a physical/image whole disk returns **success without unmounting** volumes that live in a synthesized APFS container. Containers must be unmounted first, and the result must be re-checked against the mount table. `ejectSafely` does both.
- `DADiskMountWithArguments` together with `kDADiskMountOptionWhole` fails with `kDAReturnBadArgument`. A read-only "whole" mount therefore mounts each volume individually.
- DiskArbitration reports autofs trigger points (`/System/Volumes/Data/home`) as network volumes. They are excluded from "Eject All".
- Not done yet: retry/backoff on busy, sleep integration, and dependency ordering for images stored on external disks (M2/M3).
