# USB Manager - root module edition

Every time the phone gets plugged into a computer, it asks what the connection
is for: charge only, file transfer, photos, USB tethering or MIDI, and whether
USB debugging should be on *for this connection*. Pull the cable and ADB goes
back off.

This is a rework of [TigerSpirit217's USBManager](https://github.com/TigerSpirit217/USBManager)
as a plain Magisk / KernelSU / APatch module. The original hooks
`UsbDeviceManager` and `AdbService` inside system_server via LSPosed. This one
doesn't touch system_server at all, so you don't need LSPosed, Vector or any
Xposed API.

## What it does

- Prompts when a **computer** enumerates the phone (wall chargers don't trigger it)
- Per-connection USB mode + ADB, with an optional "make this my default"
- **ADB off on unplug** (on by default)
- **OTG left alone**: when the phone is the USB host nothing pops up
- **Waits for unlock**: the chooser shows up once the secure lock screen is gone
- **Game mode**: pick apps; if one is in front when you plug in, no prompt,
  just charge-only (or your default)
- Status page with live mode/ADB switching, settings, log viewer
- "Ask every time" can be turned off to just apply a default silently
- **USB guard**: unknown USB device + locked phone + no unlock in time = restart (see below)
- **Block all USB data**: charging only, both directions, survives reboots
- Connection **history** and a **trusted devices** list
- **Auto restart** when the phone hasn't been unlocked for a set time
- Optional **app cache cleanup** before any restart the module does

## Requirements

- Android 8.0+ (9+ recommended, 8.x only has the older `svc usb setFunction`)
- Magisk 20.4+, KernelSU (or KSU Next / SukiSU) or APatch
- A WebUI host for the chooser:
  - KernelSU, KSU Next, SukiSU, APatch: built in, nothing to install
  - Magisk: install **WebUI X Portable** or **KsuWebUIStandalone**. Without one,
    the module still works but applies your default config quietly instead of asking.

If the LSPosed USBManager app is still installed and active, disable it,
otherwise you'll get two prompts.

## How it works

| Original (LSPosed) | This module |
| --- | --- |
| hook `UsbDeviceManager.updateState` | read `/sys/class/udc/<sys.usb.controller>/state` (or `android_usb`, or `dumpsys usb` as a last resort) |
| capture `UsbDeviceManager`, call `setCurrentFunctions` | `svc usb setFunctions <mode>` |
| capture `AdbService`, call `setAdbEnabled` | `settings put global adb_enabled 0/1` (AdbService picks it up and handles adbd + the notification) |
| `UsbPort` status to ride out re-enumeration | Type-C partner / `power_supply/usb` presence + a short suppress window after every change |
| chooser activity in the module APK | the module's WebUI, opened with `am start` as root |
| `dumpsys window` for keyguard | `screen_locked` from `dumpsys usb`, window policy as fallback |

`bin/usbmgrd` is a small shell daemon. It sleeps on a FIFO with a 1 s timeout,
so an idle tick is a couple of builtin `read`s and no forks. `dumpsys` only runs
when something actually happens.

## USB guard

The idea: if someone gets your locked phone and plugs it into a forensic box,
the phone restarts before they get anywhere. After a restart it's back in
"before first unlock" state, where your data is still encrypted at rest.

- Arms when something **not on the trusted list** is connected **while the
  phone is locked** (secure lock screen). Both directions count: a computer,
  or a USB device plugged into the phone (keyboards, "HID brute-force" sticks...).
- Unlock within the time limit (15 s to 5 min) and it disarms. Otherwise: restart.
- **Cut data right away** (default on): the device loses USB data the
  moment the countdown starts and gets it back after you unlock.
- **Keep counting after unplug** (default on): pulling the cable doesn't
  reset anything, only unlocking does.
- **Warn on the lock screen**: notification at the start, vibration 10 s before.
- **Test mode**: does everything except the restart. Use it first.
- Never arms before the first unlock after boot. There's nothing more to
  protect then, and it rules out restart loops while plugged into the same box.
- Holds a wakelock while counting, so a sleeping phone doesn't stall the timer.

### How devices are recognised (read this before trusting)

| Device | Fingerprint | Strength |
| --- | --- | --- |
| USB device plugged into the phone, with a serial | `usb:VID:PID:SERIAL` | unique |
| USB device without a serial | `usb:VID:PID` | model |
| Computer/dock that reports a USB-PD identity | `pc:pd:VID:PID` | model |
| Any other computer | `pc:op=…:spd=…:t=…:pd=…` (port type, speed, charger type) | generic |

When the phone is the USB *device*, a computer doesn't tell it who it is.
There's no serial or key the phone could read without software on the
computer's side. So for most computers the fingerprint only describes the
*kind* of port, and trusting it trusts every computer that looks the same.
The WebUI warns about that before you trust a generic fingerprint. For
computers, the simplest habit is to unlock when you plug in; that disarms the guard anyway.

## Auto restart

Restarts the phone when it hasn't been unlocked for a while (10 minutes to
72 hours, default 18 h), so a phone that's been lost or taken sits in
"before first unlock" state instead of staying unlocked-since-boot forever.

- The clock starts when the phone locks and resets on every unlock. "Unlocked"
  means the secure lock screen is gone, the same signal the USB guard uses.
- Lock state is only checked while the screen is on (every 5 s), because
  that's the only time someone can unlock. With the screen off the daemon
  just compares timestamps.
- Never before the first unlock after boot: nothing to protect yet, and it
  means the module's own restart can't loop.
- An active phone call postpones it by 5 minutes at a time.
- In deep sleep the daemon doesn't run, but the boot clock keeps counting, so
  the restart lands on the phone's next wake-up after the deadline. On a phone
  with a network connection that's usually within minutes.

### Clear app caches before restarting

Off by default. When on, any restart the module triggers (USB guard or auto
restart) first runs `pm trim-caches`, which is Android's own cleaner and wipes
every app's cache directories. It's capped at 20 s for the guard and 60 s for
auto restart, and the restart goes ahead even if it isn't done.
`dalvik-cache` is deliberately left alone, since wiping it only makes the next
boot slow.

## Block all USB data

On the dev-dcs GKI builds ([New-GKI-Dev_DcS-Way](https://github.com/dev-dcs/New-GKI-Dev_DcS-Way),
`kernel-patches/usb-hardening`) the kernel has two switches, and the module uses them whenever they exist:

- `/proc/sys/kernel/deny_usb_gadget`: the UDC core refuses to pull up the data lines, so a
  computer never sees the phone, even when Android re-binds the gadget. Charging keeps working.
- `/proc/sys/kernel/deny_new_usb`: newly plugged USB devices never enumerate at all.
  They show up in the history as "USB device refused by the kernel". After unblocking,
  replug them.

Both are set in `post-fs-data` when the block is on, which is before init binds the
gadget, so there's no gap during boot either. The guard's "cut data right away" uses
them too. If something clears a switch, the daemon sets it again within a second.
Devices already attached when the block starts still get deauthorized the usual way.

On stock kernels, without those switches, it falls back to the userspace method:

- Computer side: the USB gadget gets detached from the controller
  (`/config/usb_gadget/*/UDC` → `none`), so the computer doesn't even see
  the locked MTP device Android shows in "charge only" mode. ADB is forced off.
- Phone-as-host side: usbcore's `authorized_default` goes to 0, so USB sticks,
  keyboards and the like enumerate (and get logged) but never get a driver.
  Hard-wired internal devices are left alone.
- Applied in `post-fs-data` and `service.sh`, so it's in place during boot.
- Charging keeps working; from a computer it can be slower.

Limits of the fallback: it's configfs/usbcore level, not the hardware
data-line switch (`UsbManager.enableUsbDataSignal`) GrapheneOS uses on
Pixels; that API needs a binder callback and isn't reachable from a shell. If
Android re-binds the gadget on its own, the daemon cuts it again within a
second and logs it. The kernel switches above close that gap.

## Files

```
/data/adb/usbmanager/settings.conf   settings (kept across updates)
/data/adb/usbmanager/dnd.list        game mode apps, one package per line
/data/adb/usbmanager/trusted.list    trusted fingerprints: fp|label|strength
/data/adb/usbmanager/history.log     last ~300 connections and what the guard did
/data/adb/usbmanager/usbmgr.log      log (rotates at 256 KB)
```

CLI, handy over `adb shell su`:

```
sh /data/adb/modules/usbmanager_dcs/bin/usbctl status
sh /data/adb/modules/usbmanager_dcs/bin/usbctl apply mtp 1
sh /data/adb/modules/usbmanager_dcs/bin/usbctl set adb_off_unplug 0
sh /data/adb/modules/usbmanager_dcs/bin/usbctl block on
sh /data/adb/modules/usbmanager_dcs/bin/usbctl set guard 1
sh /data/adb/modules/usbmanager_dcs/bin/usbctl history 20
```

Logcat tag is `USBManager`.

## Not ported

- The experimental "computer recognition" schemes (pairing + Windows backend).
  They're opt-in plugins in the original and need its APK.
- The ADB authorizations screen. Android's own "Revoke USB debugging
  authorizations" covers it.
- Showing the chooser *over* the lock screen. WebUI hosts can't draw over the
  keyguard, so the prompt waits until you unlock.

## Credits

- Original idea and LSPosed module: [TigerSpirit217/USBManager](https://github.com/TigerSpirit217/USBManager) (Mulan PubL v2)
- Root module edition: @Dev_DcS
