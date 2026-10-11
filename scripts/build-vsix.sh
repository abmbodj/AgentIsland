#!/bin/sh
# Package vscode-ext/ as a VSIX (a zip with a manifest) without needing node/vsce.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/agent-island-jump.vsix}"
V=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$ROOT/vscode-ext/package.json")
T=$(mktemp -d); mkdir -p "$T/extension"
cp "$ROOT/vscode-ext/package.json" "$ROOT/vscode-ext/extension.js" "$T/extension/"
cat > "$T/[Content_Types].xml" <<X
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
X
cat > "$T/extension.vsixmanifest" <<X
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="agent-island-jump" Version="$V" Publisher="abmbodj"/>
    <DisplayName>Agent Island Jump</DisplayName>
    <Description xml:space="preserve">Lets Agent Island focus the exact integrated terminal running an agent session.</Description>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
X
mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
(cd "$T" && zip -qr "$OUT" "[Content_Types].xml" extension.vsixmanifest extension)
rm -rf "$T"
