#!/bin/zsh
# Builds dist/Palette.app.
#
#   scripts/build.sh            build and sign
#   scripts/build.sh --install  also replace /Applications/Palette.app and open it
#
# Environment:
#   PALETTE_SIGN_IDENTITY  Signing identity. Defaults to the first Developer ID Application identity, then
#                          Apple Development, then ad-hoc ("-" forces ad-hoc). A stable identity keeps the
#                          Accessibility permission across rebuilds; ad-hoc loses it every time. Developer ID
#                          also turns on the hardened runtime and a secure timestamp, both needed to notarize.
#   PALETTE_VERSION        Marketing version. Defaults to the VERSION file.
#   PALETTE_UNIVERSAL=1    Build for Apple silicon and Intel instead of only this Mac's architecture.
#   PALETTE_BUILD          Build number (CFBundleVersion). Defaults to one derived from the version.
set -euo pipefail
cd "${0:A:h}/.."

ARCH_FLAGS=()
[[ "${PALETTE_UNIVERSAL:-}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release --product Palette $ARCH_FLAGS
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

APP=dist/Palette.app
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources,Frameworks}
cp "$BIN_DIR/Palette" $APP/Contents/MacOS/Palette
# Drop debug and local symbols: they hold the build machine's source and object paths.
strip -S -x $APP/Contents/MacOS/Palette
cp shell/palette.zsh shell/worker.zsh assets/Mark.svg LICENSE $APP/Contents/Resources/
cp -R shell/completions $APP/Contents/Resources/

# Notices for everything bundled besides Palette: Sparkle's license, which lists its own dependencies.
SPARKLE_LICENSE=.build/artifacts/sparkle/Sparkle/LICENSE
[[ -f $SPARKLE_LICENSE ]] || { echo "Missing $SPARKLE_LICENSE" >&2; exit 1; }
SPARKLE_VERSION=$(plutil -extract CFBundleShortVersionString raw "$BIN_DIR/Sparkle.framework/Resources/Info.plist")
{
  print -r -- "Palette includes the following third-party software."
  print -r -- ""
  print -r -- "Sparkle $SPARKLE_VERSION (https://sparkle-project.org)"
  print -r -- ""
  cat $SPARKLE_LICENSE
} > $APP/Contents/Resources/ThirdPartyNotices.txt

# App icon: every size iconutil expects, from the 1024 px master.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p $ICONSET
for size in 16 32 128 256 512; do
  sips -z $size $size assets/AppIcon.png --out $ICONSET/icon_${size}x${size}.png >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/AppIcon.png --out $ICONSET/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
rm -rf ${ICONSET:h}
ditto "$BIN_DIR/Sparkle.framework" $APP/Contents/Frameworks/Sparkle.framework

# Sparkle compares CFBundleVersion to find newer builds, so it must only ever go up. Derive it from the version,
# which doesn't depend on git history: x.y.z -> x*1000000 + y*1000 + z, e.g. 0.1.0 -> 1000, 1.2.3 -> 1002003.
VERSION=${PALETTE_VERSION:-$(<VERSION)}
[[ $VERSION =~ '^([0-9]+)\.([0-9]{1,3})\.([0-9]{1,3})$' ]] || { echo "Version $VERSION isn't x.y.z" >&2; exit 1; }
BUILD=${PALETTE_BUILD:-$(( match[1] * 1000000 + match[2] * 1000 + match[3] ))}
PLIST=$APP/Contents/Info.plist
cp Resources/Info.plist $PLIST
plutil -replace CFBundleShortVersionString -string "$VERSION" $PLIST
plutil -replace CFBundleVersion -string "$BUILD" $PLIST

IDENTITY=${PALETTE_SIGN_IDENTITY:-}
if [[ -z $IDENTITY ]]; then
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
  IDENTITY=$(print -r -- $ids | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
  [[ -n $IDENTITY ]] || IDENTITY=$(print -r -- $ids | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)
  [[ -n $IDENTITY ]] || IDENTITY=-
fi

# Sign inside-out (never --deep): Sparkle's helpers, then the framework, then the app.
SIGN=(codesign --force --sign "$IDENTITY")
[[ $IDENTITY == "Developer ID Application"* ]] && SIGN+=(--options runtime --timestamp)
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
$SIGN $SPARKLE/XPCServices/Installer.xpc
$SIGN --preserve-metadata=entitlements $SPARKLE/XPCServices/Downloader.xpc
$SIGN $SPARKLE/Autoupdate
$SIGN $SPARKLE/Updater.app
$SIGN $APP/Contents/Frameworks/Sparkle.framework
$SIGN $APP
codesign --verify --strict --deep $APP
echo "Built $APP $(plutil -extract CFBundleShortVersionString raw $PLIST) ($(plutil -extract CFBundleVersion raw $PLIST)), signed with ${IDENTITY/#-/ad-hoc}"

if [[ ${1:-} == --install ]]; then
  pkill -x Palette 2>/dev/null && while pgrep -x Palette >/dev/null; do sleep 0.1; done || true
  rm -rf /Applications/Palette.app
  cp -R $APP /Applications/Palette.app
  open /Applications/Palette.app
  echo "Installed /Applications/Palette.app"
fi
