#!/usr/bin/env bash
# Selects the Xcode that the installed .NET for iOS workload requires (it refuses other versions when building an app).
# For CI runners, which ship several Xcode versions and default to the newest. Needs sudo for xcode-select.
set -euo pipefail

packs="${DOTNET_ROOT:-$HOME/.dotnet}/packs"
# The iOS SDK pack is named Microsoft.iOS.Sdk.net10.0_<Xcode version>, e.g. Microsoft.iOS.Sdk.net10.0_26.0.
version=$(ls "$packs" | sed -n 's/^Microsoft\.iOS\.Sdk\.net[0-9.]*_\([0-9][0-9.]*\)$/\1/p' | sort -t. -k1,1n -k2,2n | tail -n 1)
if [[ -z "$version" ]]; then
    echo "No .NET for iOS SDK pack in $packs; install the maui workload first." >&2
    exit 1
fi
echo ".NET for iOS needs Xcode $version"

# GitHub's images link Xcode_<major.minor>.app to the installed patch release, e.g. Xcode_26.0.app to Xcode_26.0.1.app.
app="/Applications/Xcode_$version.app"
if [[ ! -d "$app" ]]; then
    app=$(ls -d /Applications/Xcode_"$version".*.app 2>/dev/null | tail -n 1 || true)
fi
if [[ -z "$app" || ! -d "$app" ]]; then
    echo "This runner has no Xcode $version. Installed:" >&2
    ls -d /Applications/Xcode*.app >&2
    exit 1
fi

sudo xcode-select -s "$app"
xcodebuild -version
