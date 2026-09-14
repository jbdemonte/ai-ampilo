#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

destination="/Applications"
build_app=true
launch_app=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest-dir)
            [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' 'Missing --dest-dir value.' >&2; exit 2; }
            destination="$2"; shift 2 ;;
        --no-build) build_app=false; shift ;;
        --no-launch) launch_app=false; shift ;;
        --help)
            printf '%s\n' 'Usage: scripts/install.sh [--dest-dir DIRECTORY] [--no-build] [--no-launch]'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$destination" == /* ]] || { printf '%s\n' 'Use an absolute installation directory.' >&2; exit 2; }
if "$build_app"; then scripts/bundle.sh; fi
source_app="$PWD/build/AIUsage.app"
[[ -d "$source_app" ]] || { printf '%s\n' 'Build the app first: make build' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"

mkdir -p "$destination" || { printf '%s\n' 'Try make install INSTALL_DIR="$HOME/Applications" for a per-user installation.' >&2; exit 1; }
destination="$(cd "$destination" && pwd -P)"
target="$destination/AIUsage.app"
[[ "$target" != "$(cd build && pwd -P)/AIUsage.app" ]] || { printf '%s\n' 'The installation directory must differ from the build directory.' >&2; exit 1; }
[[ ! -L "$target" ]] || { printf '%s\n' 'Refusing to replace a symbolic link.' >&2; exit 1; }
if [[ -e "$target" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)
    [[ "$identifier" == 'com.jbd.AIUsage' ]] || { printf '%s\n' 'The destination contains a different app or folder; leaving it untouched.' >&2; exit 1; }
fi

# Stage and verify first. An unsuccessful copy must leave the installed app intact.
staging=$(mktemp -d "$destination/.aiusage-install.XXXXXX")
cleanup() {
    if [[ -d "$staging/previous.app" && ! -e "$target" && ! -L "$target" ]]; then
        mv "$staging/previous.app" "$target" || return
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$source_app" "$staging/AIUsage.app"
codesign --verify --deep --strict "$staging/AIUsage.app"

if [[ -e "$target" ]] || "$launch_app"; then
    # Async shutdown can make AppleScript report -128 even when quitting succeeds.
    if pgrep -x AIUsage >/dev/null; then
        osascript -e 'tell application id "com.jbd.AIUsage" to quit' >/dev/null 2>&1 || true
    fi
    for ((attempt = 0; attempt < 100; attempt++)); do
        if pgrep -x AIUsage >/dev/null; then
            sleep 0.1
        else
            status=$?
            [[ "$status" == 1 ]] || { printf '%s\n' 'Unable to verify that AI Usage has stopped.' >&2; exit 1; }
            break
        fi
    done
    [[ "$attempt" -lt 100 ]] || { printf '%s\n' 'Quit AI Usage before reinstalling.' >&2; exit 1; }
fi
if [[ -e "$target" ]]; then mv "$target" "$staging/previous.app"; fi
mv "$staging/AIUsage.app" "$target"
printf 'Installed: %s\n' "$target"
if "$launch_app"; then open "$target"; fi
