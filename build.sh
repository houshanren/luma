#!/bin/sh
set -eu
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Luma.app"
EXEC="Luma"

swift build -c "$CONFIG" --product PhotosClone
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/PhotosClone"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/$EXEC"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成 $APP"
