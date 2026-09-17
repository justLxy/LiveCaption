#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$PWD/XueScribe.app"
legacy_app="$PWD/LumaCaption.app"
if [[ ! -d "$app" && -d "$legacy_app" ]]; then
    mv "$legacy_app" "$app"
fi
if [[ ! -d "$app/Contents/Resources/Runtime" ]]; then
    print -u2 "Missing bundled runtime: $app/Contents/Resources/Runtime"
    exit 1
fi
runtime="$app/Contents/Resources/Runtime"
mkdir -p "$app/Contents/MacOS"
clang++ -O2 -std=c++17 Bridge/asr_bridge.cpp -I Dependencies/include -L "$runtime/nemo/lib" -lnemo_speech_asr_c -Wl,-rpath,@executable_path/../lib -o "$runtime/nemo/bin/asr-bridge"
rm -f "$app/Contents/MacOS/LumaCaption"
swift_sources=(Sources/*.swift)
swift_sources=(${swift_sources:#Sources/LocalSecrets.swift})
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 $swift_sources -o "$app/Contents/MacOS/XueScribe" -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Carbon -framework NaturalLanguage -framework Security
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/NOTICE.txt "$app/Contents/Resources/NOTICE.txt"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "Built: $app"
