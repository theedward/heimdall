# Disk Beacon

A tiny native macOS menu bar app showing internal disk occupancy and available space: **82% · 89 GB**. Its colored disk icon fills with usage; a text status in the menu makes the warning accessible without relying on color.

- Refreshes every 30 seconds, on wake, and when opening the menu.
- Green when there is room, amber when space is getting tight, red when critical.
- Adjustable presets: relaxed (30/10 GB), balanced (60/25 GB, default), early warning (100/50 GB).
- Menu includes exact space figures, refresh, Storage Settings, and launch at login.
- Local only. No network requests, analytics, notifications, or background scanning. The GitHub link opens only when selected in About.

## Build and install

Requires macOS 13 or later, Xcode Command Line Tools with Swift, and Python 3. Builds for the Mac's current architecture.

```sh
./build.sh
open "build/Disk Beacon.app"
```

To install in `~/Applications` and enable launch at login:

```sh
./install.sh
```

Quit an existing instance before installing an update. The app uses ad-hoc signing, not an Apple Developer ID or notarization. Downloaded builds may require approval in macOS Privacy & Security; building locally is the simplest installation route.

## What is measured?

Disk Beacon reads filesystem statistics for `/System/Volumes/Data`, the standard startup Data volume. Available space is `f_bavail`; occupied space is the volume's reported total minus that available space. APFS volumes share space, so occupied space includes container space unavailable to this volume, rather than just the sum of files in the Data volume. It may differ from `df`'s Capacity column and from Storage Settings' accounting of purgeable space. Potentially purgeable files are not counted as free. Sizes use decimal GB.

Thresholds are based on absolute free space, not percentage, to preserve room for installs and updates. The menu bar percentage describes occupancy.

Inspect the current reading without opening the UI:

```sh
"build/Disk Beacon.app/Contents/MacOS/DiskBeacon" --check
```

Preferences are stored under `io.github.theedward.disk-beacon`. Launch at login uses `~/Library/LaunchAgents/io.github.theedward.disk-beacon.plist`. Turning it off removes that file; enabling it takes effect at the next login. Quit closes the current instance without disabling future login launches.

## Uninstall

Turn off **Launch at login**, quit the app, then delete `~/Applications/Disk Beacon.app`. Optionally remove its preferences with:

```sh
defaults delete io.github.theedward.disk-beacon
```

## License

[MIT](LICENSE).
