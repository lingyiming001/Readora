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
python3 - "$app/Contents/Info.plist" <<'PYINFO'
import pathlib, plistlib, re, sys
settings = dict(re.findall(r"^(\w+)\s*=\s*(.+?)\s*$", pathlib.Path("Resources/Readora.xcconfig").read_text(), re.M))
settings["EXECUTABLE_NAME"] = settings["PRODUCT_NAME"]
info = plistlib.loads(pathlib.Path("Resources/Info.plist").read_bytes())
for key, value in info.items():
    if isinstance(value, str):
        info[key] = re.sub(r"\$\((\w+)\)", lambda match: settings[match[1]], value)
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info, sort_keys=False))
PYINFO
codesign --force --sign - "$app/Contents/MacOS/ReadoraMCP"
codesign --force --sign - --entitlements Resources/Readora.entitlements "$app"
if [[ "${READORA_SKIP_LAUNCH:-0}" != "1" ]]; then
    open "$app"
fi
