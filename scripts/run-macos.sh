#!/bin/zsh
set -eu
cd "${0:A:h:h}"
CLANG_MODULE_CACHE_PATH=/tmp/readora-clang-cache swift build --disable-sandbox --configuration debug --scratch-path .build --cache-path /tmp/readora-spm-cache
./scripts/generate-app-icon.sh
app="$PWD/deploy/Readora.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/debug/ReadoraMCP "$app/Contents/MacOS/ReadoraMCP"
cp .build/debug/Readora "$app/Contents/MacOS/Readora.next"
mv -f "$app/Contents/MacOS/Readora.next" "$app/Contents/MacOS/Readora"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Readora</string>
<key>CFBundleIdentifier</key><string>local.readora.mac</string>
<key>CFBundleName</key><string>Readora</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>NSMicrophoneUsageDescription</key><string>用于你主动开启的AI语音聊天，将声音识别为文字。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>用于AI语音聊天的中文或英文语音识别，识别文字由你选择发送给大模型。</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/ReadoraMCP"
codesign --force --sign - --entitlements Resources/Readora.entitlements "$app"
if [[ "${READORA_SKIP_LAUNCH:-0}" != "1" ]]; then
    open "$app"
fi
