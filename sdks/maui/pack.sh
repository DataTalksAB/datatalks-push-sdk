#!/bin/bash
# Packs the three NuGet packages, the two bindings and the wrapper, into sdks/maui/native/artifacts/nupkg at the version in
# sdks/maui/Directory.Build.props. Extra arguments go to every dotnet pack, for example -p:Version=0.5.0-beta.2.
# Both native builds must exist first (build-native.sh). The iOS framework is built on a Mac; a copy of it also packs on
# Windows. Without it the wrapper would ship without iOS, so the script stops.
set -euo pipefail

cd "$(dirname "$0")"
artifacts="$PWD/native/artifacts"
out="$artifacts/nupkg"

if [ ! -f "$artifacts/push-release.aar" ]; then
    echo "No $artifacts/push-release.aar: run build-native.sh first." >&2
    exit 1
fi

if [ ! -d "$artifacts/DataTalksPushBridge.xcframework" ]; then
    echo "No $artifacts/DataTalksPushBridge.xcframework: run build-native.sh on a Mac, or copy it from one." >&2
    exit 1
fi

rm -rf "$out"
# One at a time: the wrapper's package refers to the bindings' at the same version.
for project in src/DataTalks.Push.Android.Binding src/DataTalks.Push.iOS.Binding src/DataTalks.Push.Maui; do
    dotnet pack "$project" -c Release -o "$out" --nologo -v:q "$@"
done

ls "$out"
