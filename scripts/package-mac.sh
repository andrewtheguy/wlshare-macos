#!/usr/bin/env bash
#
# Build the app for distribution and wrap it in a drag-to-Applications disk
# image.
#
#   scripts/package-mac.sh     # dist/package/WlshareViewer-macos-arm64.dmg
#
# This is the whole of what .github/workflows/release.yml runs, so a local run
# produces the same image the release carries: there is nothing in the workflow
# that only a runner can do.
#
# Nothing here signs with a Developer ID and nothing is notarized — there is no
# certificate to do either with. The bundle is ad-hoc signed, which is the least
# an arm64 binary needs to run at all, so a downloaded image is quarantined and
# Gatekeeper calls the app damaged. The README has the two ways around that.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

app_name=WlshareViewer
out=dist/package
derived=build/package
dmg="$out/$app_name-macos-arm64.dmg"

command -v xcodebuild >/dev/null || { echo "xcodebuild not found — install Xcode" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

rm -rf "$out" "$derived"
mkdir -p "$out"

./build-core.sh release
xcodegen generate

# Release rather than the Debug ci/ci.sh builds: this is the one people run.
# `-` is the ad-hoc identity, which signs without a certificate.
xcodebuild build \
    -project "$app_name.xcodeproj" \
    -scheme "$app_name" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived/DerivedData" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO

app="$derived/DerivedData/Build/Products/Release/$app_name.app"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
# An arm64 bundle whose signature is missing or broken refuses to launch for a
# reason that has nothing to do with Gatekeeper, and only codesign names it.
codesign --verify --strict "$app"

version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")

stage="$derived/dmg"
mkdir -p "$stage"
# ditto rather than cp -R: it keeps the bundle's symlinks and metadata, and a
# mangled framework layout is a signature that no longer verifies.
/usr/bin/ditto "$app" "$stage/$app_name.app"
ln -s /Applications "$stage/Applications"

# HFS+ named rather than left to hdiutil: the symlink above is what makes the
# mounted window a drag-to-install one, and an APFS image does not mount on
# every macOS that can run this app.
/usr/bin/hdiutil create \
    -volname wlshare \
    -srcfolder "$stage" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$dmg"

(cd "$out" && shasum -a 256 -- *.dmg > SHA256SUMS)
# The release tag is v<this>. It is read back out of the bundle rather than
# parsed out of project.yml so that what is published is what shipped.
printf '%s\n' "$version" > "$out/VERSION"

echo
echo "[package] $dmg ($(du -h "$dmg" | cut -f1)), version $version"
cat "$out/SHA256SUMS"
