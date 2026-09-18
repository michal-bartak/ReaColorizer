---
title: Clearing colours
description: The three clearing scopes, and the per-kind reset for unmatched objects
---

Clearing sets an object back to the **theme default** — it removes the custom colour rather than
writing a new one.

## The Clear menu

<figure class="shot">

![The Clear menu](../../../assets/usage/clear-menu.png)

<figcaption>Clear…, on the action bar</figcaption>
</figure>

| Scope | What it resets |
|---|---|
| **Clear colours the rules match** | Only objects a rule currently claims. |
| **Clear selected objects** | What is selected, whether or not a rule matches it. |
| **Clear EVERY custom colour in the project…** | Everything, including colours this tool never set. Asks first. |

**Clear selected objects** follows the same focus rule as **Selection**: with both a track and some
items selected, whichever you clicked last wins, and selected regions and markers are always
included.

:::caution
The third scope reaches colours that had nothing to do with these rules. It asks for confirmation,
and REAPER's undo (`Cmd`/`Ctrl`+`Z`) will put them back — but it is the one clearing scope that can
lose work.
:::

`MXM_AutoColor_ClearColors.lua` offers the first two scopes from the Action List. Clearing *every*
custom colour is deliberately GUI-only: it is not something a single keystroke should do.

## Reset unmatched objects

**Options → Scope → Reset to the default colour when no rule matches** is set **per kind**, and is
off everywhere by default.

<figure class="shot">

![The Scope row in Options](../../../assets/configuration/scope.png)

<figcaption>Reset to the default colour when no rule matches</figcaption>
</figure>

With it on for a kind, every apply strips the colour from any object of that kind the rules do not
claim — making the rules the single source of truth for that kind.

:::caution[Careful with tracks]
For tracks this also strips every track colour you set by hand.
:::

### For items it is usually what you want

It is the better answer to "my pasted item kept its old colour":

> An item with **no custom colour** is drawn by REAPER in its **track's** colour, live. Copy it to
> another track and it follows that track immediately — no rule, no sweep, and nothing that can go
> stale.

So there are two ways to make items match their track, and they are not equal:

| | How it works | On copy/paste to another track |
|---|---|---|
| **also colour items** on a track rule | Writes the track's colour onto the item | Stays wrong until something re-applies, and is stale if the new track's rule does not cascade |
| **reset unmatched items** | Removes the item's colour, so REAPER draws it from the track | Correct instantly, forever |

Prefer the second, unless you actually want items to differ from their track, or your theme does not
tint item backgrounds by track colour.

:::note[Older REAPER builds]
On REAPER older than 7.62 the marker/region *clear* path is unavailable, because `SetProjectMarker4`
reads colour 0 as "leave unchanged". Colouring still works, and the scripts say how many
markers/regions they had to skip.
:::

## Where to go next

- [REAPER preferences](/Reaper-AutoColor/configuration/reaper-preferences/) — whether item colours are drawn at all.
- [Troubleshooting](/Reaper-AutoColor/troubleshooting/) — a colour that will not go away.
