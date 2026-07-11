HELPER_LABEL := com.eclinick.juice.dev.helper
HELPER_DEST := /Library/PrivilegedHelperTools/$(HELPER_LABEL)
PLIST_SRC := Scripts/dev/$(HELPER_LABEL).plist
PLIST_DEST := /Library/LaunchDaemons/$(HELPER_LABEL).plist
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
DEV_SIGNING_IDENTITY ?= Developer ID Application: Ethan Clinick (U2MBGTFZM5)

.PHONY: build test app app-adhoc verify-app verify-dev-app verify-release-app dmg appcast release-cask publish build-helper-dev dev-helper-install dev-helper-uninstall dev-app-sign dev-probe

build:
	swift build

# Creates and verifies an isolated, Developer-ID-signed development bundle.
# The system helper launch constraints require a real signing identity.
app:
	DEVELOPMENT_BUILD=1 SIGNING_IDENTITY="$(DEV_SIGNING_IDENTITY)" ./Scripts/build-app.sh
	$(MAKE) verify-dev-app

# Useful for inspecting packaging only; its privileged SMAppService helper is
# not expected to launch on systems that enforce signed launch constraints.
app-adhoc:
	DEVELOPMENT_BUILD=1 SIGNING_IDENTITY=- ./Scripts/build-app.sh
	$(MAKE) verify-dev-app

# Verifies the app contains a correctly described, architecture-matched, and
# explicitly signed SMAppService launch daemon.
verify-app:
	$(MAKE) verify-dev-app

verify-dev-app:
	./Scripts/verify-app.sh "dist/Juice Dev.app" development

verify-release-app:
	./Scripts/verify-app.sh "dist/Juice.app" production

# Creates a signed development disk image at dist/Juice Dev.dmg.
dmg:
	DEVELOPMENT_BUILD=1 SIGNING_IDENTITY="$(DEV_SIGNING_IDENTITY)" ./Scripts/create-dmg.sh

# Generates a signed appcast.xml next to the release archives. Pass the
# versioned GitHub release asset URL prefix, for example:
# make appcast APPCAST_DOWNLOAD_URL_PREFIX=https://github.com/EClinick/juice/releases/download/v1.0.0/
appcast:
	./Scripts/generate-appcast.sh

# Builds a universal Developer ID-signed DMG and prints its Homebrew checksum.
release-cask:
	./Scripts/release-cask.sh

# Complete, guarded GitHub + Sparkle + Homebrew release workflow.
# Usage: make publish VERSION=0.1.2
publish:
	./Scripts/publish-release.sh

# Swift Testing is supplied by the full Xcode toolchain, while the active
# developer directory may be Command Line Tools. Prefer the standard Xcode
# install so this reliably runs the actual suite.
test:
	@if [ -d "$(XCODE_DEVELOPER_DIR)" ]; then \
		DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" swift test; \
	else \
		echo "Full Xcode is required to run Juice's Swift Testing suite."; \
		exit 1; \
	fi

build-helper-dev:
	swift build -c release -Xswiftc -DDEV_BUILD -Xswiftc -DDEV_HELPER

# Installs a dev (ad-hoc signed) build of the helper as a launchd daemon.
# Requires sudo. Pairs with an ad-hoc signed app (see dev-app-sign).
dev-helper-install: build-helper-dev
	@echo "WARNING: installs a DEV-signed helper with a weak (identifier-only) client check."
	@echo "WARNING: Local development machines only. Run 'make dev-helper-uninstall' when done."
	sudo launchctl bootout system/$(HELPER_LABEL) 2>/dev/null || true
	sudo cp .build/release/JuiceHelper $(HELPER_DEST)
	sudo chown root:wheel $(HELPER_DEST)
	sudo chmod 755 $(HELPER_DEST)
	sudo codesign --force -s - -i $(HELPER_LABEL) $(HELPER_DEST)
	sudo cp $(PLIST_SRC) $(PLIST_DEST)
	sudo chown root:wheel $(PLIST_DEST)
	sudo chmod 644 $(PLIST_DEST)
	sudo launchctl bootstrap system $(PLIST_DEST)

dev-helper-uninstall:
	# Ignore bootout failure: 'service not loaded' is the expected benign
	# outcome when the helper was never bootstrapped or already removed.
	-sudo launchctl bootout system/$(HELPER_LABEL) 2>/dev/null
	sudo rm -f $(HELPER_DEST) $(PLIST_DEST)

# Ad-hoc signs the debug app build with the bundle identifier the helper's
# dev code-signing requirement expects.
dev-app-sign:
	swift build -Xswiftc -DDEV_BUILD -Xswiftc -DDEV_HELPER
	codesign --force -s - -i com.eclinick.juice.dev .build/debug/Juice

# Build, sign, and run the XPC end-to-end probe against the installed helper.
dev-probe:
	swift build -Xswiftc -DDEV_BUILD -Xswiftc -DDEV_HELPER
	codesign --force -s - -i com.eclinick.juice.dev .build/debug/JuiceXPCProbe
	./.build/debug/JuiceXPCProbe
