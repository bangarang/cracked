#!/bin/zsh
# Builds Cracked.app in release mode and packages it as a drag-to-Applications DMG.
#
#   scripts/build-dmg.sh                  # ad-hoc signed (users click "Open Anyway" once)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=cracked scripts/build-dmg.sh
#                                         # signed, notarized and stapled
#
# Works with just the Command Line Tools: it builds through a throwaway SwiftPM
# package that points at the app's sources, so Xcode isn't required.
# Output: build/Cracked-<version>.dmg
set -euo pipefail

REPO=${0:A:h:h}
BUILD=$REPO/build
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' $REPO/project.yml)
BUILD_NUMBER=$(sed -n 's/.*CURRENT_PROJECT_VERSION: \([0-9]*\).*/\1/p' $REPO/project.yml)
BUNDLE_ID=com.bangarang.cracked
APP=$BUILD/Cracked.app
DMG=$BUILD/Cracked-$VERSION.dmg

echo "→ Building Cracked $VERSION ($BUILD_NUMBER)"
rm -rf $BUILD/package $APP $BUILD/dmg $DMG
mkdir -p $BUILD/package

# 1. Throwaway SwiftPM package around the app's sources.
ln -s $REPO/Cracked/Sources $BUILD/package/Sources
cat > $BUILD/package/Package.swift <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "Cracked",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .executableTarget(name: "Cracked", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Sources"),
    ]
)
EOF

# 2. Release build: a universal binary when the toolchain can, else this Mac's architecture.
cd $BUILD/package
if swift build -c release --arch arm64 --arch x86_64 >$BUILD/build.log 2>&1; then
    BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    echo "  (universal build unavailable, building for $(uname -m) only)"
    swift build -c release >>$BUILD/build.log 2>&1 || { tail -30 $BUILD/build.log; exit 1; }
    BIN=$(swift build -c release --show-bin-path)
fi
echo "  $(lipo -archs $BIN/Cracked)"

# 3. App bundle.
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/Cracked $APP/Contents/MacOS/
for bundle in $BIN/*.bundle(N); do cp -R $bundle $APP/Contents/Resources/; done
sed -e "s/\$(EXECUTABLE_NAME)/Cracked/; s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/; s/\$(PRODUCT_NAME)/Cracked/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/; s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/en/; s/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/" \
    $REPO/Cracked/Resources/Info.plist > $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" $APP/Contents/Info.plist 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" $APP/Contents/Info.plist
printf 'APPL????' > $APP/Contents/PkgInfo

# App icon from the asset catalog's PNGs (iconutil wants icon_16x16.png, icon_16x16@2x.png…).
ICONSET=$BUILD/AppIcon.iconset
rm -rf $ICONSET && mkdir -p $ICONSET
for png in $REPO/Cracked/Resources/Assets.xcassets/AppIcon.appiconset/*.png; do
    cp $png $ICONSET/${${png:t}/@1x/}
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
rm -rf $ICONSET

# 4. Sign: Developer ID with the hardened runtime if given, else ad-hoc.
ENTITLEMENTS=$REPO/Cracked/Resources/Cracked.entitlements
if [[ -n ${SIGN_IDENTITY:-} ]]; then
    codesign --force --options runtime --timestamp --entitlements $ENTITLEMENTS --sign "$SIGN_IDENTITY" $APP
else
    codesign --force --entitlements $ENTITLEMENTS --sign - $APP
fi
codesign --verify --strict $APP

# 5. DMG: the app next to an Applications shortcut, so installing is one drag.
mkdir -p $BUILD/dmg
cp -R $APP $BUILD/dmg/
ln -s /Applications $BUILD/dmg/Applications
hdiutil create -quiet -volname "Cracked $VERSION" -srcfolder $BUILD/dmg -fs HFS+ -format UDZO -ov $DMG
rm -rf $BUILD/dmg
[[ -n ${SIGN_IDENTITY:-} ]] && codesign --force --timestamp --sign "$SIGN_IDENTITY" $DMG

# 6. Notarize and staple when a notarytool keychain profile is given.
if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $DMG
fi

echo "→ $DMG ($(du -h $DMG | cut -f1))"
shasum -a 256 $DMG
