# Heimdall

A tiny native macOS menu bar app that keeps a quiet watch on your disks. See occupancy and available space at a glance: **75% · 128 GB**. Click the menu bar item to open its fluid functionalism panel.

The menu bar uses text only, without a redundant usage icon. Normal readings stay neutral. Amber means space is getting tight; red means it is critical. Text labels make every state clear without relying on color.

## Download and install

Requires **macOS 13 or later**. The universal download supports **Apple Silicon and Intel** Macs.

1. Download **Heimdall-1.2.0-universal.dmg** from the [latest release](https://github.com/theedward/heimdall/releases/latest).
2. Open the disk image and **drag Heimdall into Applications**.
3. Eject the disk image, then open **Heimdall** from Applications.
4. Allow notifications when macOS asks if you want low-space banners. Click the menu bar readout to select a disk, adjust thresholds, or enable **Launch at login**.

![Drag Heimdall into Applications](docs/previews/installer.png)

*Installer layout preview, using the packaged artwork and icons.*

### First launch

This release is ad-hoc signed, without an Apple Developer ID certificate or notarization. macOS may block the first launch. After attempting to open the app, use **System Settings → Privacy & Security → Open Anyway** if macOS offers it, then confirm opening. Only approve a download you trust. You can also build from the MIT-licensed source below.

For updates, quit Heimdall before replacing the app. If you previously installed it in `~/Applications` using the source installer, replace that copy there rather than keeping two copies in different Applications folders.

## Screenshots

These images are rendered from the same SwiftUI views used by the app. **Every disk reading is made up**, including normal usage. They contain no user's disk figures or file names.

![Heimdall in light mode: normal, warning, critical](docs/previews/overview-light.png)

![Heimdall in dark mode: normal, warning, critical](docs/previews/overview-dark.png)

![External SSD example](docs/previews/external-light.png)

The [design notes](docs/DESIGN.md) describe the fluid functionalism adaptation and preview generation.

## Features

- Select the internal disk or a connected writable external disk. The menu bar remembers your selection, and shows **Disk offline** when it disconnects.
- Refreshes every 30 seconds, on wake, when disks connect/disconnect, and when opening the panel.
- Native macOS low-space banners for all listed disks when a threshold is crossed. A 2 GB recovery margin and 30-minute cooldown reduce repeat warnings; escalation from warning to critical is immediate. First readings, reconnections and preset changes establish a quiet baseline.
- Notification toggle and **Send test notification** button. Clicking a disk warning opens its panel. Delivery follows macOS permissions and Focus settings.
- **Check for updates** contacts GitHub only when clicked. A newer stable version offers **View release**; downloads and installation remain manual.
- Adjustable warning presets: relaxed (30/10 GB), balanced (60/25 GB, default), early warning (100/50 GB).
- **Review & free up space** opens Apple's Storage settings for the internal disk. External disks offer **Open disk in Finder**.
- Launch-at-login toggle, System light/dark appearance, explicit state labels and reduced-motion-aware spring feedback.
- Disk measurements stay local. No analytics or background file scanning. Manual update checks send an app-version User-Agent to the public GitHub API; no disk readings or file names are sent.

## Build from source

Requires Xcode Command Line Tools with Swift and Python 3. A normal build targets the current Mac's architecture.

```sh
./build.sh
open "build/Heimdall.app"
```

To install in `~/Applications` with launch at login enabled:

```sh
./install.sh
```

Quit an existing instance before installing an update.

### Create the drag-to-Applications installer

```sh
./package-dmg.sh
```

This builds a universal app, creates its icon and installer artwork, installs the pinned `dmgbuild` packaging dependency in a temporary virtual environment, and writes the `.dmg` plus a SHA-256 checksum into `build/`. A custom architecture is optional:

```sh
HEIMDALL_ARCH=arm64 ./package-dmg.sh
```

The packaging tools are build-time dependencies; the downloaded app needs neither Python nor Xcode.

Regenerate the fictional UI pictures:

```sh
"build/Heimdall.app/Contents/MacOS/Heimdall" --render docs/previews
```

## What is measured?

Heimdall reads filesystem statistics for `/System/Volumes/Data`, the standard startup Data volume, and mounted writable local external volumes. Available space is `f_bavail`; occupied space is the volume's reported total minus that available space. APFS volumes share space, so occupied space includes container space unavailable to this volume, rather than just the sum of files in the Data volume. It may differ from `df`'s Capacity column and from Storage Settings' accounting of purgeable space. Potentially purgeable files are not counted as free. Sizes use decimal GB.

Thresholds use absolute free space to preserve room for installs and updates. The percentage describes occupancy. Inspect a real reading without opening the UI:

```sh
"build/Heimdall.app/Contents/MacOS/Heimdall" --check
```

List detected disks with `--list-disks`. Run behavior and release-validation tests with `./test.sh`.

Preferences use `io.github.theedward.heimdall`. Launch at login uses `~/Library/LaunchAgents/io.github.theedward.heimdall.plist`. Turning it off removes that file; enabling it takes effect at the next login. Quit closes the current instance without disabling future login launches.

## Uninstall

Turn off **Launch at login**, quit the app, then move its Applications copy to the Trash. Optionally remove its preferences:

```sh
defaults delete io.github.theedward.heimdall
```

## License

[MIT](LICENSE).
