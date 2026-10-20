#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p deploy/ios
if [[ ! -f Resources/iOS/Kokoro/readora-model.json ]]; then
    python3 scripts/prepare-kokoro.py
fi
xcodebuild -project Readora.xcodeproj -scheme ReadoraiOS \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath .build/ios \
    -archivePath "$PWD/deploy/ios/Readora-unsigned.xcarchive" \
    CODE_SIGNING_ALLOWED=NO archive
print '已生成未签名 iOS 归档：deploy/ios/Readora-unsigned.xcarchive'
print '真机安装请在 Xcode 选择 ReadoraiOS、你的 Team 和连接的 iPhone，按 ⌘R。'
