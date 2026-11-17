#!/usr/bin/env bash
# Checks that every SDK declares the version being released. Usage: tools/release/check-version.sh 0.5.0-beta.1
set -euo pipefail

version="${1:?usage: check-version.sh <version>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0

check() {
    local file="$1" found="$2"
    if [[ "$found" == "$version" ]]; then
        echo "ok    $file: $found"
    else
        echo "FAIL  $file: '${found}' is not $version"
        failed=1
    fi
}

check sdks/android/gradle.properties \
    "$(sed -n 's/^version=//p' "$root/sdks/android/gradle.properties" | tr -d '\r')"
check sdks/ios/Sources/DataTalksPush/AppKeys.swift \
    "$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$root/sdks/ios/Sources/DataTalksPush/AppKeys.swift")"
check sdks/ios/Sources/DataTalksPushExtension/DeliveryReporter.swift \
    "$(sed -n 's/.*"datatalks-push-ios\/\([^"]*\)".*/\1/p' "$root/sdks/ios/Sources/DataTalksPushExtension/DeliveryReporter.swift")"
check sdks/maui/Directory.Build.props \
    "$(sed -n 's/.*<Version>\([^<]*\)<\/Version>.*/\1/p' "$root/sdks/maui/Directory.Build.props")"
check sdks/capacitor/package.json \
    "$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$root/sdks/capacitor/package.json" | head -n 1)"
check sdks/capacitor/package-lock.json \
    "$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$root/sdks/capacitor/package-lock.json" | head -n 1)"
check sdks/capacitor/android/build.gradle \
    "$(sed -n "s/.*dataTalksPushVersion = '\([^']*\)'.*/\1/p" "$root/sdks/capacitor/android/build.gradle")"

exit "$failed"
