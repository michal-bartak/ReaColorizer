---
title: Troubleshooting
description: When the colour is not what the rules say it should be
---

## Start here: why this colour?

Select the track or item and run `MXM_AutoColor_WhyThisColour.lua`. It answers the whole question
in one console readout: which rule claimed the object, what the rules would set, whether anything is
currently applying, and why an old colour survived.

<figure class="shot">

![WhyThisColour output](../../assets/troubleshooting/why-this-colour.png)

<figcaption>MXM_AutoColor_WhyThisColour.lua</figcaption>
</figure>

## Nothing visibly changed, but it says it coloured things

Almost always a REAPER display setting rather than the tool:

1. **Item colours are not drawn.** *Preferences → Appearance → Peaks/Waveforms* — tick **Item color**
   for background and/or peaks. See [REAPER preferences](/Reaper-AutoColor/configuration/reaper-preferences/).
1. **A take colour is winning.** Take beats item. Confirm it by giving one item a custom colour and
   its take a different one — whichever you see is the one your build draws.
1. **Your theme overrides it.** REAPER's own tooltip warns that a colour theme may override the tint
   preference.

## Colours keep changing back

Two live colour engines are fighting. The scripts warn when SWS's auto-colour is switched on:

<figure class="shot">

![The SWS banner](../../assets/troubleshooting/sws-warning.png)

<figcaption>SWS Auto Color is enabled</figcaption>
</figure>

Switch one off — *SWS → Auto Color/Icon/Layout* — and keep the rules in one place.

## A rule shows 0 hits

**Hits** counts what a rule *wins*, not what its pattern matches:

- An **earlier rule on the same tab** claimed those objects first. Move this one up.
- The mode is **glob** and the pattern is not wrapped in `*`. Globs are anchored to the whole name:
  `bass` matches a track called exactly "bass". Use `*bass*`, or switch to **contains**.
- A **filter** is narrowing it — the filter and the pattern must both hold.
- The rule is **switched off**, or every rule on the tab is (the tab says so).

The **Pattern tester** at the foot of the window settles it: set the same mode, paste the pattern and
the name, and see whether it matches at all.

## "This pattern is too slow"

The rule exceeded its step budget and is treated as a no-match, rather than being allowed to freeze
REAPER. Nested quantifiers — `(a+)+$` and friends — are the usual cause. Simplify the pattern; the
same intent usually has a linear form.

## My hand-picked colour came back / did not come back

The background loop **never reverts a colour you set by hand**: once an object's colour stops matching
what the tool last wrote, that object is left alone until you rename it.

To hand the object back to the rules, press **Apply now** (or run `MXM_AutoColor_ApplyAll.lua`).
That drops the marks the loop is holding, and the rules take every object back.

## The Auto button says "off" and will not start

Run the action `MXM_AutoColor_AutoToggle.lua` once from the Action List. Until REAPER has run it,
the script does not know its own command ID, so the button can only report the state — after that it
starts and stops the loop.

## An item renamed in place did not recolour

Items and regions are re-read on a timer — **Rescan items at most every (s)**, 5 s by default —
because REAPER reports only one project-wide "something changed" counter and re-reading every item on
every change is expensive. Renaming in place is the one edit nothing cheaper can see. Lower the
interval, or press **Apply now**. See [Auto-apply](/Reaper-AutoColor/usage/auto-apply/#what-it-re-reads-and-when).

## My change to the scripts did nothing

The window and the auto-toggle hold their Lua state for as long as they run. After editing anything
under `Scripts/MXM_AutoColor/lib/`:

1. Close the configuration window and re-run it.
1. Toggle auto **off and on** again.

One-shot actions pick up changes immediately.

## Marker and region colours will not clear

On REAPER older than **7.62** the marker/region *clear* path is unavailable: `SetProjectMarker4`
reads colour 0 as "leave unchanged". Colouring still works, and the scripts report how many
markers/regions they had to skip.

## The master track is never coloured

It never will be. REAPER does not honour a custom colour on the master — not through this tool, and
not through REAPER's own track-colour action — so it is not scanned at all.

## My rules are gone

Look next to [`config.json`](/Reaper-AutoColor/configuration/rules-file/):

| File | Meaning |
|---|---|
| `config.bak.json` | The previous version. Rename it over `config.json` with the window closed. |
| `config.bad.json` | The file was unreadable and was parked here rather than lost. |

The window also has **Undo** for rule changes, as long as it is still open.

## The window says nothing will be saved

The rule file was written by a **newer** version of the tool. Editing is allowed so you can look
around, but nothing is written back — an older build will not quietly rewrite a config it does not
understand. Update the scripts.

## Diagnostics

| Script | What it tells you |
|---|---|
| `MXM_AutoColor_WhyThisColour.lua` | Select a track or item: which rule claimed it, what the rules would set, whether anything is applying, and why an old colour survived |
| `MXM_AutoColor_Dump.lua` | Every track, item, region and marker with its name, GUID and current colour |
| `MXM_AutoColor_RunTests.lua` | The self-test, printed to the ReaScript console |

For the background loop, set the ExtState `MXM_AutoColor` / `auto_debug` to `1` and watch the
console.

:::note[Probes that do not ship]
The repository's `dev/` folder holds a few more — a take-colour probe, a focus probe, and one that
builds a scratch project covering the awkward cases. They are author tools, excluded from the
package on purpose, so they are not in your REAPER install. Clone the repository if you want them.
:::
