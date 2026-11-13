#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-release}
swift build -c "$configuration"
bin_dir=$(swift build -c "$configuration" --show-bin-path)
app="$PWD/dist/WYSIWAG.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/WYSIWAG" "$app/Contents/MacOS/WYSIWAG"
cp "$bin_dir/wysiwag-cli" "$app/Contents/MacOS/wysiwag-cli"
# App code resolves packaged Resources explicitly; SwiftPM CLI fallback is beside its executable.
for bundle in "$bin_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
    cp -R "$bundle" "$app/Contents/MacOS/"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WYSIWAG</string>
<key>CFBundleDisplayName</key><string>WYSIWAG</string>
<key>CFBundleIdentifier</key><string>com.wysiwag.app</string>
<key>CFBundleExecutable</key><string>WYSIWAG</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
<key>NSScreenCaptureUsageDescription</key><string>WYSIWAG reads visible text from the active app with on-device OCR.</string>
<key>NSAccessibilityUsageDescription</key><string>WYSIWAG checks whether a secure text field is focused so it can skip capture.</string>
<key>NSDocumentsFolderUsageDescription</key><string>WYSIWAG saves your screen text as daily CSV files in your chosen folder.</string>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/ja.lproj"
cat > "$app/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSScreenCaptureUsageDescription" = "WYSIWAG reads visible text from the active app with on-device OCR.";
"NSAccessibilityUsageDescription" = "WYSIWAG checks whether a secure text field is focused so it can skip capture.";
"NSDocumentsFolderUsageDescription" = "WYSIWAG saves your screen text as daily CSV files in your chosen folder.";
STRINGS
cat > "$app/Contents/Resources/ja.lproj/InfoPlist.strings" <<'STRINGS'
"NSScreenCaptureUsageDescription" = "WYSIWAGは端末内のOCRで、使用中のアプリに表示された文字を読み取ります。";
"NSAccessibilityUsageDescription" = "WYSIWAGはパスワード入力欄にフォーカスがあるか確認し、記録をスキップします。";
"NSDocumentsFolderUsageDescription" = "WYSIWAGは選択したフォルダに、画面の文字を日別CSVとして保存します。";
STRINGS
codesign --force --deep --sign - --identifier com.wysiwag.app "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/wysiwag-cli" check-packaged-resources
printf '%s\n' "$app"
