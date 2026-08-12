#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
developer_dir=${DEVELOPER_DIR:-/Users/tao/Downloads/Xcode-beta.app/Contents/Developer}
build_dir="$project_dir/.build/out/Products/Debug"
app_dir="$build_dir/PhotoAI-Mac.app"

DEVELOPER_DIR="$developer_dir" swift build --package-path "$project_dir"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/PhotoAIMac" "$app_dir/Contents/MacOS/PhotoAIMac"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/PhotoAI-Mac.icns" "$app_dir/Contents/Resources/PhotoAI-Mac.icns"
ditto "$build_dir/PhotoAIMac_PhotoAIMac.bundle" "$app_dir/Contents/Resources/PhotoAIMac_PhotoAIMac.bundle"

open -n "$app_dir"
