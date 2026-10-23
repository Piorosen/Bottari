PROJECT := Bottari.xcodeproj
SCHEME := Bottari
DERIVED := .build/xcode
DESTINATION := platform=macOS,arch=$(shell uname -m)
APP := $(DERIVED)/Build/Products/Debug/Bottari.app

.PHONY: build test run open clean

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

clean:
	rm -rf .build Packages/BottariKit/.build
