#!/bin/zsh
# Builds build/RateFollower.app (menu-bar only, ad-hoc signed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to ~/Applications and launch
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/build/RateFollower.app"
VERSION="0.1.0"

# Plain swiftc + lipo: needs only a Swift compiler and the macOS SDK
# (Command Line Tools are enough). No SwiftPM, no xcbuild, no Xcode project.
cd "$ROOT"
OBJ="$ROOT/build/obj"
mkdir -p "$OBJ"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    Sources/RateFollower/*.swift -o "$OBJ/RateFollower-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$OBJ/RateFollower-arm64" "$OBJ/RateFollower-x86_64" -output "$APP/Contents/MacOS/RateFollower"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ratefollower</string>
  <key>CFBundleName</key><string>RateFollower</string>
  <key>CFBundleExecutable</key><string>RateFollower</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x RateFollower 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/RateFollower.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/RateFollower.app"
  echo "Installed to ~/Applications and launched"
fi
