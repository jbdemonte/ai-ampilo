#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
python3 scripts/localize.py --check
swift build -c release --disable-sandbox
bin_dir=$(swift build -c release --show-bin-path --disable-sandbox)
mkdir -p build
target="$PWD/build/AIUsage.app"
staging=$(mktemp -d "$PWD/build/.aiusage-bundle.XXXXXX")
cleanup() {
    if [[ -d "$staging/previous.app" && ! -e "$target" && ! -L "$target" ]]; then
        mv "$staging/previous.app" "$target" || return
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
bundle="$staging/AIUsage.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/AIUsage" "$bundle/Contents/MacOS/AIUsage"
cp "$bin_dir/aiusage-cli" "$bundle/Contents/MacOS/aiusage-cli"
cp Sources/AIUsage/Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
ditto "$bin_dir/AIUsage_AIUsageCore.bundle" "$bundle/Contents/Resources/AIUsage_AIUsageCore.bundle"
swift scripts/icon.swift "$staging/AppIcon.iconset"
iconutil -c icns "$staging/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle/Contents/MacOS/aiusage-cli"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
if [[ -e "$target" || -L "$target" ]]; then mv "$target" "$staging/previous.app"; fi
mv "$bundle" "$target"
printf '%s\n' "$target"
