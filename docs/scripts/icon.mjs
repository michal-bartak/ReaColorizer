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

// REAPER toolbar icons are a 3-state horizontal strip of square cells: normal, hover, pressed.
// Verified by measuring Data/toolbar_icons: 527 of the 529 shipped icons are exactly 90x30. Their
// cell 2 is cell 1 at about +15% lightness and cell 3 is recoloured to the theme accent -- both
// wrong for this mark. Lightening six saturated hues at once reads as a white film laid over the
// icon rather than as a highlight, and the accent recolour would throw away the one thing the mark
// is about.
//
// So the states advance the colours around the ring instead: hover rotates every arm one step
// clockwise, pressed two. Same six hues, same luminance, and the icon appears to turn.
const STATES = [0, 1, 2];

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
const TOOLBAR_NAME = 'mxm_toolbar_autocolor.png';

/**
 * Advance every arm's colour `steps` places around the ring, so arm N takes the colour of the arm
 * `steps` further clockwise. The master lists its arms in clockwise order starting at the top, so
 * rotating the stroke colours in document order IS rotating them around the star.
 */
function rotate(svg, steps) {
  if (steps === 0) return svg;
  const colours = [...svg.matchAll(/stroke="(#[0-9A-Fa-f]{6})"/g)].map((m) => m[1]);
  let i = 0;
  return svg.replace(
    /stroke="#[0-9A-Fa-f]{6}"/g,
    () => `stroke="${colours[(i++ + steps) % colours.length]}"`,
  );
}

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

// 3. The REAPER toolbar strips, one per resolution.
for (const { dir, cell } of TOOLBAR_CELLS) {
  const margin = Math.round(cell * TOOLBAR_MARGIN);
  const art = cell - margin * 2;
  const cells = await Promise.all(
    STATES.map((steps) =>
      sharp(Buffer.from(rotate(master, steps)))
        .resize(art, art)
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

  await write(join(TOOLBAR_DIR, dir, TOOLBAR_NAME), strip);
}
