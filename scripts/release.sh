#!/bin/bash
# Build a signed, notarized Apple Silicon DMG from a clean commit. Never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity in your Keychain}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile}"
for tool in xcodegen xcodebuild xcrun codesign security hdiutil ditto python3; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash changes before releasing. The artifact must match a clean commit." >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep 'Developer ID Application:' | grep -Fq "$SIGN_IDENTITY"; then
    echo "No matching Developer ID Application certificate is available." >&2
    exit 1
fi
# Validate the stored profile without printing or exporting its credentials.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
commit=$(git rev-parse HEAD)
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/release.XXXXXX")
cleanup() {
    local status=$?
    if [[ "$status" == 0 ]]; then rm -rf "$stage"
    else echo "Release failed. Diagnostic files remain in $stage" >&2
    fi
}
trap cleanup EXIT

xcodegen generate
xcodebuild -scheme BuildMate -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$stage/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_DEBUG_DYLIB=NO build
app="$stage/build/Build/Products/Release/Build Mate.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a MAJOR.MINOR.PATCH version." >&2; exit 1; }
[[ "$(lipo -archs "$app/Contents/MacOS/BuildMate")" == arm64 ]] || { echo "Expected an arm64-only binary." >&2; exit 1; }
[[ -f "$app/Contents/Resources/ThirdPartyNotices.txt" ]] || { echo "Missing dependency license notices." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :BuildMateSourceRevision string $commit" "$app/Contents/Info.plist"

# GRDB is statically linked. Refuse unexpected nested executable code until its signing is accounted for.
while IFS= read -r -d '' item; do
    if [[ "$item" != "$app/Contents/MacOS/BuildMate" ]] && file -b "$item" | grep -q 'Mach-O'; then
        echo "Unexpected nested code needs an explicit signing step: $item" >&2
        exit 1
    fi
done < <(find "$app" -type f -print0)
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
    local file="$1" report="$2"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$report"
    python3 - "$report" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; inspect ' + sys.argv[1])
print('Notarization accepted: ' + result['id'])
PY
}

# Staple the app before packaging so the copied app carries its own offline ticket.
ditto -c -k --keepParent "$app" "$stage/BuildMate.zip"
notarize "$stage/BuildMate.zip" "$stage/app-notary.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$stage/image"
ditto "$app" "$stage/image/Build Mate.app"
ln -s /Applications "$stage/image/Applications"
filename="Build-Mate-$version-arm64.dmg"
hdiutil create -volname "Build Mate $version" -srcfolder "$stage/image" -format UDZO "$stage/$filename"
codesign --timestamp --sign "$SIGN_IDENTITY" "$stage/$filename"
notarize "$stage/$filename" "$stage/dmg-notary.json"
xcrun stapler staple "$stage/$filename"
xcrun stapler validate "$stage/$filename"
codesign --verify --strict "$stage/$filename"
spctl --assess --type open --context context:primary-signature --verbose=2 "$stage/$filename"

# Publishable files appear in dist only after every check above succeeds.
output="$PWD/dist/$version"
if [[ -e "$output" ]]; then
    echo "Release output already exists: $output. Preserve it or move it aside before rebuilding." >&2
    exit 1
fi
mkdir "$stage/output"
mv "$stage/$filename" "$stage/output/"
cp "$stage/app-notary.json" "$stage/dmg-notary.json" "$stage/output/"
printf 'Build Mate %s (%s)\nSource commit: %s\nArchitecture: arm64\nMinimum macOS: 26.0\n' "$version" "$build" "$commit" > "$stage/output/BUILD.txt"
(cd "$stage/output" && shasum -a 256 "$filename" > SHA256SUMS)
mv "$stage/output" "$output"
echo "Release ready: $output/$filename"
echo "Source commit: $commit"
echo "No tag or GitHub release has been created. Follow docs/releasing.md."
