# Heimdall interface

Native adaptation of [Fluid Functionalism](https://www.fluidfunctionalism.com/docs) and its [relative surface hierarchy](https://www.fluidfunctionalism.com/docs/surfaces).

The panel uses neutral nested surfaces, fine borders, quiet shadows, and a free-space-first hierarchy. Normal readings are gray; amber and red signal warning and critical states. State names and explicit thresholds accompany color. Both system light and dark appearances are supported.

The warning preset selector uses a raised selection surface. Press feedback compresses subtly and reverses with spring motion. Reduce Motion removes scaling and spring feedback. Hover/tooltips and keyboard focus use native macOS behavior. The launch-at-login switch is rendered in SwiftUI, using the same implementation in the app and previews.

Pictures are rendered from the actual shared SwiftUI panel and menu bar text, not drawn mockups. Normal (128 GB free), warning (42 GB free) and critical (18 GB free) all use generated readings to illustrate states without filling the disk. They are visual examples, not evidence that the disk has those free-space values.

![Light appearance and states](previews/overview-light.png)
![Dark appearance and states](previews/overview-dark.png)

Regenerate with:

```sh
./build.sh
"build/Heimdall.app/Contents/MacOS/Heimdall" --render docs/previews
```

The menu bar shows only percentage and free-space text. Normal text uses the native label color; amber and red mark warning and critical readings. The redundant occupancy rectangle has been removed. The user confirmed the cleanup shortcut reaches the intended macOS page.

The native disk menu sits above the free-space card. Offline disks have an explicit state and reconnect guidance. Notifications use a neutral toggle and a test action; updates use a small on-demand action and status text. The panel scrolls on smaller displays. Amber and red remain reserved for disk warnings.

Cleanup uses a separate resizable native window so the menu bar stays compact. Neutral cards separate the rules, candidate groups and setting recommendations. Each row has an unchecked-by-default selection, reason, path, date, size and Finder reveal action. A fixed footer keeps the selected count and the review action visible while the content scrolls. The confirmation names the selected items and explains Trash behavior. Settings changes have their own confirmation. Cleanup previews use a fictional example user and files; only the scroll container is omitted for offscreen rendering, while the content views remain shared.

Storage opportunities use six SwiftUI category buttons with native keyboard focus and a neutral raised selection rather than a machine-specific drive workflow. Each row identifies the appropriate action: reviewed tool cleanup, native manager, destination picker, or Finder review. Empty categories explain missing tools/data/access; incomplete sizes say “At least” and do not become space-saving promises. Extra scan locations are optional and removable. Runtime last-use information is evidence, while application/editor usage remains unknown. A destination is chosen at the moment of relocation; it is never preselected from the developer’s Mac. The new screenshots use only fictional tools, locations and values.

Personal-file review starts on Downloads, with Documents alongside it. A two-row category grid keeps labels legible. Plain-language file explanations make archive ownership and uncertain last-use evidence clear. Each file offers move, reviewed removal and Finder reveal; removal defaults to Keep file. A separate neutral Trash card explains the permanent scope, with Open Trash and Empty Trash actions. The destructive confirmation defaults to Cancel and delegates to Finder.
