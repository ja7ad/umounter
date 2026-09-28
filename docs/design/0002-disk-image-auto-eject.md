# 0002 — Auto-eject disk images (DMG / ISO) after a timeout

| | |
|---|---|
| **Status** | Implemented (2026-10-14): `ImageAutoEjectScheduler` in UMounterCore |
| **Date** | 2026-10-14 |
| **Depends on** | [0001 proposal](0001-umounter-proposal.md) §5.5 (per-device policies), DiskKit M0 |

## 1. Problem

Installer DMGs and ISOs stay mounted for hours or days after the app inside has been copied to `/Applications`. They clutter Finder's sidebar and the desktop. They also inflate the "Eject All" count, and a DMG stored *on* an external disk keeps that disk from ejecting. Nobody unmounts them on purpose; people forget.

**Feature:** an option to automatically eject disk images after a timeout. It should be safe (never while in use), cheap (no polling), and reversible (one click to bring the image back).

## 2. Verified facts (macOS 27, Apple silicon)

Checked on this machine with an `.iso` and a `.dmg` mounted:

| Question | Answer | How it was checked |
|---|---|---|
| How do we know a disk is an image? | DiskArbitration reports protocol `Virtual Interface`. In the IORegistry there are **two driver paths**: images opened in Finder (DiskImages2) sit under `AppleDiskImageDevice`, and images attached with `hdiutil attach` sit under `IOHDIXHDDriveOutKernel` → `IODiskImageBlockStorageDeviceOutKernel`. | `ioreg -r -c AppleDiskImageDevice`, `ioreg -r -c IOHDIXHDDriveOutKernel` |
| Which file backs it? | Finder path: `"DiskImageURL"` (URL string) on `AppleDiskImageDevice`. `hdiutil` path: `"image-path"` (NUL-terminated bytes) on `IOHDIXHDDriveOutKernel`, also exposed as `"Protocol Characteristics"` → `"Virtual Interface Location Path"`. DiskKit checks all three. **No need to spawn `hdiutil info -plist`.** | `ioreg`, cross-checked with `hdiutil info`. Found because the end-to-end test DMG (attached with `hdiutil`) was not recognized at first. |
| ISO vs DMG? | Both go through the same driver. Use the file extension of `DiskImageURL` (`.dmg`, `.iso`, `.cdr`, `.sparseimage`, `.sparsebundle`) and `MediaWritable` to tell them apart. | `hdiutil info` lists both as `read-only disk image` |
| When was it attached? | The `ctime` of `/dev/diskN` equals attach time (birth time is the epoch). This covers images attached *before* UMounter launched. | `stat -f %Sc /dev/disk4` = 21:08:42; `disk0` = boot time |
| Nested images? | They happen in real life. On this Mac, `disk5` is a `.dmg` whose file lives on the mounted `.iso` (`disk4`). | `DiskImageURL` = `file:///Volumes/Jettison%201.9.7/…dmg` |
| Unmount vs detach | Unmounting a volume leaves `/dev/diskN` attached. Auto-eject must use `ejectSafely(.., mode: .eject)`, which unmounts the whole disk and then `DADiskEject`s it. That detaches the image just like `hdiutil detach`. | DiskKit M0 tests |

DiskKit now exposes the backing file as **`DiskInfo.diskImageURL`**, computed during the same IORegistry walk that finds `physicalRootBSDName`.

## 3. User-facing behaviour

### 3.1 Settings → Disks → "Disk Images"

```
[x] Automatically eject disk images
      Eject  [ 10 minutes ▾ ]  after  ( ) mounting   (•) they're no longer in use
      [x] Only read-only images (installers, ISOs)
      [ ] Never while the image's app is running
[x] After ejecting, offer to move installer images to the Trash
Exceptions: [ image list… ]  (+ “Keep Mounted” from the menu adds one)
```

- **Timeouts:** 1, 5, 10, 30, or 60 minutes, or Custom. Default: **off**, then 10 min "no longer in use" once enabled.
- **Modes:**
  - *after mounting*: a fixed deadline of `attachTime + timeout`. Simple and predictable.
  - *after no longer in use* (recommended): the clock starts when the image becomes **idle** (§4.2) and restarts whenever it becomes busy again.
- **Read-only only** (default on). Writable images (sparse bundles used as encrypted work volumes, VM disks) are excluded unless the user opts in.
- **Encrypted images** are always excluded by default, because remounting them needs a password.

### 3.2 Menu

```
Eject ▸
   Jettison 1.9.7 — ISO · ejects in 4 min         ⏏
      Keep Mounted   (adds to exceptions)
      Eject Now
      Show Image File in Finder
```

- The countdown is shown only for images with an active deadline. It's rendered with `Text(timerInterval:)` / `Text(.relative)`, so SwiftUI updates it without our own timer.

### 3.3 After auto-eject

- **Notification:** *“Jettison 1.9.7” was ejected automatically* with the actions **Remount** and **Move to Trash**.
  - **Remount** = `NSWorkspace.shared.open(diskImageURL)` (DiskImageMounter reattaches it). This works because the file still exists.
  - **Move to Trash** (only when the file is in `~/Downloads` and the setting is on) = `NSWorkspace.shared.recycle([url])`. It is never automatic, and the Trash is recoverable.
- Auto-ejects are recorded in history (see proposal §5.8).

### 3.4 Installer hint (optional; a suggestion, not automatic)

When an image looks like an installer and its app is now installed, show it earlier. The image looks like an installer when its root contains `X.app`, often next to an `Applications` symlink. The app counts as installed when `/Applications/X.app` exists with an mtime after the image's attach time. In that case the menu row reads "*Installed — eject now?*", and with "after no longer in use" mode the deadline can be shortened to 1 minute. To detect the copy without polling, watch `/Applications` with a `DispatchSource.makeFileSystemObjectSource(.write)` **only while an installer image is mounted**.

## 4. Design

### 4.1 Classification

```swift
extension DiskInfo {
    var isDiskImage: Bool { diskImageURL != nil }          // set from AppleDiskImageDevice ancestor
    var imageFormat: ImageFormat { … }                     // from diskImageURL.pathExtension
}
```

The policy applies to **devices** (physical roots), so all volumes of one image are handled together.

### 4.2 "Idle" definition

An image is *idle* when **all** of these hold:
1. No process holds files on any of its mounted volumes: `proc_listpidspath(…, PATH_IS_VOLUME | EXCLUDE_EVTONLY)`. This already ignores Finder and Spotlight watchers that don't block an unmount.
2. No **process is running from it**. A running process holds its mapped executable, so check 1 also covers this. It is called out because "the app inside is running from the DMG" is the classic installer mistake.
3. No image nested on it is still mounted (§4.4).

Checks happen **only at deadlines**, never continuously.

### 4.3 Scheduler (low power)

```
            DiskStore snapshot changes (DiskArbitration events)
                              │
                              ▼
   ┌───────────── ImageAutoEjectScheduler (actor) ──────────────┐
   │  state per image: attachedAt, idleSince?, deadline, tries  │
   │  ONE sleeping Task → earliest deadline (with tolerance)    │
   └───────────────────────────────┬────────────────────────────┘
                                   │ deadline reached
                                   ▼
              idle check (§4.2) ── busy ──▶ push deadline: mode "after mounting" → +1 min backoff (max 5);
                   │                        mode "no longer in use" → idleSince = nil, restart on next check
                   │ idle
                   ▼
         DiskStore.eject(device, mode: .eject)  ──▶ notification + history
```

- There is exactly **one** pending wakeup for all images. It sleeps with `clock.sleep(until: deadline, tolerance: .seconds(30))`, so the kernel can coalesce it with other timers. At idle there are zero wakeups unless an image is mounted and the feature is on.
- Every snapshot change triggers a reschedule. This covers an image that appeared, was unplugged, or was ejected by hand.
- "No longer in use" mode without polling: at each deadline, if the image is busy, find the blocking PIDs and wait for them with `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)`. When the last one exits, set `idleSince = now` and `deadline = now + timeout`. Fall back to a capped re-check (5 min) for PIDs we cannot observe.
- The clock is injected (`any Clock<Duration>`), so tests run the whole state machine instantly with a test clock.
- Sleep and wake: deadlines use `ContinuousClock`, which keeps counting while asleep. On wake, overdue images are checked once, after the remount delay. They never fire during a dark wake.

### 4.4 Ordering and nesting

When an image's backing file lives on another mounted image (or on an external disk), eject the **inner** image first. With the verified example: the inner `.dmg` (disk5) is ejected before the `.iso` (disk4). If the inner image is excluded or busy, the outer one is treated as busy too. This is the first concrete use of the dependency graph from the proposal (§5.3).

### 4.5 Where the code goes

| Piece | Location |
|---|---|
| `diskImageURL`, attach time (`/dev/diskN` ctime) | **DiskKit** (`diskImageURL` done; `attachedAt` to add) |
| `ImageAutoEjectPolicy` (settings, Codable) + `ImageAutoEjectScheduler` (actor, injected clock) | **UMounterCore** |
| Countdown in the Eject menu, "Keep Mounted", Settings section | **UMounter** app |
| Notification actions (Remount / Move to Trash) | **UMounter** app, `UNUserNotificationCenter` |

### 4.6 Tests

- Classification: fixtures for DMG, ISO, writable sparse bundle, encrypted image, and a nested image.
- Scheduler with a test clock: mount → deadline → idle → ejected; busy → backoff → idle → ejected; manual eject cancels the deadline; unplugging cancels it; changing the timeout reschedules it; an exception is never ejected.
- Integration (RAM-disk/`hdiutil create` harness from DiskKit): a real read-only DMG is auto-ejected after a 2 s timeout, and not ejected while a test process holds a file open on it.

## 5. Safety rules

1. Never force-unmount. If the image is busy, wait or report; never `kDADiskUnmountOptionForce`.
2. Never delete. "Move to Trash" is an explicit notification action, limited to `~/Downloads`.
3. Writable and encrypted images are opt-in only.
4. The feature is off by default, and the first time it is enabled UMounter explains what it does.

## 6. Open questions

1. Should "after mounting" mode exist at all, or is "no longer in use" the only mode? It is safer and covers the same need. Proposal: ship both, and make *no longer in use* the default.
2. Should images opened by *other apps* (e.g. Xcode simulator runtimes, which mount outside `/Volumes`) be eligible? Proposal: no. Only images that are visible in `/Volumes` are eligible, the same rule as "Eject All".
3. Should the timeout be per image format (e.g. ISO 60 min, DMG 10 min)? Proposal: one global timeout in v1, and per-image exceptions only.
