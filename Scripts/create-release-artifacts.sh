#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
info_plist="$project_directory/Resources/Info.plist"
output_directory=${PHOTOAI_RELEASE_OUTPUT_DIR:-"$project_directory/dist"}

cd "$project_directory"

if ! git diff --quiet || ! git diff --cached --quiet; then
    print -u2 "Release packaging requires a clean tracked working tree."
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
minimum_system_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")
artifact_name="PhotoAI-Mac-$version-unsigned.app.zip"
checksum_name="PhotoAI-Mac-$version-SHA256.txt"
build_info_name="BUILD-INFO.txt"

mkdir -p "$output_directory"
for path in \
    "$output_directory/$artifact_name" \
    "$output_directory/$checksum_name" \
    "$output_directory/$build_info_name"; do
    if [[ -e "$path" ]]; then
        print -u2 "Refusing to overwrite existing artifact: $path"
        exit 1
    fi
done

swift build --configuration release --product PhotoAIMac
binary_directory=$(swift build --configuration release --show-bin-path)
binary_path="$binary_directory/PhotoAIMac"
resource_bundle="$binary_directory/PhotoAIMac_PhotoAIMac.bundle"

if [[ ! -x "$binary_path" ]]; then
    print -u2 "Release executable was not found: $binary_path"
    exit 1
fi
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "Release resource bundle was not found: $resource_bundle"
    exit 1
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/PhotoAI-Mac-Release.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT
app_path="$temporary_root/PhotoAI-Mac.app"

mkdir -p \
    "$app_path/Contents/MacOS" \
    "$app_path/Contents/Resources"
install -m 0644 "$info_plist" "$app_path/Contents/Info.plist"
install -m 0755 "$binary_path" "$app_path/Contents/MacOS/PhotoAIMac"
install -m 0644 \
    "$project_directory/Resources/PhotoAI-Mac.icns" \
    "$app_path/Contents/Resources/PhotoAI-Mac.icns"
ditto \
    "$resource_bundle" \
    "$app_path/Contents/Resources/PhotoAIMac_PhotoAIMac.bundle"

codesign --force --deep --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ ! -f "$app_path/Contents/Resources/PhotoAI-Mac.icns" ]] || \
   [[ ! -f "$app_path/Contents/Resources/PhotoAIMac_PhotoAIMac.bundle/Contents/Resources/PhotoAI-Logo.png" ]]; then
    print -u2 "Release application is missing required brand resources."
    exit 1
fi

(
    cd "$temporary_root"
    COPYFILE_DISABLE=1 /usr/bin/zip -X -q -r "$output_directory/$artifact_name" "PhotoAI-Mac.app"
)

if /usr/bin/unzip -Z1 "$output_directory/$artifact_name" | \
   /usr/bin/grep -Eq '(^|/)(__MACOSX|\._[^/]+)($|/)'; then
    print -u2 "Release archive unexpectedly contains macOS metadata files."
    exit 1
fi
/usr/bin/unzip -tq "$output_directory/$artifact_name"

(
    cd "$output_directory"
    shasum -a 256 "$artifact_name" > "$checksum_name"
)

{
    print "Product: PhotoAI Mac"
    print "Version: $version"
    print "Build: $build_number"
    print "Bundle Identifier: $bundle_identifier"
    print "Minimum macOS: $minimum_system_version"
    print "Git Commit: $(git rev-parse HEAD)"
    print "Git Branch: $(git branch --show-current)"
    print "Build Configuration: release"
    print "Swift: $(swift --version | sed -n '1p')"
    print "Xcode: $(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    print "Signing: ad-hoc only; no Developer ID, Team ID, or notarization"
    print "Artifact: $artifact_name"
} > "$output_directory/$build_info_name"

print "Created release artifacts:"
print "$output_directory/$artifact_name"
print "$output_directory/$checksum_name"
print "$output_directory/$build_info_name"
