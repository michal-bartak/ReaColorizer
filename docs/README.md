# Reaper AutoColor docs

The user documentation, built with [Astro](https://astro.build/) +
[Starlight](https://starlight.astro.build/) and published to GitHub Pages at
<https://michal-bartak.github.io/Reaper-AutoColor/>.

From the repository root:

```bash
make docs          # build and serve at http://localhost:4321/Reaper-AutoColor/
make docs-dev      # live-reload dev server, for writing
```

`make` alone lists every target. Directly, from this folder:

```bash
npm install
npm run dev        # http://localhost:4321/Reaper-AutoColor/
npm run build      # static site into dist/
```

## Layout

```
astro.config.mjs               site config and the sidebar
src/content/docs/              the pages, as Markdown
src/assets/<section>/          screenshots, referenced relatively from the pages
src/styles/custom.css          accent colour, figures, the screenshot lightbox
scripts/placeholders.py        the list of expected screenshots, and the stand-ins
```

Adding a page means creating the Markdown file **and** adding it to the `sidebar` array in
`astro.config.mjs`.

## Screenshots

Every screenshot is taken by hand — the window is a ReaImGui script inside REAPER, so there is
nothing for CI to drive. `scripts/placeholders.py` lists the shots the pages expect and draws a
labelled grey card for any that is missing, so the site always builds and a gap is obvious on the
page.

```bash
make docs-shots            # fill in what is missing (runs on docs-dev and docs-build too)
make docs-shots-status     # what is still a placeholder
```

Drawing them needs Pillow (`pip3 install Pillow`). Without it the script is a no-op and says so —
the committed placeholders still build.

Replace one by saving a real screenshot over it, at the same path under `src/assets/`. The script
never overwrites a file it did not draw.

## Not part of the site

`DECISIONS.md` and `RESEARCH.md` sit in this folder too. They are the engineering notes — why the
tool is built the way it is, and external facts verified against source — and Astro does not read
them. They keep their paths so the root `README.md` and every link to them still work.
