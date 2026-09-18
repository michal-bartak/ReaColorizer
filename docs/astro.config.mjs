import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import starlightThemeRapide from 'starlight-theme-rapide';

// GitHub Pages: served at https://michal-bartak.github.io/ReaColorizer/
// (base matches the repo name). Update both if the repo is renamed.
export default defineConfig({
  site: 'https://michal-bartak.github.io',
  base: '/ReaColorizer',
  integrations: [
    starlight({
      title: 'ReaColorizer',
      description: 'Colour REAPER tracks, items, regions and markers from their names',
      plugins: [starlightThemeRapide()],
      // One transparent SVG serves both: the mark is mid-tone throughout, so it reads on the
      // light and the dark theme without a per-theme variant.
      //
      // The master is ../icon/icon.svg, OUTSIDE this project -- it belongs to the tool, not to
      // the site, and it sits with the REAPER toolbar renders that a user copies into their
      // REAPER install. Astro bundles it into _astro/ from there without complaint. The favicon
      // is a generated copy in public/, because Astro only serves that directory verbatim.
      // A PNG, not the SVG: see the favicon <link>s in `head` below.
      favicon: '/favicon-32.png',
      logo: {
        src: '../icon/icon.svg',
        alt: 'ReaColorizer',
        replacesTitle: false,
      },
      // Restore Starlight's own theme picker: a labelled Dark/Light/Auto <select>.
      // starlight-theme-rapide replaces ThemeSelect with a sun/moon icon button whose click
      // handler only flips between dark and light, so "auto" (follow the OS) is unreachable once
      // you click it. Its overrideComponents() yields to an override declared here, logging one
      // build warning as it does so. NOTE that warning is expected, not a misconfiguration.
      // Header spacing then needs two rapide rules undone; see the theme-picker block in
      // src/styles/custom.css.
      components: {
        ThemeSelect: '@astrojs/starlight/components/ThemeSelect.astro',
      },
      // Renames the table-of-contents' top entry from "Overview" to the page title.
      routeMiddleware: './src/starlightRouteData.ts',
      social: { github: 'https://github.com/michal-bartak/ReaColorizer' },
      customCss: ['./src/styles/custom.css'],
      // Click a screenshot in the docs body to view it full-size in a lightbox.
      // Runs on first load and after every Starlight client-side navigation.
      head: [
        // The remaining favicon sizes, plus the SVG for anything that would rather scale a vector.
        // `favicon` above emits its own <link> and prefixes the base path for you; these do not,
        // hence the literal /ReaColorizer. If a browser ever shows no icon at all, delete the SVG
        // line -- a PNG favicon is the one thing every browser agrees on.
        { tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '16x16', href: '/ReaColorizer/favicon-16.png' } },
        { tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '48x48', href: '/ReaColorizer/favicon-48.png' } },
        { tag: 'link', attrs: { rel: 'icon', type: 'image/svg+xml', href: '/ReaColorizer/favicon.svg' } },
        {
          tag: 'script',
          content: `
            (function () {
              function overlay() {
                var el = document.getElementById('img-lightbox');
                if (el) return el;
                el = document.createElement('div');
                el.id = 'img-lightbox';
                el.className = 'img-lightbox';
                el.innerHTML = '<img alt="">';
                el.addEventListener('click', function () { el.classList.remove('open'); });
                document.addEventListener('keydown', function (e) {
                  if (e.key === 'Escape') el.classList.remove('open');
                });
                document.body.appendChild(el);
                return el;
              }
              function wire() {
                var imgs = document.querySelectorAll('.sl-markdown-content img');
                for (var i = 0; i < imgs.length; i++) {
                  (function (img) {
                    if (img.dataset.lightbox) return;
                    img.dataset.lightbox = '1';
                    img.addEventListener('click', function () {
                      var el = overlay();
                      var big = el.querySelector('img');
                      big.src = img.currentSrc || img.src;
                      big.alt = img.alt || '';
                      el.classList.add('open');
                    });
                  })(imgs[i]);
                }
              }
              document.addEventListener('DOMContentLoaded', wire);
              document.addEventListener('astro:page-load', wire);
            })();
          `,
        },
      ],
      sidebar: [
        { label: 'Overview', link: '/' },
        { label: 'Installation', link: '/installation/' },
        {
          label: 'Usage',
          items: [
            { label: 'The configuration window', link: '/usage/' },
            { label: 'Matching names', link: '/usage/matching/' },
            { label: 'Colours and gradients', link: '/usage/colours/' },
            { label: 'Items and folders', link: '/usage/items-and-folders/' },
            { label: 'Applying colours', link: '/usage/applying/' },
            { label: 'Auto-apply', link: '/usage/auto-apply/' },
            { label: 'Clearing colours', link: '/usage/clearing/' },
          ],
        },
        {
          label: 'Configuration',
          items: [
            { label: 'Options', link: '/configuration/' },
            { label: 'Rules file', link: '/configuration/rules-file/' },
            { label: 'REAPER preferences', link: '/configuration/reaper-preferences/' },
          ],
        },
        { label: 'Troubleshooting', link: '/troubleshooting/' },
        { label: 'Development', link: '/development/' },
        { label: 'Credits', link: '/credits/' },
      ],
    }),
  ],
});
