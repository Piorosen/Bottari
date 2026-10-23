PROJECT := Bottari.xcodeproj
SCHEME := Bottari
DERIVED := .build/xcode
DESTINATION := platform=macOS,arch=$(shell uname -m)
APP := $(DERIVED)/Build/Products/Debug/Bottari.app

.PHONY: build test run open clean release package

# Build the app (Debug) without opening Xcode.
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination "$(DESTINATION)" -derivedDataPath $(DERIVED) -quiet build

# Core package tests. To run them inside Xcode, open Packages/BottariKit/Package.swift and press ⌘U.
test:
	swift test --package-path Packages/BottariKit

run: build
	open $(APP)

open:
	open $(PROJECT)

# Signed, notarized DMG plus the Sparkle zip and appcast (see Config/release.env.example).
release:
	scripts/release.sh

# The same steps without signing, to try the pipeline.
package:
	scripts/release.sh --unsigned

clean:
	rm -rf .build Packages/BottariKit/.build
