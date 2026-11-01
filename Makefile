PROJECT := Bottari.xcodeproj
SCHEME := Bottari
# Outside the checkout: macOS guards ~/Desktop, ~/Documents and ~/Downloads,
# and an app built inside one of them asks for that folder each time it runs.
DERIVED ?= $(HOME)/Library/Developer/Xcode/DerivedData/Bottari-make
DESTINATION := platform=macOS,arch=$(shell uname -m)
APP := $(DERIVED)/Build/Products/Debug/Bottari.app

# Sign Debug builds with the Mac's Apple Development certificate when there is
# one. An ad-hoc signature changes with every build, so macOS forgets what the
# user allowed (folder access, Keychain items) and asks again; a certificate
# keeps the app the same app from build to build.
DEV_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
ifneq ($(DEV_TEAM),)
SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=$(DEV_TEAM)
endif

.PHONY: build test run open clean snapshots archive testflight

# Build the app (Debug) without opening Xcode.
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED)" -quiet build $(SIGNING)

# Core package tests. To run them inside Xcode, open Packages/BottariKit/Package.swift and press ⌘U.
test:
	swift test --package-path Packages/BottariKit

run: build
	open "$(APP)"

# Every screen drawn with sample data into SHOTS, with self-checks in *-check.txt.
# The app runs in the App Sandbox, which lets it write only inside its container.
SHOTS ?= $(HOME)/Library/Containers/io.github.piorosen.bottari.appstore/Data/tmp/bottari-shots
snapshots: build
	rm -rf "$(SHOTS)"
	open -n -g -j -W "$(APP)" --args -renderSnapshots "$(SHOTS)"
	@grep -h '^FAIL' "$(SHOTS)"/*-check.txt && exit 1 || echo "스냅샷: $(SHOTS)"

open:
	open $(PROJECT)

# Signed for the App Store, into .build/appstore (see Config/appstore.env.example).
archive:
	scripts/testflight.sh

# The same, uploaded to App Store Connect for TestFlight. The only way Bottari ships.
testflight:
	scripts/testflight.sh --upload

clean:
	rm -rf .build Packages/BottariKit/.build "$(DERIVED)"
