# UMounter — Design Proposal

| | |
|---|---|
| **Status** | Draft / Proposal |
| **Date** | 2026-10-14 |
| **Target** | macOS 14 Sonoma+ (feature-gated extras on macOS 26 Tahoe / 27), Apple silicon first, Universal build |
| **Language** | Swift 6 (strict concurrency), SwiftUI + AppKit where needed |
| **Reference product** | [Jettison 1.9.7](https://www.stclairsoft.com/Jettison/) by St. Clair Software (screenshots in [`jettison_screenshot/`](jettison_screenshot/)) |

---

## 1. Summary

UMounter is a menu bar utility that makes removing storage from a Mac **provably safe**, not just "probably ejected". It matches Jettison's features (eject everything, eject on sleep, remount on wake, filters, hotkeys, notifications). It also adds a safety model built on a few lesser-known public Apple APIs:

1. **Flush, then verify, then unmount.** Force a full hardware cache flush (`sync_volume_np(…, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)`) before asking DiskArbitration to unmount. Report success only after DiskArbitration confirms it.
2. **Know who blocks the eject before trying.** `proc_listpidspath(…, PROC_LISTPIDSPATH_PATH_IS_VOLUME, …)` lists every process with files open on a volume, so UMounter can show "Preview and Spotlight are using *Photos SSD*" instead of a generic "disk in use" error.
3. **"Eject when safe" (deferred ejection).** UMounter queues the ejection and runs it automatically once writes go quiet and blockers close. It then plays a sound or posts a notification. This replaces Jettison's "could not eject" dialog with a promise.
4. **Dependency-aware ejection graph.** Disk images stored *on* an external disk, APFS volume groups, multi-partition disks, and every disk behind one dock are ejected in the correct order. Independent devices are ejected in parallel.
5. **Read-only and quiet-unmount policies.** Some devices (camera SD cards, archive disks) can be mounted read-only, or unmounted automatically after N minutes of no writes. Pulling them out is then *always* safe.
6. **Improper-removal detector.** UMounter records when a mounted volume disappears without an unmount. When the disk comes back, it offers to verify the file system.

Every feature is event-driven: no polling timers while idle, a target of **≈0 % CPU and < 25 MB RSS** at rest.

---

## 2. Research: Jettison (the reference)

### 2.1 Features visible in the screenshots

| Area | Jettison feature |
|---|---|
| **Menu bar icon** | Eject glyph with a **badge showing how many disks will be ejected** ("⏏ 2"). The outlined icon means auto-eject on sleep is off. |
| **Menu** | *Eject External Disks*, *Eject and Sleep*, *Sleep*, *Remount Ejected Disks* (disabled when there's nothing to remount), *Eject ▸* (per disk), *Mount ▸* (per unmounted disk), *Settings…*, *About*, *Check for Update…*, *Quit*. ⌘-click opens the disk in Finder ("Mount and Open"). |
| **General** | Start at login; show menu bar icon; show count badge; auto-eject **before system sleep**, **after display turns off**, **before logout/restart/shutdown**. |
| **What to Eject** | Category filters: Hard disks & SSDs, DVDs/CDs, Disk images, Network drives, SD cards; **"Unmount instead of ejecting"** (keeps the device attached so it can be remounted without replugging). |
| **Notification** | Progress window while ejecting and while remounting; system notifications; success and failure sounds (selectable system sounds). |
| **Hotkeys** | Global shortcuts for *Eject external disks*, *Eject and sleep*, *Remount ejected disks*. |
| **Options** | Remount drives N seconds after wake; per-disk lists: *Also eject these disks*, *Don't eject these disks*, *Don't remount these disks*. |

### 2.2 Behaviour learned from the release notes and FAQ

These are the hard problems Jettison has fought over about 10 years of releases. UMounter has to solve them from day one.

| Problem | Jettison's approach | Lesson for UMounter |
|---|---|---|
| Apps keep files open (Music, Photos, Spotlight `mds_stores`, `corespotlightd`, `photoanalysisd`, `AMPDevicesAgent`, `PhotosReliveWidget`, QuickLook) | A hard-coded list of apps and processes to quit before sleep and relaunch after wake. Hidden `defaults` keys: `appsToQuit`, `processesToTerminate`, `leaveAppsRunning`, `terminateSystemProcesses`. | Discover blockers **dynamically** per volume (`proc_listpidspath`) instead of maintaining a hard-coded list. Show them in the UI. Ask before killing. Keep a *small* curated list only for known system daemons. |
| Root-owned processes can't be signalled; non-admin users and SD cards need privileges (Sequoia 15.4 "Higher privileges required") | A privileged helper in `/Library/PrivilegedHelperTools` (the older SMJobBless style). | Use **`SMAppService.daemon`** (macOS 13+) with an XPC-only, minimal-surface helper that is **optional** and only installed when the user first needs it. |
| Sleep notifications arrive late; dark wakes | A "hybrid" of the old and new power APIs (1.8.1). | Use `IORegisterForSystemPower` as the primary channel, plus NSWorkspace notifications as a backstop. Treat a wake as "full" only once the screens are awake. |
| Quick wake → sleep races; remount races when the system is busy (1.8.7, 1.9.5) | Patches over time. | Model eject/remount as a **single serial state machine** (actor) with cancellation, so races cannot happen by construction. |
| "Disk ejected improperly" caused by Power Nap, Time Machine, `tcpkeepalive`, standby | FAQ tells users to run `pmset`. | **Diagnose and explain in the app**: read `pmset -g` settings and assertions and present a one-click "Sleep hygiene" checklist (explain, never silently change system settings). |
| Volume groups (APFS System + Data), encrypted volumes, keychain passwords | Added over time (1.9.3, 1.8.8). | Build an explicit **disk graph** from DiskArbitration and IORegistry from day one. |
| Full Disk Access needed in some cases (1.9) | Requests FDA. | Request it **only** when a specific feature needs it. Explain why. |
| Hides system images (cryptexes, simulator runtimes, update volumes) | Filter list. | Filter on structured properties (`DeviceInternal`, `MediaWhole`, mount flags like `MNT_DONTBROWSE`, `nobrowse`, known paths) rather than names. |

**Jettison's gaps (opportunities):** No live "is it safe yet?" state. No deferred ejection. No dependency ordering. No per-device policies beyond include/exclude lists. No read-only mounting. No dock/hub grouping. No Shortcuts/App Intents, no CLI, no Control Center control. Errors are dialogs, not actions. Its configuration hides in `defaults write` keys.

---

## 3. Research: Apple platform APIs

All of the APIs below are **public** (headers checked against the macOS 27.0 SDK unless noted otherwise).

### 3.1 DiskArbitration (`DiskArbitration.framework`): the core

| API | Use in UMounter |
|---|---|
| `DASessionCreate` + **`DASessionSetDispatchQueue`** | A single session on a private serial queue. Purely callback-driven, so no polling is needed. |
| `DARegisterDiskAppearedCallback` / `…DisappearedCallback` / `…DescriptionChangedCallback` (watch `kDADiskDescriptionWatchVolumePath`, `…VolumeName`) | Live model of every disk and volume. Mount and unmount show up as `VolumePath` changes. |
| `DARegisterDiskMountApprovalCallback` | Policy hook: veto auto-mount of a device so UMounter can remount it **read-only** (`DADiskMountWithArguments(disk, nil, 0, cb, ctx, ["rdonly"])`) or keep it unmounted ("don't remount"). |
| `DARegisterDiskUnmountApprovalCallback` / `DARegisterDiskEjectApprovalCallback` | **Guard mode** (opt-in): return a `DADissenter` to warn when *another* app (for example Finder) tries to eject a disk that is in the middle of a protected operation. Use this rarely and transparently. |
| `DADiskUnmount(disk, kDADiskUnmountOptionWhole, …)` | Unmount every volume on a physical disk atomically. The callback gives a `DADissenter` with a status (`kDAReturnBusy`, `kDAReturnNotPrivileged`, …) and a message. |
| `kDADiskUnmountOptionForce` | Only behind an explicit, scary confirmation. Never automatic. |
| `DADiskEject` | Eject after unmount. For USB/Thunderbolt mass storage this sends SCSI *START STOP UNIT* (eject), so drives spin down and the device leaves the bus. |
| `DADiskMount` / `DADiskMountWithArguments` (`kDADiskMountOptionWhole`) | Remount. DiskArbitration runs `fsck` automatically when a volume is dirty. |
| `DADiskCopyWholeDisk`, `DADiskCopyIOMedia` | Walk from a volume to its physical device and to the IORegistry. |
| Description keys | `VolumeNetwork`, `VolumeKind`, `MediaEjectable`, `MediaRemovable`, `MediaWhole`, `MediaEncrypted`, `DeviceInternal`, `DeviceProtocol` (USB / Thunderbolt / SATA / Virtual Interface / SD), `DeviceModel/Vendor`, `BusPath`, `VolumeUUID`, `MediaUUID`. |
| **New:** `kDADiskDescriptionRepairRunningKey` (macOS **26.0**) | Do not eject while `fsck`/repair is running. Show "Repairing…" in the UI. |
| **New:** `kDADiskDescriptionFSKitPrefix` (macOS 14.4) | Volumes served by **FSKit** user-space file systems (exFAT/FAT moved there in recent releases, plus third-party ones). These may have different flush and unmount latency, so UMounter should account for them in timeouts. |

> **Key point:** never shell out to `diskutil` for the normal path. Calling DiskArbitration directly is faster, gives structured errors, and avoids spawning processes, which matters for power use.

### 3.2 Flushing and integrity (`unistd.h`, `fcntl.h`)

| API | Use |
|---|---|
| `sync_volume_np(path, SYNC_VOLUME_FULLSYNC \| SYNC_VOLUME_WAIT)` (10.8+) | Flushes **data and metadata to the platter / NAND**, not just to the drive's cache. Run this right before unmounting to shrink the risk window, and also run it on "Flush now". |
| `fsync_volume_np(fd, flags)` | Same, through an open file descriptor. |
| `fcntl(fd, F_FULLFSYNC)` | Per-file full flush (used by the "Copy-safe" helper; see §5.9). |
| `F_BARRIERFSYNC` | Cheaper ordering barrier. Not enough for removal, so it is noted here and not used. |

### 3.3 Who is using the volume? (`libproc.h`)

| API | Use |
|---|---|
| `proc_listpidspath(PROC_ALL_PIDS, 0, mountPath, PROC_LISTPIDSPATH_PATH_IS_VOLUME \| PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, buf, size)` | Returns every PID with an open file, cwd, or mapped file on the volume. `EXCLUDE_EVTONLY` skips `O_EVTONLY` watchers (Finder, FSEvents clients) that do **not** block an unmount. This is the same approach `lsof +f` / Finder's "in use by" use, without spawning a process. |
| `proc_pidpath`, `proc_name`, `NSRunningApplication(processIdentifier:)` | Turn PIDs into user-facing app names and icons. |
| `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` | (Optional, on demand) show the *exact file* that is open: "Preview has *IMG_0042.HEIC* open". |

Limitations: without root, processes belonging to other users are not visible. The optional helper fills that gap.

### 3.4 Power and session events

| API | Use |
|---|---|
| `IORegisterForSystemPower` → `kIOMessageCanSystemSleep` | Idle sleep **can be vetoed** (`IOCancelPowerChange`) if a protected write is in progress and the user opted in. |
| `kIOMessageSystemWillSleep` | Forced sleep (lid close, menu Sleep). We **must** call `IOAllowPowerChange` within about 30 s. Run the eject pipeline with a hard deadline, then acknowledge. |
| `kIOMessageSystemWillPowerOn` / `kIOMessageSystemHasPoweredOn` | Start of wake. |
| `NSWorkspace.willSleepNotification`, `.didWakeNotification`, `.screensDidSleepNotification`, `.screensDidWakeNotification`, `.willPowerOffNotification`, `.sessionDidResignActiveNotification` (fast user switching) | Backstop channel. Used for display-off ejection, log-out/shutdown ejection, and user switching. |
| Distributed notifications `com.apple.screenIsLocked` / `…Unlocked` | Optional "eject on lock" trigger. |
| `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` | Hold off *idle* sleep while a deferred ejection is waiting for a copy to finish. Release it immediately afterwards. |
| `IOPSNotificationCreateRunLoopSource` / `IOPSCopyPowerSourcesInfo` | Power-source change trigger ("unplugged from the desk"). |
| Dark wake | The public way to know about a full wake is `screensDidWake` / `didWake`. **Remount only on full user wake**, never during Power Nap/dark wake (the cause of Jettison's "ejected improperly" FAQ entries). The private `IOPMConnection` API is **not used**. |

### 3.5 IOKit registry (topology, speed, statistics)

| Data | Source | Use |
|---|---|---|
| Physical topology | Walk parents from `DADiskCopyIOMedia` up to `IOUSBHostDevice` / `IOThunderboltPort` / `AppleUSBXHCIPort` (`locationID`, `"USB Product Name"`, `"Built-In"`) | **Group disks by dock/hub** → "Eject everything on *CalDigit TS4*". |
| Link speed | `IOUSBHostDevice` `"Device Speed"` / `"USBSpeed"`, Thunderbolt link properties | Warn: "*Samsung T7* is connected at USB 2 (480 Mb/s): check the cable". |
| I/O counters | `IOBlockStorageDriver` → `kIOBlockStorageDriverStatisticsKey` (`"Bytes (Write)"`, `"Operations (Write)"`, …) | Cheap **write-activity sampling** for "Eject when safe", sampled only while a deferred ejection is pending or the popover is open. |
| Disk image backing file | `"DiskImageURL"` on `AppleDiskImageDevice` (Finder-opened images) or `"image-path"` on `IOHDIXHDDriveOutKernel` (`hdiutil`-attached images). Both verified on macOS 27 and exposed as `DiskInfo.diskImageURL`. | Build the **dependency graph**: an image whose backing file lives on disk X must be detached before X. |
| Matching notifications | `IOServiceAddMatchingNotification` on `IOMedia` with `IONotificationPortSetDispatchQueue` | Only if DiskArbitration is not enough. DiskArbitration already covers it in most cases. |

### 3.6 Other system services

| Topic | API / approach |
|---|---|
| Time Machine | `tmutil destinationinfo -X` / `tmutil status -X` (plist output, run on demand only). Detect "backup running to this disk", then offer *Stop backup & eject* (`tmutil stopbackup`). |
| Spotlight | Spotlight (`mds_stores`, `corespotlightd`) is a frequent blocker. Show it as a blocker and retry with backoff, because it usually releases within seconds after `sync`. Offer a per-disk "Never index" toggle (writes `.metadata_never_index` or uses `mdutil -i off` through the helper). |
| Network volumes | DiskArbitration reports them (`VolumeNetwork`). Unmount them through `DADiskUnmount` as well. Remount them through `NetFSMountURLAsync` (NetFS.framework) using the saved URL and Keychain credentials. |
| Encrypted volumes | Remount relies on DiskArbitration plus the Keychain-stored password. If it is locked, show "Unlock…" which hands off to Disk Utility/Finder. Never store passwords ourselves. |
| Login item | `SMAppService.mainApp.register()` |
| Privileged helper | `SMAppService.daemon(plistName:)` + an `NSXPCConnection` with a code-signing requirement (`setCodeSigningRequirement`, macOS 13+). |
| Global hotkeys | `RegisterEventHotKey` (Carbon, still the only no-permission global hotkey API) wrapped behind a small type, or the **KeyboardShortcuts** package. Avoid `CGEventTap` because it needs Accessibility permission and wakes the process on every key. |
| Notifications | `UserNotifications` (`UNUserNotificationCenter`) with actions such as "Show blockers" and "Retry". Mark sleep-time notifications as `.passive` and avoid them during sleep, since Jettison's FAQ shows they can wake the Mac. |
| Sounds | `NSSound(named:)` system sounds. Skip them when going to sleep, because the audio route is torn down. |
| Shortcuts / Siri / Spotlight actions | **App Intents**: `EjectAllIntent`, `EjectDiskIntent(disk: DiskEntity)`, `RemountIntent`, `IsSafeToUnplugIntent`. |
| Control Center / menu bar controls | **`ControlWidget`** (WidgetKit, **macOS 26+**): an "Eject All" button control and a "Safe to unplug" status control. |
| Desktop widget | WidgetKit widget showing connected disks and their safety state. |
| Accessory security (Apple silicon laptops) | Since macOS 13, new USB/TB accessories and SD cards need approval, and a Mac locked for more than 3 days may require unlocking before an approved accessory works again. **"Unmount instead of eject" keeps the device enumerated**, so remount after wake does not need re-approval. Make it the default for laptops. |

---

## 4. Product goals and non-goals

**Goals**
- G1: Full parity with Jettison (§2.1).
- G2: Never claim "safe" unless the flush and unmount were *confirmed* by the OS.
- G3: Turn every failure into an action ("Quit Preview", "Wait and eject", "Force").
- G4: Idle cost close to zero: no timers, no polling, no spawned processes while idle.
- G5: Scriptable: App Intents, CLI, URL scheme.

**Non-goals (v1)**
- Partitioning, formatting, or repairing disks (that is Disk Utility's job; we only *offer* verification).
- Kernel or DriverKit extensions.
- Mac App Store distribution of the full feature set (the sandbox blocks `proc_listpidspath` on other processes, the helper, and signalling apps). A reduced "Lite" MAS build is possible later.

---

## 5. Feature specification

### 5.1 Menu bar (Jettison parity plus extras)

```
⏏ 2                         ← badge = disks that "Eject All" would act on; tint = state
──────────────────────────────
Eject All External Disks        ⌃⌥⌘E
Eject All and Sleep             ⌃⌥⌘S
Sleep
Remount Ejected Disks           ⌃⌥⌘R   (disabled if nothing to remount)
──────────────────────────────
● Photos SSD    1.2 TB free · USB 10 Gb/s      ⏏   ← green: idle & flushed
◐ Backup HDD    Time Machine backing up…       ⏏   ← amber: writing
● Card (SD)     read-only                      ⏏
  └ in use by Preview, Spotlight   [Quit Preview] [Eject when safe]
──────────────────────────────
Dock: CalDigit TS4 (3 disks)    Eject Dock ⏏
Mount ▸  (unmounted / previously ejected volumes)
──────────────────────────────
Settings…   ·   About   ·   Check for Updates…   ·   Quit
```

- Implementation: `MenuBarExtra` with `.menuBarExtraStyle(.window)` for the rich list. If the classic `NSMenu` feel is preferred, use an `NSStatusItem` + `NSMenu` that is built lazily in `menuNeedsUpdate(_:)`.
- ⌥-click shows details (BSD name, file system, UUID, bus path). ⌘-click on a disk row opens it in Finder (Jettison parity).
- Icon states: **outline** = auto-eject disabled; **badge** = count; **amber dot** = a deferred ejection is pending; **red** = the last operation failed.

### 5.2 Ejection pipeline (the core novelty)

Every eject request, whether manual, hotkey, sleep, or intent, goes through one pipeline:

```
 Resolve ─▶ Plan ─▶ Pre-flight ─▶ Quiesce ─▶ Flush ─▶ Unmount ─▶ Eject/Park ─▶ Verify ─▶ Report
```

1. **Resolve**: expand the target into the disk graph (volume → container → physical store → dock).
2. **Plan**: topologically sort by dependency (§5.3). Independent physical devices form parallel lanes using a `TaskGroup`. Each lane runs serially.
3. **Pre-flight** (no side effects):
   - `kDADiskDescriptionRepairRunningKey` is set → wait.
   - Time Machine is backing up to this destination → ask the user, or "wait for backup".
   - `proc_listpidspath` blockers → classify them as *user app* (can ask to quit), *known system daemon* (can retry or terminate through the helper), or *unknown*.
4. **Quiesce**: for sleep-triggered ejection, gracefully ask the blocking user apps to quit (`NSRunningApplication.terminate()`, never `forceTerminate` without consent) and remember them for relaunch.
5. **Flush**: `sync_volume_np(path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)` per mounted volume, run off the main actor with a timeout.
6. **Unmount**: `DADiskUnmount(whole, kDADiskUnmountOptionWhole)`. On `kDAReturnBusy`, re-run pre-flight and retry with **bounded exponential backoff** (0.25 s → 0.5 s → 1 s → 2 s; Spotlight usually lets go).
7. **Eject or Park**:
   - *Eject* → `DADiskEject` (the device leaves the bus and HDDs spin down).
   - *Park* (= Jettison's "unmount instead of eject") → stay unmounted and attached so it can be remounted later without replugging.
8. **Verify**: confirm through the DiskArbitration callback that `VolumePath` is gone and (for eject) that the disk disappeared. Only now does the UI say **"Safe to unplug"**.
9. **Report**: notification, sound, history entry, and an `os_log` signpost.

Each step is cancellable. The state machine lives in a single `actor EjectionCoordinator`, which removes the wake/sleep races Jettison patched in 1.8.7 and 1.9.5.

### 5.3 Dependency-aware ejection graph (novel)

Edges ("A must be ejected before B"):
- A disk image (or sparse bundle) **whose backing file is on** volume B. Found through the IORegistry image path, then `statfs` on the path to get its device.
- APFS volumes → their container (synthesized disk) → the physical store. DiskArbitration's `Whole` unmount handles a single disk; the graph handles *multi-disk* cases such as Fusion drives and RAID sets.
- A volume group (System + Data) as one unit (Jettison 1.9.3).
- Network volumes are independent, but are ejected **first** during sleep because they can stall for longer.

Result: "Eject All" never fails with "disk in use" just because a `.dmg` mounted from that disk is still attached.

### 5.4 "Eject when safe": deferred ejection (novel)

When pre-flight finds blockers, or the disk is writing, instead of failing:
- The disk row shows **"Waiting: Finder copy (2.1 GB left) · Preview"** with *Cancel* and *Force*.
- UMounter watches for:
  - blockers exiting: `NSWorkspace.didTerminateApplicationNotification` for apps, and `DispatchSource.makeProcessSource(.exit)` for daemons. This is event-driven, not polling.
  - write quiescence: `IOBlockStorageDriver` write counters sampled every 1 s **only while waiting**, until they are unchanged for a configurable window (default 3 s).
- While waiting, hold a `PreventUserIdleSystemSleep` assertion so the Mac does not idle-sleep mid-copy, and release it on completion.
- When conditions are met → run the normal pipeline → notification "*Photos SSD* is safe to unplug" + sound.

### 5.5 Device policies (per device, keyed by Media UUID / Volume UUID / serial)

| Policy | Effect |
|---|---|
| **Default** | Follows the global category filters. |
| **Never eject** | Jettison's "Don't eject these disks". |
| **Always eject** | Jettison's "Also eject these disks" (for example internal secondary drives). |
| **Don't remount** | Jettison parity. |
| **Mount read-only** (novel) | Mount-approval callback → dissent → remount with `rdonly`. For cameras, cards, and evidence or archive disks. Unplugging is always safe. |
| **Auto-eject disk images after a timeout** (novel) | DMG/ISO installers are ejected N minutes after mount or after they go idle. See [0002](0002-disk-image-auto-eject.md). |
| **Quiet-unmount after N min idle** (novel) | Park the volume automatically after N minutes with no writes, and remount it on access through the menu. For backup disks that otherwise sit mounted all day. | **Implemented 2026-10-14** as `IdleDiskAutoEjector` (SD cards, USB and external disks; I/O counters plus blocker scan).
| **Never index** | Disable Spotlight on that volume (removes the #1 blocker). |
| **Eject on lock / on power unplug / on network change** | Context triggers (§5.7). |

### 5.6 Sleep, wake, display-off, logout (Jettison parity, hardened)

- **Before system sleep**: on `kIOMessageSystemWillSleep`, run the pipeline with a **25 s deadline** (the OS allows about 30 s), then `IOAllowPowerChange` *always*, even on failure. For idle sleep (`kIOMessageCanSystemSleep`), optionally veto while a protected deferred ejection is in progress.
- **After display turns off**: `screensDidSleepNotification`, with an optional grace delay (avoids churn when the screen saver flickers).
- **Before logout / restart / shutdown**: `willPowerOffNotification`.
- **Remount after wake**: only after a *full user wake* (`screensDidWake` + session active), wait N seconds (default 5, as in Jettison), then remount *only what UMounter ejected* and is still present, excluding the "Don't remount" list. After that, relaunch the apps that were quit.
- **Dark wake / Power Nap**: never remount. Mitigates the "ejected improperly" warnings.
- **Sleep hygiene panel** (novel): reads `pmset -g` and `pmset -g assertions` on demand and explains settings that cause problems (Power Nap, `tcpkeepalive`, `standby`, apps that prevent sleep) with links to the matching System Settings pane. Read-only; never changes `pmset` silently.
- **Fast user switching**: on `sessionDidResignActive`, optionally eject (disks mounted by user A stay mounted under user B otherwise).

### 5.7 Context triggers (novel)

All of these are opt-in and event-driven:
- **Undock**: when the power source switches to battery (`IOPSNotificationCreateRunLoopSource`), *or* via a hotkey, eject every disk attached through the same dock or hub.
- **Lock screen**: `com.apple.screenIsLocked`.
- **Focus / Shortcuts automation**: exposed through App Intents. Users can build "When I leave work Wi-Fi → Eject All" in Shortcuts without UMounter needing Location permission.

### 5.8 Improper-removal detection and recovery (novel)

- If a disk *disappears* while UMounter's model still has it **mounted** (no unmount callback first), record an "Unsafe removal" event (device, time, volume, recent write activity).
- When the device reappears: DiskArbitration runs `fsck` on dirty HFS+/FAT/exFAT automatically. UMounter shows "*Card* was removed without ejecting on 14 Oct 21:03 — **Verify now**", which runs `diskutil verifyVolume` (or `fsck_apfs -n`) through the helper. The result goes into history.
- A small history view (last 100 events) helps users find the app that *keeps* blocking.

### 5.9 Quality-of-life

- **Health card per disk**: capacity, file system, encryption, protocol, **negotiated link speed with cable warnings**, SMART status where available (SATA/NVMe internal; most USB bridges do not pass it through, so it is shown as "unavailable", not "OK").
- **Rename**, **Reveal in Finder**, **Copy BSD name/UUID**.
- **CLI** `umounter` (symlink installed from inside the app bundle), which talks to the running app over XPC:
  `umounter list --json`, `umounter eject --all --wait`, `umounter blockers /Volumes/X`, `umounter park disk4`.
- **URL scheme** `umounter://eject?all=1` for launchers (Raycast, Alfred).
- **Progress HUD** (Jettison's progress window) as a small non-activating `NSPanel` that does not steal focus.

### 5.10 Settings (map of Jettison tabs → UMounter)

| UMounter tab | Contents |
|---|---|
| **General** | Launch at login · menu bar icon and badge · triggers: before sleep / display off (+delay) / logout / lock / fast user switch / power unplug |
| **Disks** | Category filters (HDD/SSD, optical, disk images, network, SD/card readers) · default action *Eject* vs *Park* · **per-device policy table** (replaces the three dropdowns) |
| **Wake** | Remount after wake (delay) · relaunch quit apps · never remount on dark wake (fixed, informational) |
| **Notifications** | Progress HUD (eject/remount) · system notifications · success/failure sounds |
| **Shortcuts** | Global hotkeys (Eject All, Eject & Sleep, Remount, Eject Dock, Toggle auto-eject) · link to Shortcuts app |
| **Advanced** | Helper install/uninstall · blocker handling (ask / auto-quit user apps / also terminate known daemons) · Spotlight · Sleep hygiene · logs export |

All settings live in `UserDefaults` with typed keys (no hidden `defaults write` features as in Jettison; advanced options are visible in the UI).

---

## 6. Architecture

```
┌───────────────────────────── UMounter.app (LSUIElement, non-sandboxed, Developer ID) ─────────────────────────────┐
│                                                                                                                    │
│  UI layer (@MainActor)          Domain (actors)                         System adapters (Sendable wrappers)       │
│  ─────────────────────          ───────────────                         ──────────────────────────────────         │
│  MenuBarExtra / NSStatusItem ──▶ DiskStore (@Observable snapshot) ◀──── DASessionClient   (DiskArbitration)        │
│  SettingsScene (lazy)           EjectionCoordinator (actor) ──────────▶ VolumeFlusher     (sync_volume_np)        │
│  ProgressHUD (NSPanel)          PolicyEngine                ──────────▶ BlockerScanner    (libproc)               │
│  Notifications                  TriggerRouter ◀──────────────────────── PowerMonitor      (IOKit pwr + NSWorkspace)│
│  App Intents / ControlWidget    HistoryStore (JSON lines)               TopologyReader    (IORegistry)            │
│  XPC CLI listener                                                       IOActivitySampler (on demand only)        │
│                                                                         HelperClient ──XPC──┐                     │
└─────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┘
                                                                                              ▼
                                         UMounterHelper (SMAppService.daemon, root, optional, ~5 XPC methods)
                                         terminate(pid:), listBlockers(volume:), verify(volume:), setIndexing(…)
```

### 6.1 Packages / targets

```
UMounter/
├─ App/                      # @main, MenuBarExtra, Settings, HUD
├─ Packages/
│  ├─ DiskKit/               # DA + IOKit + libproc wrappers (no UI, fully testable)
│  ├─ EjectEngine/           # Coordinator, graph, policies, pipeline
│  └─ UMShared/              # Codable models, XPC protocol, Intents entities
├─ Helper/                   # privileged daemon target (tiny)
├─ CLI/                      # `umounter` command (swift-argument-parser)
├─ Widgets/                  # WidgetKit + ControlWidget (macOS 26+)
└─ Tests/
```

### 6.2 Key types (sketch)

```swift
struct DiskID: Hashable, Sendable, Codable { let mediaUUID: UUID?; let bsdName: String }

struct DiskSnapshot: Sendable, Identifiable {
    let id: DiskID
    var name: String
    var kind: Kind            // .physical, .apfsContainer, .volume, .image, .network
    var mountPoint: URL?
    var isInternal: Bool
    var protocolName: String? // "USB", "Thunderbolt", "Secure Digital"
    var dockID: String?       // topology grouping
    var dependsOn: [DiskID]
    var safety: Safety        // .flushedIdle, .writing, .blocked([Blocker]), .repairing
}

actor EjectionCoordinator {
    func eject(_ targets: [DiskID], reason: Reason, mode: Mode, deadline: ContinuousClock.Instant?) async -> EjectReport
    func ejectWhenSafe(_ target: DiskID) -> PendingEjection   // cancellable handle
    func remountParked(excluding: Set<DiskID>) async -> RemountReport
}
```

### 6.3 Bridging the C callbacks safely (Swift 6)

DiskArbitration and IOKit callbacks are C function pointers with a `void *context`. Recommended pattern:

```swift
final class DASessionClient: @unchecked Sendable {            // confined to `queue`
    private let queue = DispatchQueue(label: "umounter.da", qos: .utility)
    private let session = DASessionCreate(kCFAllocatorDefault)!
    let events: AsyncStream<DiskEvent>
    private let continuation: AsyncStream<DiskEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            Unmanaged<DASessionClient>.fromOpaque(ctx!).takeUnretainedValue().handleAppeared(disk)
        }, ctx)
        // … disappeared / description changed
        DASessionSetDispatchQueue(session, queue)
    }

    func unmount(_ disk: DADisk, options: DADiskUnmountOptions) async throws {
        try await withCheckedThrowingContinuation { cont in
            let box = Unmanaged.passRetained(ContinuationBox(cont)).toOpaque()
            DADiskUnmount(disk, options, { _, dissenter, ctx in
                let box = Unmanaged<ContinuationBox>.fromOpaque(ctx!).takeRetainedValue()
                box.resume(dissenter.map(DiskError.init) )
            }, box)
        }
    }
}
```

- Exactly **one** DiskArbitration session per process.
- Callbacks → `AsyncStream` → consumed by actors. The UI observes an `@Observable` snapshot that is updated on the main actor with coalescing.

---

## 7. Low power and resource budget

### 7.1 Budget

| Metric | Target (idle) | Target (during eject) |
|---|---|---|
| CPU | 0 % (no wakeups) | short bursts |
| Wakeups/s (`powermetrics`/Activity Monitor) | < 0.1 | — |
| Memory (`footprint`) | < 25 MB | < 40 MB |
| Threads | ≤ 4 | — |
| Child processes | 0 | 0 (except on-demand `tmutil`, `pmset`) |
| Launch to menu ready | < 150 ms | — |

### 7.2 Rules that achieve this

1. **Event-driven only.** DiskArbitration callbacks on a dispatch queue, IOKit power notifications, NSWorkspace notifications, `DispatchSource` for process exit. **No `Timer`, no polling loops** while idle. The only sampler (`IOActivitySampler`) runs *only* while a deferred ejection is pending or the popover is visible, and uses `DispatchSourceTimer` with **`leeway`** (≥ 10 %) so the kernel can coalesce wakeups.
2. **QoS discipline.** Background work at `.utility`/`.background`. User-initiated ejections at `.userInitiated`. Never block the main thread with `sync_volume_np` or `proc_listpidspath`.
3. **Lazy everything.** Build the settings window, the history store, the helper connection, the topology walk, and SF Symbol images on first use. Release the settings window on close (`Window` scene with no restoration).
4. **No process spawning in hot paths.** Use DiskArbitration, libproc, and IOKit directly instead of `diskutil`, `lsof`, or `ioreg`. Spawn `tmutil`/`pmset` only on demand.
5. **App Nap friendly.** Do not disable App Nap globally. Use `ProcessInfo.performActivity(options: .userInitiated)` only around an active ejection.
6. **Coalesce UI updates.** DiskArbitration can send bursts (an APFS container appearing means 5–10 callbacks). Debounce snapshot publication by about 50 ms on the main actor.
7. **Small binary.** No Electron or web views. SwiftUI plus a few AppKit bits. Dead-strip. Keep third-party dependencies to Sparkle, KeyboardShortcuts (optional), and swift-argument-parser (CLI only).
8. **Widgets and controls** read a tiny shared snapshot (App Group container) and refresh via `WidgetCenter.reloadTimelines` / `ControlCenter.shared.reloadControls` **only on change**. They never refresh on a schedule.

### 7.2.1 Measured (2026-10-14)

Idle **13 MB** footprint, 0% CPU, 0 wakeups, 3 threads, after replacing SwiftUI `MenuBarExtra` with an AppKit `NSStatusItem` (the SwiftUI menu cost about 35 MB). Details are in `App/README.md`.

### 7.3 How to measure (put this in CI and the PR checklist)

- Xcode → Debug navigator → **Energy Impact** gauge during a typical session.
- **Instruments**: *Time Profiler*, *Allocations*, *Leaks*, *Energy Log*, *os_signpost* (Points of Interest) for each pipeline step.
- `sudo powermetrics --samplers tasks --show-process-energy -i 5000 | grep UMounter`
- `footprint -p UMounter`, `vmmap --summary`
- `log stream --predicate 'subsystem == "app.umounter"' --level debug`
- Use `XCTClockMetric`, `XCTMemoryMetric`, and `XCTCPUMetric` performance tests for snapshot building with 50 simulated disks.

---

## 8. Developer experience tips

1. **Swift 6 language mode + strict concurrency from day one.** Wrap every C API in a small `Sendable` adapter that is confined to one queue. Expose `async` functions and `AsyncStream`s. Domain code should never see a C pointer.
2. **Protocol-first adapters for testability.** Define `protocol DiskArbitrating`, `BlockerScanning`, `Flushing`, `PowerEventSource`. Ship fakes, so the whole pipeline (including sleep with a 25 s deadline and busy/retry loops) is unit-tested with **Swift Testing** (`@Test`, parameterized tests) and a `TestClock` (swift-clocks or a custom `Clock`) without real disks.
3. **Real-disk test harness without hardware.** Script RAM disks and disk images: `hdiutil attach -nomount ram://2097152`, `diskutil eraseVolume APFS T /dev/diskN`, plus `hdiutil create -size 200m -fs ExFAT`. Integration tests can then mount, open a file to create a blocker, attempt an eject, and assert on the dissenter, all in CI on macOS runners.
4. **Structured logging.** One `Logger(subsystem: "app.umounter", category: …)` per component. Use `OSSignposter` intervals around each pipeline step so Instruments shows a timeline of an "Eject All". A "Copy diagnostics" button exports `OSLogStore` entries for the last hour.
5. **Typed errors.** Map `DADissenterGetStatus` codes (`kDAReturnBusy`, `kDAReturnNotPrivileged`, `kDAReturnNotPermitted`, `kDAReturnExclusiveAccess`, …) into an `enum EjectFailure: Error` with user-facing recovery suggestions. Unit-test the mapping.
6. **Preview-driven UI.** SwiftUI `#Preview`s fed with fixture `DiskSnapshot`s (writing, blocked, repairing, network, dock group) so the UI can be built without plugging anything in.
7. **Tooling.** Use `swift-format` (or SwiftLint) in a pre-commit hook, an `.xcconfig`-based build settings file, XcodeGen or Tuist (or a plain SPM-centred workspace), and a `Makefile` with `make test`, `make energy`, `make notarize`.
8. **Signing and distribution.** Developer ID + Hardened Runtime + notarization (`xcrun notarytool`), Sparkle 2 with EdDSA for updates, and DMG built by `create-dmg`. The helper is embedded at `Contents/Library/LaunchDaemons/` and registered through `SMAppService`, and its XPC listener validates the client's code-signing requirement.
9. **Entitlements and permissions minimalism.** No Accessibility or Input Monitoring (Carbon hotkeys need neither). Request Full Disk Access only if a user hits the case that needs it, with an in-app explanation. Document every permission in `docs/design/permissions.md`.
10. **Debug menu** (only in DEBUG builds): simulate sleep and wake events, inject fake blockers, dump the disk graph as Graphviz.

---

## 9. Security and safety principles

- **Never force by default.** `kDADiskUnmountOptionForce` and `forceTerminate` are always explicit, per action, and labelled with consequences.
- **Never silently change system settings** (`pmset`, Spotlight). Explain them and deep-link to System Settings, or apply changes only after explicit consent through the helper.
- **Least privilege helper**: about 5 narrowly typed XPC methods, input validated (PIDs must currently hold files on the named volume, and paths must be under `/Volumes` or be a DiskArbitration-known mount point), plus client code-signing check. The helper can be uninstalled from Settings.
- **No passwords stored by UMounter.** Encrypted volumes rely on the system Keychain and DiskArbitration.
- **Privacy**: no analytics by default. History stays local.

---

## 10. Milestones

| Milestone | Scope |
|---|---|
| **M0 — Spike (1 wk)** | DiskKit: DiskArbitration session → `AsyncStream`; list disks; unmount/eject one disk; `proc_listpidspath` blockers. Measure idle energy. |
| **M1 — Parity core** | Menu (Eject All, per-disk Eject/Mount, Remount), category filters, Park vs Eject, notifications and sounds, login item, hotkeys. |
| **M2 — Sleep & wake** | Power monitor, sleep deadline pipeline, display-off, logout, full-wake remount with delay, app quit/relaunch. |
| **M3 — Safety engine** | Flush step, blocker UI with actions, retry/backoff, **Eject when safe**, dependency graph, history and improper-removal detector. |
| **M4 — Policies & topology** | Per-device policies (read-only, quiet-unmount, never-index), dock grouping, link-speed warnings, Time Machine awareness. |
| **M5 — Ecosystem** | App Intents, CLI, URL scheme, WidgetKit + ControlWidget (macOS 26+), Sparkle updates, helper via SMAppService. |
| **M6 — Polish** | Sleep hygiene panel, diagnostics export, localization, accessibility audit, performance CI. |

---

## 11. Open questions

1. ~~**Minimum OS**~~ **Decided 2026-10-14: macOS 14 Sonoma+.** Liquid Glass is used on macOS 26+ through `#available` checks, with materials as the fallback on 14–15. Sierra-era support was rejected because it would mean an AppKit-only rewrite without SwiftUI, async/await, or DiskKit as written. ControlWidget stays gated to 26+.
2. **Menu style**: classic `NSMenu` (feels native, keyboard-friendly, matches Jettison) vs a rich SwiftUI popover (room for safety states and blocker actions). Proposal: a **hybrid**, with an NSMenu for commands and a disk submenu built from custom `NSMenuItem.view`s, or a popover behind a setting.
3. **Default for laptops**: Park (unmount) vs Eject. Proposal: **Park on sleep, Eject on manual**, because Park avoids accessory re-approval and lets remount work without replugging.
4. **Commercial model**: free/open-source vs paid like Jettison ($6.95). This affects whether a Mac App Store "Lite" build is worth doing.
5. **Quiet-unmount UX**: how users get a parked volume back (menu click, Finder can't do it). Possibly show a "Mount" item for parked disks in a Finder Sync extension (extra complexity; deferred).

---

## 12. References

- Jettison product page — https://www.stclairsoft.com/Jettison/
- Jettison FAQ — https://www.stclairsoft.com/Jettison/faq.html
- Jettison release notes (blog) — https://www.stclairsoft.com/blog/category/jettison/
- Jettison 1.9.4 notes — https://www.stclairsoft.com/blog/2025/09/25/jettison-1-9-4-improves-notification-sounds-and-tahoe-support/
- Apple: Allow USB and other accessories to connect to your Mac — https://support.apple.com/102282
- Apple: `ControlWidget` — https://developer.apple.com/documentation/swiftui/controlwidget
- Apple: WidgetKit Controls — https://developer.apple.com/documentation/widgetkit/controls-collection
- Apple: DiskArbitration — https://developer.apple.com/documentation/diskarbitration
- Apple: `SMAppService` — https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple: App Intents — https://developer.apple.com/documentation/appintents
- SDK headers checked: `DiskArbitration/DADisk.h`, `DiskArbitration/DiskArbitration.h`, `DASession.h`, `libproc.h`, `unistd.h` (`sync_volume_np`), `IOKit/IOMessage.h`, `IOKit/storage/IOBlockStorageDriver.h` (macOS 27.0 SDK).
