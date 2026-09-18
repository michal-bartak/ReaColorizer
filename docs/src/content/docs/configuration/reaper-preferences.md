---
title: REAPER preferences
description: Two settings outside this tool that decide whether its colours are visible
---

Two REAPER preferences decide whether the colours this tool writes are visible at all. Neither is
something the tool can set for you, and both explain "it says it coloured 40 items and nothing
changed".

## Which colour an item is drawn in

**Preferences → Appearance → Peaks/Waveforms**, under *Extra peaks display options*:

```
Tint media item waveform peaks to:   [Track color] [Item color] [Take color]
Tint media item background to:       [Track color] [Item color] [Take color]
```

Precedence is **take > item > track**: a custom take colour beats a custom item colour, which beats
the track colour.

If **Item color** is unticked, item colours may not show no matter what this tool writes.

:::note
REAPER's own tooltip warns that *"Color theme may override this preference"*. The setting is stored
in `reaper.ini` as `tinttcp`, and is absent until you change it.
:::

## Automatic take colours

**Preferences → Appearance → Media**:

```
Automatically color any recording pass that adds takes or lanes
```

REAPER's tooltip: *"When recording, automatically apply the same random color to all takes created in
the same recording pass."*

This is the usual source of custom take colours nobody remembers setting. Because take colour beats
item colour, and take colours travel with a copy/paste, a stale one can follow an item onto a track
where it no longer means anything.

:::tip
Turn it off if you want this tool's item colours to be the whole story. To see which of the two your
build actually draws, give one item a custom colour and its take a different one — whichever you see
is the one winning.
:::

Note that this tool **resets** take colours whenever it writes a colour to an item — see
[Takes are not coloured](/AutoColor/usage/items-and-folders/#takes-are-not-coloured).
