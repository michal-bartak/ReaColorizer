---
title: Auto-apply
description: The background loop, what it refuses to touch, and what it costs
---

`MXM_AutoColor_AutoToggle.lua` starts a background loop that keeps the project in step as you
rename things. Run the action again to stop it. The toolbar button lights while it runs.

<figure class="shot">

![The Auto button](../../../assets/usage/auto-status.png)

<figcaption>The Auto button, and the status line</figcaption>
</figure>

## It is built to stay out of your way

- **It never reverts a colour you set by hand.** If an object's colour stops matching what the tool
  last wrote, while its name is unchanged, that object is left alone until you rename it.
- It adds **no undo points**, so renaming a track does not shred your undo history. Turn on
  *Create undo points for automatic changes* in [Options](/Reaper-AutoColor/configuration/) if you want
  them.
- It writes nothing when nothing changed, and pauses entirely **while recording**.
- Tracks are swept immediately; items and regions follow once the project has settled, in
  time-budgeted chunks.

:::tip[Taking an object back]
**Apply now** (from the window or `MXM_AutoColor_ApplyAll.lua`) tells the loop to drop those
hand-colour marks, so the rules own every object again.
:::

## Starting and stopping

The **Auto** button on the action bar shows the loop's state — `Auto: off`, `Auto: on`, or
`Auto: paused` — and, once the loop has run at least once in this REAPER session, starts and stops
it. Before that it can only report: REAPER has to have run the action once for the script to know
its command ID.

Opening the configuration window does **not** stop or pause the loop. The window shows its status
and has its own **Pause**; the loop itself is started and stopped only by the `AutoToggle` action.

## What it re-reads, and when

REAPER reports a single project-wide "something changed" counter, so a fader move arrives looking
exactly like a rename. The loop works around that rather than re-reading everything:

| | When it is re-read |
|---|---|
| **Tracks** | On every change — a rename is only visible by reading names. Re-planned only when what it read actually differs. |
| **Items and regions** | Only when something says they need it: one appeared or vanished, a track changed, or **Rescan items at most every (s)** has elapsed. |

The rescan interval is 5 s by default, and the only thing waiting on it is an item **renamed in
place**, which nothing cheaper can see. Set it to 0 to re-read everything on every change — correct,
and slow on a large project.

`Check every (s)` and `Work budget (ms)` in [Options](/Reaper-AutoColor/configuration/) control how
often the loop wakes and how long it may work before yielding.

:::caution[Gradients on items]
A gradient cannot be computed incrementally: the whole group has to be re-planned when one member
moves. A gradient rule aimed at **items** is therefore the one thing here that gets expensive on very
large projects.
:::

## Debug output

Set the ExtState `MXM_AutoColor` / `auto_debug` to `1` for a console readout of what the loop is
doing and why.

## Where to go next

- [Options](/Reaper-AutoColor/configuration/) — the timing settings and undo behaviour.
- [Troubleshooting](/Reaper-AutoColor/troubleshooting/) — when a colour is not what the rules say it should be.
