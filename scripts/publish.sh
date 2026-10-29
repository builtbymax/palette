#!/bin/zsh
# Publishes a release built by scripts/release.sh as the latest GitHub release: scripts/publish.sh 0.0.1
#
# Tags the commit the release was built from as v<version>. Installed copies find the new appcast.xml at
# releases/latest. The feed is only reachable without signing in while the repository is public.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/publish.sh <version>}"
VERSION="${VERSION#v}"
OUT="dist/releases/$VERSION"
ZIP="$OUT/Palette-$VERSION.zip"
[[ -f "$ZIP" && -f "$OUT/appcast.xml" && -f "$OUT/commit" ]] \
  || { echo "No release in $OUT, run make release VERSION=$VERSION first" >&2; exit 1; }

NOTES=(--generate-notes)
[[ -f "$OUT/Palette-$VERSION.md" ]] && NOTES=(--notes-file "$OUT/Palette-$VERSION.md")
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" "$OUT/appcast.xml" --title "Palette $VERSION" \
  --target "$(cat "$OUT/commit")" $NOTES
