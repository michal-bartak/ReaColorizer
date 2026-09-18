---
title: Applying colours
description: Apply now, Selection, and the actions that do the same without the window
---

Rules decide colours; applying is what writes them into the project. Nothing in the rule table
touches your tracks until you apply, or until the
[background loop](/ReaColorizer/usage/auto-apply/) does it for you.

Objects that already have the colour the rules want are **not rewritten**, so applying twice costs
nothing and changes nothing.

## From the window

<figure class="shot">

![The action bar](../../../assets/usage/action-bar.png)

<figcaption>Apply now and Selection, on the action bar</figcaption>
</figure>

**Apply now** colours the whole project — every track, item, region and marker — in **one undo
point**. It also tells the background loop to drop the marks it holds on objects you recoloured by
hand, so the rules take those objects back. That is the way out if you have hand-coloured something
and want the rules to own it again.

**Selection** colours only what is selected. When a track **and** some items are selected, whichever
you clicked last wins — the same rule REAPER uses for its own "depending on focus" actions. The
status line says which it used.

- With **items** in focus, tracks are still read (folder inheritance and the track → item cascade
  need them) but none of them is written.
- With **tracks** in focus, items are left out entirely.
- **Selected regions and markers are always included**, whichever way the focus went: there is no
  focus value to weigh them against.

## From the Action List

The same two operations exist as standalone actions, so you can put them on a key or a toolbar
without opening the window:

| Action | Scope |
|---|---|
| `MXM_NameColorizer_ApplyAll.lua` | The whole project. One undo point. Drops the hand-colour marks, like **Apply now**. |
| `MXM_NameColorizer_ApplySelection.lua` | The selected **tracks and items**. |

:::note[The action and the button are not quite the same]
`MXM_NameColorizer_ApplySelection.lua` never touches regions or markers, while the window's
**Selection** button includes any that are selected. The action has no window to report the
difference in, so it takes the narrower, more predictable scope.
:::

## When a rule change reaches the project

Editing a rule does **not** repaint the project, and neither does clicking around in the window
afterwards. With the background loop running, the edit is held until an object actually changes, and
is then applied to everything at once, so the project is never half on the old rules.

**Apply now** is the way to commit an edit immediately.

## Where to go next

- [Auto-apply](/ReaColorizer/usage/auto-apply/) — keeping the project in step without pressing anything.
- [Clearing colours](/ReaColorizer/usage/clearing/) — the other direction.
