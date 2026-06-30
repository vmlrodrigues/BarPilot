# BarPilot — build & distribution
#
#   make local                  Ad-hoc local/dev build  -> ./BarPilot.app
#   make run                    Launch ./BarPilot.app
#   make release VERSION=0.1.0  Developer ID sign + notarise + DMG + GitHub release
#   make check                  Verify tools + signing certificate
#   make clean                  Remove build artifacts
#
# Distribution requires (one-time): a "Developer ID Application" certificate in
# your keychain, a notarytool keychain profile, create-dmg, and gh.
# See holding/DISTRIBUTION_SETUP.md.

APP          := BarPilot.app
DMG_NAME     := BarPilot.dmg
ENTITLEMENTS := $(CURDIR)/BarPilot.entitlements
STAGING      := $(CURDIR)/.release-staging

# Version: single source of truth is the VERSION file; override on the CLI.
VERSION ?= $(shell cat $(CURDIR)/VERSION 2>/dev/null || echo "0.0.0")

# Apple distribution config (same Developer ID / Team as my other apps).
RELEASE_SIGN_IDENTITY := Developer ID Application: Victor Rodrigues (9N354A3UZK)
RELEASE_TEAM          := 9N354A3UZK
NOTARIZE_PROFILE      := barpilot-notarization

# Push with the gh-authenticated account (avoids stale keychain creds 403ing).
GIT_PUSH := git -c credential.helper="" -c credential.helper="!gh auth git-credential" push

.PHONY: all local run release check clean help

all: local

help:
	@echo "BarPilot targets:"
	@echo "  local                    Ad-hoc local build   -> ./$(APP)"
	@echo "  run                      Launch ./$(APP)"
	@echo "  release VERSION=x.y.z    Developer ID sign + notarise + DMG + GitHub release"
	@echo "  check                    Verify tools + signing certificate"
	@echo "  clean                    Remove build artifacts"

local:
	./build-app.sh

run:
	@open ./$(APP) 2>/dev/null || { echo "Build first:  make local"; exit 1; }

check:
	@command -v swift >/dev/null 2>&1 || { echo "x swift not found (install Xcode Command Line Tools)"; exit 1; }
	@command -v create-dmg >/dev/null 2>&1 || { echo "x create-dmg not found - run: brew install create-dmg"; exit 1; }
	@command -v gh >/dev/null 2>&1 || { echo "x gh not found - run: brew install gh"; exit 1; }
	@xcrun --find notarytool >/dev/null 2>&1 || { echo "x notarytool not found (need Xcode / CLT 13+)"; exit 1; }
	@security find-identity -v -p codesigning | grep -q "$(RELEASE_SIGN_IDENTITY)" || { echo "x Developer ID cert not in keychain. Expected:"; echo "    $(RELEASE_SIGN_IDENTITY)"; exit 1; }
	@echo "OK - all release prerequisites present."

release: check
	@[ "$(VERSION)" != "0.0.0" ] || { echo "Set a version:  make release VERSION=x.y.z  (or edit ./VERSION)"; exit 1; }
	@echo "=== Building BarPilot $(VERSION) for distribution ==="
	@rm -rf "$(STAGING)" "$(DMG_NAME)" && mkdir -p "$(STAGING)"
	@echo "-> Building + signing (Developer ID . Hardened Runtime)..."
	SIGN_IDENTITY="$(RELEASE_SIGN_IDENTITY)" ENTITLEMENTS="$(ENTITLEMENTS)" HARDENED=1 VERSION="$(VERSION)" ./build-app.sh
	@echo "-> Verifying signature..."
	@codesign --verify --deep --strict --verbose=2 "$(APP)"
	@codesign -dvv "$(APP)" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|runtime" || true
	@echo "-> Notarising + stapling the APP (so self-update verifies offline, not via a live Apple call)..."
	@rm -f "$(CURDIR)/.notarize-app.zip"
	@ditto -c -k --keepParent "$(APP)" "$(CURDIR)/.notarize-app.zip"
	xcrun notarytool submit "$(CURDIR)/.notarize-app.zip" --keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(APP)"
	@rm -f "$(CURDIR)/.notarize-app.zip"
	@xcrun stapler validate "$(APP)" && echo "   app stapled: OK" || { echo "x app stapling failed - aborting"; exit 1; }
	@echo "-> Staging app + building DMG..."
	@ditto "$(APP)" "$(STAGING)/$(APP)"
	create-dmg --volname "BarPilot $(VERSION)" --window-pos 200 120 --window-size 540 380 --icon-size 128 --icon "$(APP)" 150 185 --hide-extension "$(APP)" --app-drop-link 390 185 "$(DMG_NAME)" "$(STAGING)/"
	@echo "-> Notarising DMG (a few minutes)..."
	xcrun notarytool submit "$(DMG_NAME)" --keychain-profile "$(NOTARIZE_PROFILE)" --wait
	@echo "-> Stapling ticket..."
	xcrun stapler staple "$(DMG_NAME)"
	@echo "-> Gatekeeper check..."
	@xcrun stapler validate "$(DMG_NAME)" && echo "   stapler: OK"
	@spctl --assess --type open --context context:primary-signature --ignore-cache "$(STAGING)/$(APP)" && echo "   Gatekeeper: OK" || echo "   WARNING: Gatekeeper check failed - review signing/entitlements"
	@echo "-> Tagging + publishing GitHub release..."
	git tag "v$(VERSION)"
	$(GIT_PUSH) origin main "v$(VERSION)"
	gh release create "v$(VERSION)" --title "BarPilot v$(VERSION)" --notes "BarPilot v$(VERSION). Download the DMG below and drag BarPilot to Applications." "$(DMG_NAME)"
	@rm -rf "$(STAGING)"
	@echo "=== Released v$(VERSION) -> https://github.com/vmlrodrigues/BarPilot/releases/tag/v$(VERSION) ==="

clean:
	@rm -rf .build "$(APP)" "$(DMG_NAME)" "$(STAGING)"
	@echo "Cleaned."
