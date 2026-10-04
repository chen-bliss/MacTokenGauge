#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No Apple account, certificates, signing secrets or notarization service needed.
output_dir="${1:-dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(pwd)/build/Release"
xcodebuild -project ChatGPTGauge.xcodeproj -scheme ChatGPTGauge \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
app="$build_dir/Build/Products/Release/MacTokenGauge.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid application version' >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app"
lipo "$app/Contents/MacOS/MacTokenGauge" -verify_arch arm64
lipo "$app/Contents/MacOS/MacTokenGauge" -verify_arch x86_64
staging=$(mktemp -d "${TMPDIR:-/tmp}/MacTokenGauge.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/MacTokenGauge.app"
ln -s /Applications "$staging/Applications"
cp LICENSE "$staging/LICENSE.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/MacTokenGauge-$version.zip"
hdiutil create -volname MacTokenGauge -srcfolder "$staging" \
  -format UDZO -ov "$output_dir/MacTokenGauge-$version.dmg"
hdiutil verify "$output_dir/MacTokenGauge-$version.dmg"
(
  cd "$output_dir"
  shasum -a 256 "MacTokenGauge-$version.dmg" "MacTokenGauge-$version.zip" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
cat > "$output_dir/BUILD-INFO.txt" <<INFO
MacTokenGauge $version
Commit: $(git rev-parse HEAD)
Working tree changed: $(if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then echo no; else echo yes; fi)
Architectures: arm64, x86_64
Minimum macOS: 14.0
Signing: ad hoc, hardened runtime enabled
Apple notarization: none
$(xcodebuild -version)
INFO
