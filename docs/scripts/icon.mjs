// Render every icon output from the one master, ../icon/icon.svg.
//
// Nothing here is authored by hand except the master: the favicon is a copy, the README PNG is a
// resize, and the REAPER toolbar icons are three tinted copies composited side by side. Edit the
// SVG, run `make icon`, commit what changes.
//
// sharp comes from this folder's node_modules (it is an Astro dependency), so `npm install` in
// docs/ is the only prerequisite.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const DOCS = dirname(dirname(fileURLToPath(import.meta.url)));
const REPO = dirname(DOCS);

// The master lives with the other icon outputs at the repo root, not under docs/. It is the
// project's icon that the docs happen to reuse, not a documentation asset -- and the REAPER
// toolbar PNGs beside it are something a user copies into their REAPER install, which has nothing
// to do with the site. This script lives under docs/ only because that is where node and sharp are.
const MASTER = join(REPO, 'icon', 'icon.svg');

// The configuration window gets its own toolbar button, so it gets its own master: the same star
// with a gear at its hub. Only the toolbar strips are rendered from it. The favicon and the README
// mark stay the plain star, which is the project's identity rather than one of its two actions.
const MASTER_GUI = join(REPO, 'icon', 'icon-gui.svg');

// REAPER toolbar icons are a 3-state horizontal strip of square cells. Measuring all 528 shipped
// strips in Data/toolbar_icons tells you what the cells mean, because their colours are consistent:
//
//   cell 1  #818989 (53% of opaque pixels)  normal
//   cell 2  #939A9A (50%)                   the same art, ~14% lighter -- hover
//   cell 3  #1ABC98 (50%)                   the theme accent -- drawn while a toggle is ARMED
//
// So cell 3 is not a momentary click flash; it is how REAPER shows that a toggle action is on.
// That is what lets the AutoToggle button say whether the background loop is running:
//
//   off      the star greyed to REAPER's own #818989, so it reads as inactive next to every
//            other idle button on the toolbar
//   hover    that grey lifted 14%, exactly as REAPER lifts its own
//   on       the full six colours -- the mark only pays out its colour while it is working
//
// The window button is not a toggle, so it keeps its colours throughout and merely brightens.
const GREY = '#818989';
const HOVER_LIFT = 18; // #818989 -> #939A9A: REAPER's step is additive, not a ratio

// Hi-DPI is a subdirectory with the SAME filename, not a suffix: Data/toolbar_icons/150/x.png.
// Cell size 30 is the 1x; REAPER ships 45 (150) and 60 (200).
const TOOLBAR_CELLS = [
  { dir: '', cell: 30 },
  { dir: '150', cell: 45 },
  { dir: '200', cell: 60 },
];

// REAPER's own icons do not fill their cell. Measuring the first 40 in Data/toolbar_icons gives a
// median margin of 3.5px left, 4px on the other three sides, on a 30px cell. The master is drawn
// full-bleed so the favicon and the docs logo get the whole box; the inset is added here, where
// it is wanted, by rendering the art smaller and padding back out to the cell.
const TOOLBAR_MARGIN = 3.5 / 30;

// Straight into the install payload: Reaper/ mirrors REAPER's resource path, so the icon ships to
// the exact folder REAPER looks in and nobody copies it separately. The mxm_ prefix keeps it from
// colliding with the 529 icons REAPER ships in that same folder.
const TOOLBAR_DIR = join(REPO, 'Reaper', 'Data', 'toolbar_icons');

/** Map every stroke and fill colour in the SVG through `fn`. */
function recolour(svg, fn) {
  return svg.replace(
    /(stroke|fill)="(#[0-9A-Fa-f]{6})"/g,
    (_, attr, hex) => `${attr}="${fn(hex)}"`,
  );
}

function lighten(hex, amount) {
  const n = parseInt(hex.slice(1), 16);
  const ch = [(n >> 16) & 255, (n >> 8) & 255, n & 255]
    .map((v) => Math.min(255, v + amount));
  return '#' + ch.map((v) => v.toString(16).padStart(2, '0')).join('');
}

// A toggle button: grey while off, grey lifted on hover, full colour once it is running.
const TOGGLE_STATES = [
  (svg) => recolour(svg, () => GREY),
  (svg) => recolour(svg, () => lighten(GREY, HOVER_LIFT)),
  (svg) => svg,
];

// An ordinary button: always itself, brightening under the pointer and again while held.
const PLAIN_STATES = [
  (svg) => svg,
  (svg) => recolour(svg, (hex) => lighten(hex, HOVER_LIFT)),
  (svg) => recolour(svg, (hex) => lighten(hex, HOVER_LIFT * 2)),
];

// One entry per action that has a button. The file name mirrors the script it belongs to, so the
// two line up in REAPER's toolbar editor, where you pick an icon by name next to an action.
const TOOLBAR_ICONS = [
  { master: MASTER, name: 'mxm_toolbar_autocolor.png', states: TOGGLE_STATES },      // AutoToggle
  { master: MASTER_GUI, name: 'mxm_toolbar_autocolor_gui.png', states: PLAIN_STATES }, // GUI
];

async function write(path, buffer) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, buffer);
  console.log('  ' + path.replace(REPO + '/', ''));
}

const master = await readFile(MASTER, 'utf8');
console.log('Rendering from ' + MASTER.replace(REPO + '/', ''));

// 1. Favicons. Chrome has taken SVG favicons since 80 and this one renders correctly when loaded
//    on its own, but an SVG favicon is still the least reliable thing on the page -- browsers
//    cache favicons hard and pick between candidates by their own rules. So PNGs are offered
//    alongside it and astro.config.mjs points `favicon` at the 32px one; the SVG is an extra
//    <link> for anything that prefers a vector. Everything here lands in docs/public/, which is
//    the only directory Astro serves verbatim.
await write(join(DOCS, 'public', 'favicon.svg'), master);
for (const size of [16, 32, 48]) {
  await write(
    join(DOCS, 'public', `favicon-${size}.png`),
    await sharp(Buffer.from(master)).resize(size, size).png().toBuffer(),
  );
}

// 2. The README mark. A PNG, not the SVG: GitHub's markdown sanitiser is fussier about SVG.
await write(
  join(REPO, 'icon', 'autocolor-128.png'),
  await sharp(Buffer.from(master)).resize(128, 128).png().toBuffer(),
);

// 3. The REAPER toolbar strips: every icon, at every resolution.
for (const { master: source, name, states } of TOOLBAR_ICONS) {
  const art = await readFile(source, 'utf8');
  for (const { dir, cell } of TOOLBAR_CELLS) {
    const margin = Math.round(cell * TOOLBAR_MARGIN);
    const box = cell - margin * 2;
    const cells = await Promise.all(
      states.map((state) =>
        sharp(Buffer.from(state(art)))
          .resize(box, box)
          .extend({
            top: margin,
            bottom: margin,
            left: margin,
            right: margin,
            background: { r: 0, g: 0, b: 0, alpha: 0 },
          })
          .png()
          .toBuffer(),
      ),
    );
    const strip = await sharp({
      create: {
        width: cell * 3,
        height: cell,
        channels: 4,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    })
      .composite(cells.map((input, i) => ({ input, left: i * cell, top: 0 })))
      .png()
      .toBuffer();

    await write(join(TOOLBAR_DIR, dir, name), strip);
  }
}
