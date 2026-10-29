#!/bin/zsh
# Builds a notarized, universal release of Palette plus the Sparkle appcast: scripts/release.sh 0.0.1 [ref]
#
# Builds `ref` (default origin/main, fetched first) from a clean export, not the working tree, so a release is
# exactly a pushed commit and never the GitButler workspace. VERSION in that commit must match.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Notary credentials: xcrun notarytool store-credentials palette-notary --apple-id <id> --team-id <team>
#   3. The Sparkle private key in the login keychain (account "palette"), matching SUPublicEDKey in
#      Resources/Info.plist. Back it up with generate_keys --account palette -x <file>.
#
# Environment:
#   PALETTE_SIGN_IDENTITY   Defaults to the first Developer ID Application identity in the keychain.
#   PALETTE_NOTARY_PROFILE  notarytool keychain profile, defaults to palette-notary.
#
# Output in dist/releases/<version>/: Palette-<version>.zip, its .sha256 and appcast.xml. Release notes go into
# an optional Palette-<version>.md next to the zip before running; Sparkle shows them in the update window.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/release.sh <version> [ref]}"
VERSION="${VERSION#v}"
PROFILE="${PALETTE_NOTARY_PROFILE:-palette-notary}"
IDENTITY="${PALETTE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)}"
[[ "$IDENTITY" == "Developer ID Application"* ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }

REF="${2:-origin/main}"
[[ "$REF" == origin/* ]] && git fetch --quiet origin "${REF#origin/}"
COMMIT="$(git rev-parse --verify "$REF^{commit}")"
[[ "$(git show "$COMMIT:VERSION")" == "$VERSION" ]] \
  || { echo "VERSION in ${COMMIT:0:7} is $(git show "$COMMIT:VERSION"), not $VERSION" >&2; exit 1; }
[[ -n "$(git show "$COMMIT:Resources/Info.plist" | plutil -extract SUPublicEDKey raw - 2>/dev/null)" ]] \
  || { echo "SUPublicEDKey in Resources/Info.plist of ${COMMIT:0:7} is empty" >&2; exit 1; }

WORK="$PWD/dist/release"
SRC="$WORK/src"
rm -rf "$WORK"
mkdir -p "$SRC"
git archive "$COMMIT" | tar -x -C "$SRC"
(cd "$SRC" && PALETTE_SIGN_IDENTITY="$IDENTITY" PALETTE_VERSION="$VERSION" PALETTE_UNIVERSAL=1 \
  scripts/build.sh)
APP="$SRC/dist/Palette.app"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"

# Privacy scan: no file in the bundle, binaries included, may contain this machine's home directory.
if leaks=$(grep -rl --binary-files=text -e "$HOME" "$APP"); then
  echo "Build metadata from this machine in:\n$leaks" >&2
  exit 1
fi

OUT="dist/releases/$VERSION"
ZIP="$OUT/Palette-$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sha256" "$OUT/appcast.xml"

# Notarize, staple the ticket to the app so it also opens offline, then zip the stapled app again. The zip
# leaves out extended attributes and ACLs (provenance, quarantine), which only describe this machine.
ZIP_FLAGS=(-c -k --keepParent --norsrc --noextattr --noacl)
ditto $ZIP_FLAGS "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto $ZIP_FLAGS "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
(cd "$OUT" && shasum -a 256 "Palette-$VERSION.zip" > "Palette-$VERSION.zip.sha256")
echo "$COMMIT" > "$OUT/commit"

# The appcast only lists this release; Sparkle just needs the newest one.
"$SRC/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" --account palette --embed-release-notes \
  --download-url-prefix "https://github.com/builtbymax/palette/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/builtbymax/palette/releases/tag/v$VERSION" "$OUT"

echo "\nPalette $VERSION ($BUILD, ${COMMIT:0:7}) is ready in $OUT. Publish it with: make publish VERSION=$VERSION"
