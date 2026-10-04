#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview_root="$(pwd)/build/Preview.app"
mkdir -p "$preview_root/Contents/MacOS" docs
sources=()
for source in ChatGPTGauge/*.swift; do
  if [[ "$source" != ChatGPTGauge/ChatGPTGaugeApp.swift ]]; then sources+=("$source"); fi
done
swiftc "${sources[@]}" scripts/preview.swift -o "$preview_root/Contents/MacOS/Preview"
cat > "$preview_root/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mactokengauge.preview</string>
<key>CFBundleName</key><string>MacTokenGauge Preview</string>
<key>CFBundleExecutable</key><string>Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$preview_root"
for language in zh en ar; do
  "$preview_root/Contents/MacOS/Preview" "$(pwd)/docs/panel-$language.png" "$language"
done
