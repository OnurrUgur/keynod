APP := build/Build/Products/Release/Keynod.app
PHONE_APP := build/Build/Products/Debug-iphoneos/KeynodPhone.app
# The first iPhone that is connected and paired with this Mac; override with PHONE=<id>.
PHONE ?= $(shell xcrun devicectl list devices --hide-default-columns --hide-headers --columns Identifier \
	--filter "(State BEGINSWITH 'connected' OR State BEGINSWITH 'available') AND hardwareProperties.platform == 'iOS'" \
	2>/dev/null | grep -E '^[0-9A-F-]{36}$$' | head -1)

.PHONY: project team build run install link test phone clean

# The value of KEYNOD_TEAM_ID in Local.xcconfig, without spaces or a trailing // comment.
TEAM_ID = $(shell sed -n 's|//.*||; s/^[[:space:]]*KEYNOD_TEAM_ID[[:space:]]*=//p' Local.xcconfig 2>/dev/null | tr -d '[:space:]')
ENTITLEMENTS = $(shell sed -n 's|//.*||; s/^[[:space:]]*KEYNOD_ENTITLEMENTS[[:space:]]*=//p' Local.xcconfig 2>/dev/null | tr -d '[:space:]')

project:
	test -e Local.xcconfig || cp Local.xcconfig.example Local.xcconfig
	xcodegen generate --quiet

# A build without a Team ID starts but can't store secrets (-34018), so signed builds refuse to run without one.
team: project
	@test -n "$(TEAM_ID)" || { \
		echo "KEYNOD_TEAM_ID is empty in Local.xcconfig."; \
		echo "Keynod's Vault needs the Data Protection Keychain, which requires an app signed with your"; \
		echo "Apple Developer Team ID. Set KEYNOD_TEAM_ID (and KEYNOD_ENTITLEMENTS) in Local.xcconfig;"; \
		echo "see Local.xcconfig.example. (make test works without one.)"; \
		exit 1; }
	@test -n "$(ENTITLEMENTS)" || { \
		echo "KEYNOD_ENTITLEMENTS is empty in Local.xcconfig: set it to Keynod/KeynodMac.entitlements"; \
		echo "(Mac only) or Keynod/Keynod.entitlements (with the iPhone companion)."; \
		exit 1; }

build: team
	xcodebuild -project Keynod.xcodeproj -scheme Keynod -configuration Release \
		-derivedDataPath build -allowProvisioningUpdates -quiet build

run: build
	-pkill -x Keynod
	open $(APP)

# Copies the app to /Applications, launches it, and links `keynod` on PATH.
install: build
	-pkill -x Keynod
	rm -rf /Applications/Keynod.app
	cp -R $(APP) /Applications/Keynod.app
	sleep 1
	open /Applications/Keynod.app
	$(MAKE) link

# Puts the `keynod` command on PATH (same binary as the app, run through a symlink).
link:
	mkdir -p ~/.local/bin && ln -sf /Applications/Keynod.app/Contents/MacOS/Keynod ~/.local/bin/keynod

# Protocol, crypto, approval race, lookup, Key Catcher, and Claude hook tests.
test: project
	xcodebuild -project Keynod.xcodeproj -scheme KeynodTests -destination 'platform=macOS' \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet test

# Builds the iPhone companion and installs it on the connected iPhone.
phone: team
	@test -n "$(PHONE)" || { echo "No connected iPhone found (connect it, or pass PHONE=<id>)"; exit 1; }
	xcodebuild -project Keynod.xcodeproj -scheme KeynodPhone -configuration Debug -destination 'generic/platform=iOS' \
		-derivedDataPath build -allowProvisioningUpdates -quiet build
	xcrun devicectl device install app --device $(PHONE) $(PHONE_APP)

clean:
	rm -rf build Keynod.xcodeproj
