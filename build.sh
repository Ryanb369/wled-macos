#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
app="$root/build/WLED Control.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"
/usr/bin/swiftc -parse-as-library -swift-version 5 -O \
  -framework AppKit -framework SwiftUI -framework Foundation \
  "$root"/Sources/*.swift -o "$app/Contents/MacOS/WLEDControl"
/bin/chmod 755 "$app/Contents/MacOS/WLEDControl"
/usr/bin/codesign --force --sign - "$app"
echo "Built $app"
