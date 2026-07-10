HELPER_LABEL := com.eclinick.juice.helper
HELPER_DEST := /Library/PrivilegedHelperTools/$(HELPER_LABEL)
PLIST_SRC := Scripts/dev/$(HELPER_LABEL).plist
PLIST_DEST := /Library/LaunchDaemons/$(HELPER_LABEL).plist
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: build test app dmg release-cask build-helper-dev dev-helper-install dev-helper-uninstall dev-app-sign

build:
	swift build

# Creates a launchable macOS application bundle at dist/Juice.app. It uses an
# ad-hoc signature by default; provide SIGNING_IDENTITY for a Developer ID build.
app:
	./Scripts/build-app.sh

# Creates a drag-to-Applications disk image at dist/Juice.dmg.
dmg:
	./Scripts/create-dmg.sh

# Builds a universal Developer ID-signed DMG and prints its Homebrew checksum.
release-cask:
	./Scripts/release-cask.sh

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
	swift build -c release -Xswiftc -DDEV_HELPER

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
	codesign --force -s - -i com.eclinick.juice .build/debug/Juice

# Build, sign, and run the XPC end-to-end probe against the installed helper.
dev-probe:
	swift build
	codesign --force -s - -i com.eclinick.juice .build/debug/JuiceXPCProbe
	./.build/debug/JuiceXPCProbe
