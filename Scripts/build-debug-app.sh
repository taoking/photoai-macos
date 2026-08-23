#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
app_directory="$project_directory/.build/PhotoAI-Mac.app"

cd "$project_directory"

swift build --product PhotoAIMac
binary_directory=$(swift build --show-bin-path)

mkdir -p \
    "$app_directory/Contents/MacOS" \
    "$app_directory/Contents/Resources"

install -m 0644 \
    "$project_directory/Resources/Info.plist" \
    "$app_directory/Contents/Info.plist"
install -m 0755 \
    "$binary_directory/PhotoAIMac" \
    "$app_directory/Contents/MacOS/PhotoAIMac"

if [[ -f "$project_directory/Resources/PhotoAI-Mac.icns" ]]; then
    install -m 0644 \
        "$project_directory/Resources/PhotoAI-Mac.icns" \
        "$app_directory/Contents/Resources/PhotoAI-Mac.icns"
fi

codesign --force --deep --sign - "$app_directory"

echo "Built current debug app: $app_directory"
