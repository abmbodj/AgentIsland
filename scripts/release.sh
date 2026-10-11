#!/bin/sh
# Release: build → sign (hardened runtime) → notarize → staple → DMG → Sparkle appcast → GitHub release.
# Usage: scripts/release.sh 0.1.0 [--dry-run]
# Needs: a "Developer ID Application" cert (falls back to Apple Development, unnotarized),
#        `xcrun notarytool store-credentials AgentIsland` for notarization,
#        the Sparkle EdDSA key in the login keychain (account "agentisland").
set -eu
V="${1:?version}"; DRY="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release/$V"; rm -rf "$OUT"; mkdir -p "$OUT"
SPARKLE="$ROOT/build/tools/sparkle/bin"
if [ ! -x "$SPARKLE/sign_update" ]; then
  SV=2.10.0; mkdir -p "$ROOT/build/tools/sparkle"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SV/Sparkle-$SV.tar.xz" | tar xJ -C "$ROOT/build/tools/sparkle"
fi

IDENTITY="Apple Development"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then IDENTITY="Developer ID Application"; fi
echo "Signing with: $IDENTITY"

cd "$ROOT/macos" && xcodegen generate -q
xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Release -derivedDataPath "$ROOT/build/dd" \
  -archivePath "$OUT/AgentIsland.xcarchive" archive -quiet \
  MARKETING_VERSION="$V" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp"
APP="$OUT/AgentIsland.xcarchive/Products/Applications/Agent Island.app"
codesign --verify --deep --strict "$APP"

DMG="$OUT/AgentIsland-$V.dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Agent Island" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG" || true

if [ "$IDENTITY" = "Developer ID Application" ] && xcrun notarytool history --keychain-profile AgentIsland >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile AgentIsland --wait
  xcrun stapler staple "$DMG"
else
  echo "WARNING: not notarized (needs Developer ID cert + notarytool profile 'AgentIsland')."
fi

mkdir -p "$OUT/appcast"; cp "$DMG" "$OUT/appcast/"
"$SPARKLE/generate_appcast" --account agentisland \
  --download-url-prefix "https://github.com/abmbodj/AgentShelf2/releases/download/v$V/" "$OUT/appcast"
cp "$OUT/appcast/appcast.xml" "$OUT/appcast.xml"
echo "Built: $DMG"; echo "Appcast: $OUT/appcast.xml"

if [ "$DRY" = "--dry-run" ]; then echo "Dry run: not publishing."; exit 0; fi
gh release create "v$V" "$DMG" "$OUT/appcast.xml" --repo abmbodj/AgentShelf2 --title "Agent Island $V" --generate-notes
