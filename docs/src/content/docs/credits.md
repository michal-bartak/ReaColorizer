---
title: Credits
description: Author, tools, and license
---

## Author

Created by Michal Bartak, assisted by [Claude](https://claude.ai).

## Built with

- [REAPER](https://www.reaper.fm/) and its ReaScript Lua API.
- [ReaImGui](https://codeberg.org/cfillion/reaimgui) by cfillion, for the configuration window.
- A hand-written regex engine — no external Lua dependencies at all.
- These docs use [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/).

## Prior art

[SWS/S&M's](https://www.sws-extension.org/) Auto Color is the tool this one grew out of. It matches
case-insensitive substrings only and has no item support; this covers tracks, items, regions and
markers in one ordered rule list, with real regular expressions. Do not run both at once — see
[Troubleshooting](/Reaper-AutoColor/troubleshooting/#colours-keep-changing-back).

## License

Released under the MIT License. © 2026 Michal Bartak.

## Source

[github.com/michal-bartak/Reaper-AutoColor](https://github.com/michal-bartak/Reaper-AutoColor)
