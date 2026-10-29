#!/bin/bash
# Builds Bottari for distribution outside the App Store:
#
#   1. archive (Release) and export with a Developer ID certificate, hardened runtime
#   2. Bottari-<version>.dmg for first installs: signed, notarized, stapled
#   3. Bottari-<version>.zip of the stapled app, and appcast.xml, for Sparkle
#
#   scripts/release.sh             # needs Config/release.env (see the .example)
#   scripts/release.sh --unsigned  # same steps without signing, to try the pipeline
#
# Everything lands in .build/release/. Publishing is left to you, e.g.
#   gh release create v0.1.0 .build/release/Bottari-0.1.0.dmg .build/release/Bottari-0.1.0.zip .build/release/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

unsigned=0
[[ "${1:-}" == "--unsigned" ]] && unsigned=1
[[ -f Config/release.env ]] && source Config/release.env

out=.build/release
derived=.build/xcode-release
archive=$out/Bottari.xcarchive
rm -rf "$out"
mkdir -p "$out"

step() { printf '\n==> %s\n' "$*"; }

build=(xcodebuild -project Bottari.xcodeproj -scheme Bottari -configuration Release
       -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet)

if (( unsigned )); then
  step "보관 (서명 없이)"
  "${build[@]}" archive -archivePath "$archive" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  ditto "$archive/Products/Applications/Bottari.app" "$out/Bottari.app"
else
  : "${TEAM_ID:?Config/release.env 에 TEAM_ID 를 넣어 주세요}"
  : "${SPARKLE_PUBLIC_KEY:?Config/release.env 에 SPARKLE_PUBLIC_KEY 를 넣어 주세요 (scripts/sparkle-keys.sh)}"
  identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | awk '{print $2}')
  if [[ -z "$identity" ]]; then
    echo "키체인에 팀 $TEAM_ID 의 Developer ID Application 인증서가 없어요." >&2
    exit 1
  fi

  step "보관 (Developer ID)"
  "${build[@]}" archive -archivePath "$archive" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES \
    BOTTARI_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" BOTTARI_UPDATE_FEED_URL="${FEED_URL:-}" \
    BOTTARI_GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" BOTTARI_GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

  step "내보내기"
  cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" -exportOptionsPlist "$out/ExportOptions.plist" -quiet
  codesign --verify --deep --strict "$out/Bottari.app"
fi

app=$out/Bottari.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg=$out/Bottari-$version.dmg
zip=$out/Bottari-$version.zip

step "DMG 만들기"
staging=$out/dmg
mkdir -p "$staging"
ditto "$app" "$staging/Bottari.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Bottari $version" -srcfolder "$staging" -ov -format UDZO -quiet "$dmg"
rm -rf "$staging"

if (( !unsigned )); then
  codesign --sign "$identity" --timestamp "$dmg"

  step "공증 (몇 분 걸려요)"
  xcrun notarytool submit "$dmg" --keychain-profile "${NOTARY_PROFILE:-bottari-notary}" --wait
  xcrun stapler staple "$dmg"
  # The app inside was notarized with the DMG; staple its own copy for the update zip.
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose "$app"
fi

step "Sparkle 업데이트"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
generate_appcast=$(find "$derived" -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' -type f | head -1)
if (( unsigned )); then
  echo "서명하지 않은 빌드라 appcast.xml 은 건너뛰어요. (generate_appcast: ${generate_appcast:-없음})"
else
  updates=$out/updates
  mkdir -p "$updates"
  cp "$zip" "$updates/"
  # Signs the zip with the EdDSA key in your keychain.
  "$generate_appcast" --download-url-prefix "${DOWNLOAD_URL_PREFIX:-https://github.com/Piorosen/Bottari/releases/download}/v$version/" "$updates"
  mv "$updates/appcast.xml" "$out/appcast.xml"
  rm -rf "$updates"
fi

step "끝"
ls -lh "$out" | grep -E 'dmg|zip|appcast' || true
