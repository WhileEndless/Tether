# Tether — common tasks. `make` builds dist/Tether.app; `make help` lists everything.

APP          := dist/Tether.app
VERSION      := $(shell tr -d '[:space:]' < VERSION)
ZIP          := dist/Tether-$(VERSION).zip
INSTALL_DIR  ?= /Applications
# `make install INSTALL_DIR=~/Applications`: the shell leaves ~ alone after =, so expand it here.
override INSTALL_DIR := $(patsubst ~%,$(HOME)%,$(INSTALL_DIR))
NOTES        := release-notes/v$(VERSION).md

.DEFAULT_GOAL := app
.PHONY: help build test app debug run demo install uninstall zip check privacy hooks notes clean version

help: ## Show this help
	@echo "Tether $(VERSION)"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  make            same as make app"

version: ## Print the current version
	@echo $(VERSION)

build: ## Compile all modules (debug)
	swift build

test: ## Run the unit and integration tests
	swift test

app: ## Build the release app into dist/Tether.app (default)
	scripts/build-app.sh release

debug: ## Build a debug app into dist/Tether.app
	scripts/build-app.sh debug

run: app ## Build the release app and open it
	open $(APP)

demo: ## Open the app with synthetic demo data (your data is not used). SHOTS=1 saves screenshots
	scripts/build-app.sh debug demo
	@D=$$(mktemp -d -t tether-demo); T=/tmp/tether-demo-$$(id -u); \
	echo "Demo files in $$D (removed when the demo quits)"; \
	open -W -n "dist/Tether Demo.app" --env TETHER_DEMO="$$D" --env TETHER_SUPPORT_DIR="$$D/support" \
		--env TETHER_DEFAULTS_SUITE=tether.demo --env TETHER_SSH_CONFIG="$$D/ssh_config" --env TETHER_DEMO_TMUX="$$T" \
		$(if $(SHOTS),--env TETHER_DEMO_SHOTS=1) --args -AppleLanguages "(en)" -AppleLocale en_US; \
	if [ -d "$$D/shots" ]; then mkdir -p dist/screenshots && cp "$$D"/shots/*.png dist/screenshots/ && echo "Screenshots in dist/screenshots"; fi; \
	for s in "$$T"/tmux-*/*; do [ -S "$$s" ] && TMUX= "$$D/bin/tmux" -S "$$s" kill-server 2>/dev/null; done; \
	rm -rf "$$D" "$$T"; defaults delete tether.demo >/dev/null 2>&1; true

install: app ## Build and copy Tether.app to /Applications (INSTALL_DIR=… to change)
	@if pgrep -qf "$(INSTALL_DIR)/Tether.app/Contents/MacOS/Tether"; then echo "Quit Tether first, then run make install again."; exit 1; fi
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Tether.app"
	ditto $(APP) "$(INSTALL_DIR)/Tether.app"
	@echo "Installed to $(INSTALL_DIR)/Tether.app"

uninstall: ## Remove Tether.app from /Applications (settings and recordings are kept)
	rm -rf "$(INSTALL_DIR)/Tether.app"
	@echo "Removed. Your data is still in ~/Library/Application Support/Tether."

zip: ## Package dist/Tether-<version>.zip for a GitHub release (Apple silicon and Intel)
	UNIVERSAL=1 scripts/build-app.sh release
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Created $(ZIP)"

notes: ## Check that release notes exist for the current version
	@test -f $(NOTES) || { echo "Missing $(NOTES) — copy release-notes/TEMPLATE.md"; exit 1; }
	@echo "Found $(NOTES)"

privacy: ## Look for personal data and secrets (API keys, tokens, private keys) that must not be published
	@scripts/privacy.sh

hooks: ## Run the privacy check before every commit (git pre-commit hook)
	git config core.hooksPath scripts/git-hooks
	@echo "Commits now run scripts/privacy.sh first."

check: privacy notes test ## Everything that must pass before a release

clean: ## Remove build products
	rm -rf .build dist
