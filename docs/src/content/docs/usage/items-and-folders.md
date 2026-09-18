---
title: Items and folders
description: Colouring items from their track, and how a folder colour reaches its children
---

Two mechanisms give an object a colour without a rule of its own matching it: a track rule can
cascade to the **items** on it, and a folder's colour can flow down to its **children**.

## Colouring items from their track

A track rule has an **also colour items** switch, in the **Items** column.

<figure class="shot">

![The Items column](../../../assets/usage/cascade-items.png)

<figcaption>"also colour items" on a track rule</figcaption>
</figure>

With it on, every item sitting on a track that rule matches gets the track's colour — *whatever
those items are called*. That is usually what you want: colour the Bass track purple and its parts go
purple too, without naming them.

Precedence for an item is:

1. a rule on the **Items** tab, if one matches its take name — this always wins;
1. otherwise its track's colour, if that track's rule has *also colour items*;
1. otherwise nothing.

The switch travels down folders along with the colour, so a cascading folder rule also colours the
items on its child tracks.

:::tip[There is a better answer for "items should look like their track"]
An item with **no custom colour** is drawn by REAPER in its track's colour, live. So instead of
writing the track's colour onto the item, you can strip the item's colour and let REAPER do it — see
[reset unmatched items](/AutoColor/usage/clearing/#reset-unmatched-objects). Copy such an item to
another track and it follows that track immediately, with no rule and nothing that can go stale.
:::

## Folder colours

Whether a folder's colour flows to its children is one setting for the whole rule set, under
**Options → Folders**.

<figure class="shot">

![Folder colours](../../../assets/usage/folder-colours.png)

<figcaption>A folder and its children</figcaption>
</figure>

| Setting | Meaning |
|---|---|
| **fill gaps** *(default)* | A child that matched its own rule keeps that colour; only unmatched children inherit. |
| **force** | The folder's colour overrides matched children too. |
| **off** | No inheritance. |

`fill gaps` is the setting that lets you write one rule per folder and a handful of specific rules
for the tracks that need to stand out. `force` is for when the folder *is* the statement — every
track in the Drums folder the same colour, no exceptions.

:::caution
`force` flattens any gradient inside the folder: each parent overwrites its children, so a
rule grouping by folder ends up with one colour per folder. The rule warns when both are set.
:::

## Takes are not coloured

Colours are written to the **item**, never to a take. Whenever a colour is written to an item, every
take on that item has its own colour **reset**.

That is deliberate. Which of the two REAPER displays is a preference, so a custom take colour can
hide the item's colour entirely — without this, the tool would appear to do nothing on items whose
takes carry colours. Take colours also travel with a copy/paste, so a stale one follows an item onto
a track it no longer belongs to.

:::caution
If you deliberately colour takes, do not use this tool on items — it will clear those colours. Which
of the two your build draws is a [REAPER preference](/AutoColor/configuration/reaper-preferences/).
:::

There are no rules for takes at all. Take names are auto-derived from the track
(`$tracknumber-$track` by default) and are *not* updated when the track is renamed, so matching on
them would mostly duplicate matching the track, using a staler copy of the same string. Genuine take
colouring is per-instance and semantic — "this one is a keeper", "this is pass 3" — which REAPER
already covers with recording-pass auto-colour and take ranking.

## The master track

The master track is never scanned and never coloured: REAPER does not honour a custom colour on it,
not through this tool and not through REAPER's own track-colour action.

:::note
An earlier build offered a "master track" rule filter. A saved rule still using it is **disabled**
on load, with the reason in its note, rather than silently losing the filter — which would have
turned it into a rule matching every object.
:::

## Where to go next

- [Applying colours](/AutoColor/usage/applying/) — getting these decisions into the project.
- [Clearing colours](/AutoColor/usage/clearing/) — including the reset that makes items follow their track.
