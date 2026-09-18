--[[
Description: Name Colorizer
Version: 1.0.0
Author: Michal MaXyM Bartak
Links:
  GitHub https://github.com/michal-bartak/ReaColorizer
About:
  # Name Colorizer

  Colour tracks, items, regions and markers from their **names**, using plain
  substring, glob, or **real regular expressions**.

  One ordered rule list per object kind -- Tracks, Items, Regions, Markers --
  and within a kind the first rule that matches wins, so precedence works like
  firewall rules. Reordering track rules can never change which region wins.

  The configuration window needs ReaImGui 0.10+. Every other action, including
  Apply and Clear, works without it.

  MIT licensed. Source: <https://github.com/michal-bartak/ReaColorizer>
Metapackage: true
Changelog:
  Initial ReaPack release
Provides:
  [main] /Reaper/Scripts/MXM_NameColorizer/MXM_NameColorizer_*.lua > ./
  [nomain] /Reaper/Scripts/MXM_NameColorizer/lib/*.lua > lib/
  [nomain] /Reaper/Scripts/MXM_NameColorizer/lib/gui/*.lua > lib/gui/
  [data] /Reaper/Data/toolbar_icons/*.png > toolbar_icons/
  [data] /Reaper/Data/toolbar_icons/150/*.png > toolbar_icons/150/
  [data] /Reaper/Data/toolbar_icons/200/*.png > toolbar_icons/200/
]]--
