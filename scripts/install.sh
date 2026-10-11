#!/bin/sh
# Build a Release app signed with your Apple Development cert and install it to /Applications.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/macos" && xcodegen generate -q
xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Release -derivedDataPath "$ROOT/build/dd" build -quiet
pkill -x "Agent Island" 2>/dev/null || true
rm -rf "/Applications/Agent Island.app"
cp -R "$ROOT/build/dd/Build/Products/Release/Agent Island.app" /Applications/
echo "Installed /Applications/Agent Island.app"
