#!/bin/bash
# Builds the native libraries the binding projects wrap, into sdks/maui/native/artifacts. Usage: build-native.sh [android|ios]; both by default.
# The iOS framework needs a Mac. Run it again after a change to sdks/android/push, sdks/ios/Sources or sdks/maui/native/ios.
set -euo pipefail

cd "$(dirname "$0")"
artifacts="$PWD/native/artifacts"
mkdir -p "$artifacts"
target="${1:-all}"

if [ "$target" != "ios" ]; then
    gradle_command="${GRADLE:-../android/gradlew}"
    (cd ../android && "$gradle_command" --console=plain -q :push:assembleRelease)
    cp ../android/push/build/outputs/aar/push-release.aar "$artifacts/"
    echo "Built $artifacts/push-release.aar"
fi

if [ "$target" = "android" ]; then exit 0; fi

if [ "$(uname)" != "Darwin" ]; then
    echo "The iOS framework needs a Mac: skipped."
    exit 0
fi

project=native/ios/DataTalksPushBridge.xcodeproj
archives="$PWD/native/.archives"
rm -rf "$archives" "$artifacts/DataTalksPushBridge.xcframework"

# Built unsigned: the app that embeds the framework signs it.
for platform in "iOS" "iOS Simulator"; do
    xcodebuild archive -quiet -project "$project" -scheme DataTalksPushBridge -destination "generic/platform=$platform" \
        -archivePath "$archives/$platform.xcarchive" -derivedDataPath native/.derived CODE_SIGNING_ALLOWED=NO
done

xcodebuild -create-xcframework \
    -framework "$archives/iOS.xcarchive/Products/Library/Frameworks/DataTalksPushBridge.framework" \
    -framework "$archives/iOS Simulator.xcarchive/Products/Library/Frameworks/DataTalksPushBridge.framework" \
    -output "$artifacts/DataTalksPushBridge.xcframework"

rm -rf "$archives" native/.derived
echo "Built $artifacts/DataTalksPushBridge.xcframework"
