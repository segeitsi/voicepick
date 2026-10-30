#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-mesh.sh
app="${BBDV_BUILD_APP_DIR:-build/VoicePick.app}"
mkdir -p build/module-cache "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx15.2 \
  -module-cache-path build/module-cache Sources/*.swift \
  -o "$app/Contents/MacOS/VoicePick"
cp assets/Info.plist "$app/Contents/Info.plist"
if [[ -f assets/drawing-references.json ]]; then
  cp assets/drawing-references.json "$app/Contents/Resources/drawing-references.json"
else
  rm -f "$app/Contents/Resources/drawing-references.json"
fi
mkdir -p "$app/Contents/Resources/FaceMesh"
ditto build/mesh-dist/face-mesh "$app/Contents/Resources/FaceMesh"
cp assets/face-mesh/NOTICE.md "$app/Contents/Resources/FaceMesh/NOTICE.md"
cp assets/face-mesh/requirements-lock.txt "$app/Contents/Resources/FaceMesh/requirements-lock.txt"
ditto assets/face-mesh/licenses "$app/Contents/Resources/FaceMesh/licenses"
codesign --force --sign - --identifier local.oshi.bbdv.face-mesh "$app/Contents/Resources/FaceMesh/face-mesh"
codesign --force --sign - --identifier local.oshi.bbdv "$app"
codesign --verify --deep --strict "$app"
printf 'Готово: %s/%s\n' "$PWD" "$app"
