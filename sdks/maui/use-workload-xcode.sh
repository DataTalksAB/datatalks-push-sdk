#!/usr/bin/env bash
# Selects the Xcode that the installed .NET for iOS workload requires (it refuses other versions when building an app).
# For CI runners, which ship several Xcode versions and default to the newest. Needs sudo for xcode-select.
set -euo pipefail

packs="${DOTNET_ROOT:-$HOME/.dotnet}/packs"
# The iOS SDK pack is named Microsoft.iOS.Sdk.net10.0_<Xcode version>, e.g. Microsoft.iOS.Sdk.net10.0_26.0.
version=$(ls "$packs" | sed -n 's/^Microsoft\.iOS\.Sdk\.net[0-9.]*_\([0-9][0-9.]*\)$/\1/p' | sort -V | tail -n 1)
if [[ -z "$version" ]]; then
    echo "No .NET for iOS SDK pack in $packs; install the maui workload first." >&2
    exit 1
fi

# Xcode_26.0.app or a patch release of it, such as Xcode_26.0.1.app.
app=$(ls -d /Applications/Xcode_"$version".app /Applications/Xcode_"$version".*.app 2>/dev/null | sort -V | tail -n 1 || true)
if [[ -z "$app" ]]; then
    echo ".NET for iOS needs Xcode $version, which this runner doesn't have. Installed:" >&2
    ls -d /Applications/Xcode*.app >&2
    exit 1
fi

sudo xcode-select -s "$app"
xcodebuild -version
