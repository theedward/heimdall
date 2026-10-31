# Heimdall 2 interface

Native adaptation of [Fluid Functionalism](https://www.fluidfunctionalism.com/docs) and its [relative surface hierarchy](https://www.fluidfunctionalism.com/docs/surfaces). Neutral layered surfaces, fine borders, rounded controls and restrained shadows keep focus on the next useful action. Amber and red remain reserved for disk warnings. Press feedback uses springs; Reduce Motion removes scaling. Native keyboard controls, selected navigation state and accessibility labels remain available.

The menu prioritizes decisions: disk context, up to two Easy wins, one Worth considering, All recommendations, and a compact Preferences control. More difficult opportunities stay visible alongside simple ones. Each card shows a concrete action, the size involved and one relevant consequence. It never adds overlapping sizes into a reclaimable total.

The deeper window replaces the category-button grid with a persistent sidebar: Recommendations, Files & apps, Moves, Preferences. Files are searchable and filterable, with focused details. A move is approved in one sheet that offers compatible destinations and an organized folder; progress covers copying and verification. Trash has a separate permanent-deletion sheet. Tool purges use the same focused sheet pattern, with Homebrew’s preview included. Completed moves have a durable Move back action. Dismissals are local preferences that users can restore.

Discovery runs automatically after launch and about every 15 minutes; unavailable and incomplete locations appear under a disclosure rather than filling the primary workflow with implementation notes. Discovery is read-only. Deletion, transfer and Trash emptying require explicit user actions.

Copy stays short: names, sizes, consequences and results. Settings and technical detail are secondary. Rendered screenshots use fictional files and disk values, shared production views, and both system appearances. The renderer omits only scroll containers where necessary; actual controls and card content stay shared.

Regenerate with:

```sh
./build.sh
build/Heimdall.app/Contents/MacOS/Heimdall --render docs/previews
```
