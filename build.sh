#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$PWD/LumaCaption.app"
runtime="$app/Contents/Resources/Runtime"
mkdir -p "$app/Contents/MacOS"
clang++ -O2 -std=c++17 Bridge/asr_bridge.cpp -I Dependencies/include -L "$runtime/nemo/lib" -lnemo_speech_asr_c -Wl,-rpath,@executable_path/../lib -o "$runtime/nemo/bin/asr-bridge"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 Sources/*.swift -o "$app/Contents/MacOS/LumaCaption" -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Carbon
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "Built: $app"
