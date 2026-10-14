# UMounter app

A menu bar app built on [DiskKit](../Packages/DiskKit). It targets macOS 14 Sonoma and later, and uses Liquid Glass on macOS 26+.

| Target | Contents |
|---|---|
| `UMounterCore` | UI-free logic, unit-tested: `DiskStore` (observable disk state), `DiskCatalog` (devices, categories), `AppSettings` (typed `UserDefaults`), `AutomationController` (sleep / display off / logout / wake decisions). |
| `UMounter` | AppKit entry point (`main.swift`) with an `NSStatusItem` menu built only when opened. The Jettison-style Settings window (`NSTabViewController` toolbar tabs hosting SwiftUI forms) exists only while it's open. Also `PowerMonitor` (IOKit sleep acknowledgement), `HotkeyCenter` (Carbon global hotkeys, no permissions needed), and `Feedback` (sounds, lazily connected notifications, alerts). |

## Build and run

```bash
../scripts/build-app.sh          # → build/UMounter.app (ad-hoc signed)
open build/UMounter.app
```

## Test

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Snapshot the Settings UI (debug builds)

```bash
swift build && UMOUNTER_SNAPSHOT_DIR=/tmp/umounter-snapshots .build/debug/UMounter
```

This renders every Settings tab in light and dark mode to PNG files, then exits.

## Command Line Tools caveats

- SDK 27 turns `@State` into a macro, and the CLT toolchain doesn't ship the SwiftUI macro plugin. Views therefore keep their state in `@Observable` models owned by `AppModel`. This builds fine under Xcode too.
- The Swift Testing macro plugin needs the `-plugin-path` flag shown above.

## Memory and energy (measured 2026-10-14, macOS 27, Apple silicon, release build)

| | Before | After |
|---|---|---|
| Idle footprint (`footprint`) | 49 MB | **13 MB** |
| Live heap (`heap`) | 23.6 MB | 3.8 MB |
| Idle CPU / wakeups / threads | 0% / ~0 / 3 | **0% / 0 / 3** |
| After the menu is first opened | — | ~20–22 MB (macOS's own menu rendering and SF Symbols) |
| With Settings open | — | 32 MB |
| After Settings closes | — | 31 MB (all window objects freed; see below) |

What changed:
- **No SwiftUI at idle.** `MenuBarExtra` kept a full SwiftUI view graph alive for the whole app lifetime (about 20 MB of heap: `PropertyList.Element`, `PlatformItemList.Item`, tracked-value dictionaries). The menu is now an `NSMenu` built in `menuNeedsUpdate` and emptied after it closes. The icon is redrawn only when its state changes.
- **Settings window on demand.** It is created when opened and released on close. `heap` confirms that no window, hosting controller or view graph objects remain.
- **Notifications on demand.** `UNUserNotificationCenter` (an XPC connection plus framework state) is connected only before the first notification, when auto-eject is on, or when the app was launched from a notification.

Why memory grows with use: the first use of each piece of UI loads frameworks. Measured costs are about 7 MB for the menu, 18 MB for Settings, 3 MB for the Couldn't Eject window, and about 9 MB for an `NSAlert`. macOS never unloads frameworks from a running process. This is not a leak: repeated ejects stay flat at about 15.5 MB (`UMOUNTER_DEBUG_EJECT_LOOP`).

**Memory reclaim (`MemoryReclaimer`, Settings → General → "Keep memory low", on by default).** UMounter restarts itself in the background when all of these hold:
- it has been idle for 2 minutes (no window, menu closed, no operation, not handling sleep);
- its footprint is above 30 MB;
- its footprint is at least 12 MB above its settled launch footprint (the lower of the samples at 3 s and 15 s), which prevents restart loops.

Parked disks are saved and restored, so Remount keeps working. The new process starts with a clean environment and with window restoration off. Measured: 33 MB with Settings open, then 13 MB after the restart. The countdown is armed only when activity ends, so there is no polling.

## Energy

`SystemPowerState` follows macOS Low Power Mode (`ProcessInfo.isLowPowerModeEnabled` and `NSProcessInfoPowerStateDidChange`). With Settings → General → "Reduce background activity in Low Power Mode" on (the default), the only periodic work, idle-disk I/O sampling, pauses while Low Power Mode is on. Everything else is event-driven and keeps working. Turn the setting off to keep all features running in Low Power Mode.

How to measure:

```bash
footprint $(pgrep -x UMounter)
top -l 4 -s 15 -pid $(pgrep -x UMounter) -stats pid,cpu,mem,idlew,threads
UMOUNTER_DEBUG_SETTINGS_CYCLE=1 .build/debug/UMounter   # opens Settings at 5 s and closes it at 10 s; run footprint around that
UMOUNTER_DEBUG_DUMP_MENU=1 .build/debug/UMounter        # prints the menu as built on open
UMOUNTER_DEBUG_EJECT=disk6 .build/debug/UMounter        # ejects that device at launch (exercises the in-use window)
UMOUNTER_DEBUG_RECLAIM_DELAY=5                          # memory-reclaim idle delay in seconds (default 120)
```

The debug build reads its preferences from the `UMounter` domain, so `defaults write UMounter …` can set test values without touching the real app (`app.umounter.UMounter`).

## Automatic features and their cost

| Feature | Default | How it detects | Idle cost while active |
|---|---|---|---|
| Eject before sleep / display off / logout | sleep on | IOKit power and NSWorkspace notifications | none (event-driven) |
| Disk-image auto-eject (`ImageAutoEjectScheduler`) | off | Attach time, then a check at the deadline; process-exit sources while busy | one timer per deadline |
| Idle physical disks (`IdleDiskAutoEjector`) | off | I/O counters (`IOActivity`) sampled every timeout/6 (5–30 s), plus blocker scan | one sample per interval, **only while an eligible disk is mounted** |
| Disk-in-use window (`InUseWindowController`) | — | `proc_listpidspath` and process-exit sources; retries automatically when blockers quit | window exists only while shown |

Note: Spotlight indexing a newly connected drive reads it continuously (verified: about 12 MB/s on a FAT32 USB stick through FSKit). The idle timer correctly waits for indexing to finish.

