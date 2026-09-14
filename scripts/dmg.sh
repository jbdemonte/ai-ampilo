#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    '') scripts/bundle.sh ;;
    --no-build) ;;
    --help) printf '%s\n' 'Usage: scripts/dmg.sh [--no-build]'; exit 0 ;;
    *) printf '%s\n' 'Usage: scripts/dmg.sh [--no-build]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf '%s\n' 'Too many arguments.' >&2; exit 2; }
app="$PWD/build/AIUsage.app"
[[ -d "$app" ]] || { printf '%s\n' 'Build the app first: make build' >&2; exit 1; }
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
architectures=$(lipo -archs "$app/Contents/MacOS/AIUsage")
architecture="${architectures// /-}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ && "$architecture" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf '%s\n' 'Invalid release metadata.' >&2; exit 1; }
image="$PWD/build/AIUsage-$version-$architecture.dmg"
staging=$(mktemp -d "$PWD/build/.aiusage-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/contents"
ditto "$app" "$staging/contents/AIUsage.app"
ln -s /Applications "$staging/contents/Applications"
cp LICENSE "$staging/contents/LICENSE.txt"
cat > "$staging/contents/Install.txt" <<'EOF'
AI Usage — macOS 14 or later

1. Quit AI Usage if an older version is running.
2. Drag AIUsage.app onto Applications.
3. Open AI Usage from Applications. Its icon appears in the menu bar.

Install and sign in to the official CLI for each provider you want to monitor.
Open Settings in AI Usage to add or rename accounts.

This build is ad-hoc signed, not notarized by Apple. macOS may require explicit
approval for a downloaded app. You can also compile it yourself from source.

Updating the app preserves your accounts, settings and existing CLI sessions.
EOF
hdiutil create -volname 'AI Usage' -srcfolder "$staging/contents" -format UDZO -ov "$staging/AIUsage.dmg"
hdiutil verify "$staging/AIUsage.dmg"
mv -f "$staging/AIUsage.dmg" "$image"
printf '%s\n' "$image"
