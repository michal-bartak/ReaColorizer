#!/usr/bin/env python3
"""Generate the placeholder images the docs reference, for shots nobody has taken yet.

Every screenshot in these docs is taken by hand -- the window is a ReaImGui script inside
REAPER, so there is nothing to drive from CI. SHOTS below is therefore the list of what the
pages expect: each entry names the file, and the caption is a note-to-self about what the
real screenshot has to show.

Running this writes a labelled grey card for every entry that does NOT exist yet, so the
site builds and every missing shot is obvious on the page. It never overwrites an existing
file, so dropping a real screenshot in at the same path is all it takes to replace one.
Pass --force to redraw the placeholders anyway (it still refuses to touch anything that is
not a placeholder of ours -- see is_placeholder).

    python3 scripts/placeholders.py            # fill in what is missing
    python3 scripts/placeholders.py --status    # list what is still a placeholder
"""

import sys
from pathlib import Path

# Pillow is a convenience, not a dependency of the site: the placeholders it draws are committed,
# so a checkout builds without it. `make docs-build` runs this first to catch a newly referenced
# image, and that must not fail on a machine that has no Pillow -- say so and carry on.
try:
    from PIL import Image, ImageDraw, ImageFont, PngImagePlugin
except ImportError:
    print("Pillow is not installed, so no placeholders were drawn.\n"
          "Committed ones are unaffected. To draw new ones: pip3 install Pillow")
    sys.exit(0)

ASSETS = Path(__file__).resolve().parent.parent / "src" / "assets"

# A marker written into the PNG's text chunks, so --force and --status can tell our own
# cards apart from a real screenshot that happens to sit at the same path.
MARKER_KEY = "ReaColorizerDocs"
MARKER_VAL = "placeholder"

# path (under src/assets), size, and what the real screenshot needs to show
SHOTS = [
    ("installation/action-list.png", (1100, 620),
     "REAPER's Action List with the MB_NameColorizer_* scripts loaded"),
    ("installation/toolbar-button.png", (760, 240),
     "The toolbar button for AutoToggle, lit while the loop runs"),

    ("usage/window-overview.png", (1200, 760),
     "The whole configuration window: tab strip, rule table, action bar, preview panes"),
    ("usage/rule-row.png", (1200, 300),
     "One rule row: handle, on/off, Name, Match, Pattern, Aa, Filter, Colour, Items, Hits"),
    ("usage/tabs.png", (900, 220),
     "The four tabs -- Tracks, Items, Regions, Markers -- with their rule counts"),
    ("usage/match-modes.png", (760, 360),
     "The Match dropdown open, showing contains / glob / regex"),
    ("usage/filter.png", (760, 360),
     "The Filter dropdown on a track rule: is a folder track / is inside a folder / has no name"),
    ("usage/preview.png", (1200, 460),
     "Objects preview and Pattern tester side by side at the foot of the window"),

    ("usage/colour-picker.png", (760, 420),
     "The Colour cell and its picker, with the second colour added"),
    ("usage/gradient-spread.png", (900, 380),
     "The 'spread across' box beside the second colour, open"),
    ("usage/gradient-runs.png", (900, 620),
     "Track panel: two blocks of String* tracks, each with its own full ramp"),

    ("usage/cascade-items.png", (900, 320),
     "The Items column on a track rule -- 'also colour items' switched on"),
    ("usage/folder-colours.png", (900, 620),
     "A folder and its children in the track panel, showing fill gaps vs force"),

    ("usage/action-bar.png", (1200, 220),
     "The action bar: + rule, Undo, Apply now, Selection, Clear..., Auto, Options"),
    ("usage/auto-status.png", (760, 240),
     "The Auto button reading 'Auto: on', and the status line below the window"),
    ("usage/clear-menu.png", (760, 380),
     "The Clear... menu with its three scopes"),

    ("configuration/options.png", (860, 900),
     "The Options dialog: Folders, Scope, Background auto-colouring, Window, Rules file"),
    ("configuration/scope.png", (860, 260),
     "The Scope row: 'Reset to the default colour when no rule matches' per kind"),

    ("troubleshooting/sws-warning.png", (1100, 240),
     "The banner shown when SWS Auto Color is enabled at the same time"),
    ("troubleshooting/why-this-colour.png", (1000, 640),
     "MB_NameColorizer_WhyThisColour.lua output in the ReaScript console"),
]

BG = (232, 232, 234)
FG = (120, 120, 126)
INK = (70, 70, 76)

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def font(size):
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def is_placeholder(path):
    """True only for a card this script drew. A real screenshot has no marker chunk."""
    try:
        with Image.open(path) as im:
            return im.info.get(MARKER_KEY) == MARKER_VAL
    except Exception:
        return False


def draw(path, size, caption):
    w, h = size
    img = Image.new("RGB", size, BG)
    d = ImageDraw.Draw(img)

    # Dashed border, so a placeholder never reads as a real screenshot with a light theme.
    step, dash, pad = 16, 9, 8
    for x in range(pad, w - pad, step):
        d.line([(x, pad), (min(x + dash, w - pad), pad)], fill=FG, width=2)
        d.line([(x, h - pad), (min(x + dash, w - pad), h - pad)], fill=FG, width=2)
    for y in range(pad, h - pad, step):
        d.line([(pad, y), (pad, min(y + dash, h - pad))], fill=FG, width=2)
        d.line([(w - pad, y), (w - pad, min(y + dash, h - pad))], fill=FG, width=2)

    title = font(max(15, min(26, w // 34)))
    body = font(max(12, min(19, w // 48)))

    lines = [("screenshot placeholder", body, FG),
             (path.name, title, INK),
             (caption, body, FG),
             (f"{w} x {h}", body, FG)]

    heights = [d.textbbox((0, 0), t, font=f)[3] for t, f, _ in lines]
    gap = 12
    y = (h - (sum(heights) + gap * (len(lines) - 1))) // 2
    for (text, f, colour), th in zip(lines, heights):
        tw = d.textbbox((0, 0), text, font=f)[2]
        d.text(((w - tw) // 2, y), text, font=f, fill=colour)
        y += th + gap

    meta = PngImagePlugin.PngInfo()
    meta.add_text(MARKER_KEY, MARKER_VAL)
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, pnginfo=meta)


def main(argv):
    force = "--force" in argv
    status = "--status" in argv

    made, kept, real = 0, 0, 0
    for rel, size, caption in SHOTS:
        path = ASSETS / rel
        if path.exists() and not is_placeholder(path):
            real += 1
            continue
        if status:
            print(f"placeholder  {rel}")
            kept += 1
            continue
        if path.exists() and not force:
            kept += 1
            continue
        draw(path, size, caption)
        made += 1

    if status:
        print(f"{kept} still placeholders, {real} real screenshot(s) of {len(SHOTS)}.")
    else:
        print(f"{made} written, {kept} left alone, {real} real screenshot(s) of {len(SHOTS)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
