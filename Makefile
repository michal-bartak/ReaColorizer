.PHONY: help test icon docs docs-install docs-dev docs-build docs-preview docs-shots docs-shots-status docs-clean

# The scripts themselves need no build step -- REAPER runs the .lua files where they sit. This
# file is for the parts that do have a toolchain: the test suite, the icon, and the docs site.

# Defined up here because the icon target needs it too, and Make expands a prerequisite the moment
# it reads the rule -- a definition further down would expand to nothing.
DOCS_DIR := docs
# Matches `base` in docs/astro.config.mjs; astro preview serves the site under it.
DOCS_URL := http://localhost:4321/ReaColorizer/

help:
	@echo "Docs (Astro + Starlight, in docs/):"
	@echo "  make docs               read them locally -- build, then serve at $(DOCS_URL)"
	@echo "  make docs-dev           live-reload dev server, for writing"
	@echo "  make docs-build         static build into docs/dist/"
	@echo "  make docs-shots         draw placeholders for any newly referenced screenshot"
	@echo "  make docs-shots-status  list which screenshots are real and which are placeholders"
	@echo "  make docs-clean         remove docs/dist and docs/.astro"
	@echo ""
	@echo "Icon:"
	@echo "  make icon               re-render every icon output from icon/icon.svg"
	@echo ""
	@echo "Tests (need a standalone Lua: brew install lua):"
	@echo "  make test               run the suite outside REAPER"

test:
	./tests/run.sh

# Re-render the favicon, the README mark and the REAPER toolbar strips from the one master SVG.
# Deliberately NOT a prerequisite of docs-build: the outputs are committed and the master changes
# about never, so paying for it on every docs build would be waste.
icon: $(DOCS_DIR)/node_modules
	cd $(DOCS_DIR) && npm run --silent icon

# ---- Docs (Astro + Starlight): read them offline, or let CI publish to GitHub Pages ----

# Install docs dependencies only when they're missing (Node + npm required).
$(DOCS_DIR)/node_modules:
	cd $(DOCS_DIR) && npm install

# Explicit one-time install target.
docs-install: $(DOCS_DIR)/node_modules

# The one to reach for: build the site and serve it, exactly as published.
docs: docs-preview

# Live-reload dev server at http://localhost:4321/ReaColorizer/
docs-dev: $(DOCS_DIR)/node_modules docs-shots
	cd $(DOCS_DIR) && npm run dev

# Static build into docs/dist/
docs-build: $(DOCS_DIR)/node_modules docs-shots
	cd $(DOCS_DIR) && npm run build

# Serve the built site locally (builds first if needed)
docs-preview: docs-build
	@echo "Serving the docs at $(DOCS_URL) -- Ctrl-C to stop"
	cd $(DOCS_DIR) && npm run preview

# Screenshots. Every figure references a real .png under docs/src/assets, so replacing one is
# "overwrite the file, rebuild" -- no markdown edit. Files not captured yet hold a generated
# placeholder naming itself, so the build never breaks on a missing shot. Drawing them needs
# Pillow (pip3 install Pillow); without it this is a no-op and the committed ones still build.
#   docs-shots         draw placeholders for any newly referenced image (runs on dev/build too)
#   docs-shots-status  list which screenshots are real and which are still placeholders
docs-shots:
	cd $(DOCS_DIR) && npm run --silent shots

docs-shots-status:
	cd $(DOCS_DIR) && npm run --silent shots:status

docs-clean:
	rm -rf $(DOCS_DIR)/dist $(DOCS_DIR)/.astro
