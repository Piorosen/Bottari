#!/bin/bash
# Builds the Mac App Store edition (target "Bottari App Store": App Sandbox,
# no Sparkle) and hands it to App Store Connect:
#
#   scripts/appstore.sh           # archive and export a signed .pkg into .build/appstore/
#   scripts/appstore.sh --upload  # the same, then upload it to App Store Connect
#
# Signing and upload use an App Store Connect API key (Users and Access ›
# Integrations › Keys), so Xcode makes the Apple Distribution certificate and
# the Mac App Store profile itself. Settings in Config/appstore.env (see the .example).
# The app record must exist in App Store Connect before the first upload.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=0
[[ "${1:-}" == "--upload" ]] && upload=1
[[ -f Config/appstore.env ]] && source Config/appstore.env
: "${TEAM_ID:?Config/appstore.env 에 TEAM_ID 를 넣어 주세요}"
: "${ASC_KEY_ID:?Config/appstore.env 에 ASC_KEY_ID 를 넣어 주세요}"
: "${ASC_ISSUER_ID:?Config/appstore.env 에 ASC_ISSUER_ID 를 넣어 주세요}"
key_path=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[[ -f "$key_path" ]] || { echo "API 키 파일이 없어요: $key_path" >&2; exit 1; }

out=.build/appstore
derived=.build/xcode-appstore
archive=$out/Bottari.xcarchive
rm -rf "$out"
mkdir -p "$out"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
# Every upload needs a build number of its own.
build_number=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}

step() { printf '\n==> %s\n' "$*"; }

step "보관 (App Store, 빌드 $build_number)"
xcodebuild -project Bottari.xcodeproj -scheme "Bottari App Store" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet \
  archive -archivePath "$archive" "${auth[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CURRENT_PROJECT_VERSION="$build_number" \
  ${BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"} \
  BOTTARI_GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" BOTTARI_GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

step "내보내기"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$( (( upload )) && echo upload || echo export )</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" -exportOptionsPlist "$out/ExportOptions.plist" "${auth[@]}" -quiet

step "끝"
if (( upload )); then
  echo "App Store Connect에 올렸어요. 처리가 끝나면 TestFlight와 앱 심사에 쓸 수 있어요."
else
  ls -lh "$out"/*.pkg
fi
