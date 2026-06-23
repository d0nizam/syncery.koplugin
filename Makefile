# Makefile — Syncery
#
# ALLOWLIST build: this file names ONLY what ships publicly.  The private
# development material (the docs/ folder and PROJECT_PLAN.md) is excluded by
# simply not being listed — it is never named here.
#
#   make build       -> syncery_koplugin.zip   — runtime only, WRAPPED in a
#                       top-level `syncery.koplugin/` folder; the asset attached
#                       to each GitHub Release.  (KOReader loads only directories
#                       whose name ends in `.koplugin`; a flat zip would unpack
#                       to `syncery_koplugin/` with an underscore and NOT load.)
#   make build-full  -> syncery_koplugin_full.zip — the public source tree with
#                       files at the archive ROOT (unwrapped, the way the repo
#                       looks): runtime + spec + tools + Makefile + assets +
#                       .github + .gitignore + README + CHANGELOG + LICENSE.
#   make clean       -> remove both.
#
# Run from the repository root (the plugin directory).  Built from the working
# tree, not git, so uncommitted changes are included.

ZIP_NAME = syncery_koplugin.zip
ZIP_FULL = syncery_koplugin_full.zip
PKG_DIR  = syncery.koplugin
STAGE    = .build

# RUNTIME — exactly what KOReader loads (the lean release).
RUNTIME = _meta.lua main.lua insert_menu.lua LICENSE \
          syncery_i18n.lua syncery_settings.lua syncery_storage_mode.lua \
          syncery_util.lua syncery_update.lua \
          syncery_ann syncery_lifecycle syncery_migration syncery_progress \
          syncery_transports syncery_ui locale

# PUBLIC_EXTRA — ships in the public source repo, but not in the runtime zip.
PUBLIC_EXTRA = README.md SETUP.md CHANGELOG.md Makefile .gitignore .github assets spec tools

# Defensive nested-junk excludes (the allowlist already omits the private docs).
ZIP_EXCLUDES = -x '*/__pycache__/*' -x '*.pyc' -x '*.pristine' \
               -x 'syncery/*' -x '*/syncery/*' -x '$(STAGE)/*' -x '*.zip'

.PHONY: build build-full clean

build:
	@echo ">> Building $(ZIP_NAME) (runtime, unpacks to $(PKG_DIR)/)"
	@rm -rf $(STAGE) $(ZIP_NAME)
	@mkdir -p $(STAGE)/$(PKG_DIR)
	@cp -r $(RUNTIME) $(STAGE)/$(PKG_DIR)/
	@cd $(STAGE) && zip -r -X -q ../$(ZIP_NAME) $(PKG_DIR) $(ZIP_EXCLUDES) -x '*.md'
	@rm -rf $(STAGE)
	@echo ">> Done: $(ZIP_NAME)"

build-full:
	@echo ">> Building $(ZIP_FULL) (public source, files at archive root)"
	@rm -f $(ZIP_FULL)
	@zip -r -X -q $(ZIP_FULL) $(RUNTIME) $(PUBLIC_EXTRA) $(ZIP_EXCLUDES)
	@echo ">> Done: $(ZIP_FULL)"

clean:
	@rm -rf $(STAGE) $(ZIP_NAME) $(ZIP_FULL)
