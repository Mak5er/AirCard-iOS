#!/bin/bash
set -euo pipefail

CONFIG="${1:-Release}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Regenerating Xcode project from project.yml..."
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: XcodeGen is required so newly added sources and test targets are included."
    echo "Install it with: brew install xcodegen"
    exit 1
fi
xcodegen generate

echo "==> Building AirCard-iOS ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

xcodebuild -project AirCard-iOS.xcodeproj \
    -scheme AirCard-iOS \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "AirCard-iOS.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: AirCard-iOS.app not found in DerivedData"
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" build/AirCard-iOS.app

# Clean any existing signature
rm -rf build/AirCard-iOS.app/_CodeSignature
rm -rf build/AirCard-iOS.app/embedded.mobileprovision

mkdir -p build/Payload
cp -R build/AirCard-iOS.app build/Payload/AirCard-iOS.app

cd build
zip -qr "AirCard-iOS.ipa" Payload
rm -rf Payload AirCard-iOS.app

echo "==> Done! IPA generated at: $ROOT/build/AirCard-iOS.ipa"
ls -lh "$ROOT/build/AirCard-iOS.ipa"
