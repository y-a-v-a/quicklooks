#!/usr/bin/env bash
#
# Builds JSONLPreview.app (host) with JSONLPreviewer.appex (Quick Look preview
# extension) embedded, and installs it into ~/Applications.
#
# No Xcode project: swiftc plus two Info.plists is all an app extension is. The
# only non-obvious part is the appex entry point, which must be NSExtensionMain
# instead of main.
#
#   ./build-jsonl-preview.sh              build + install to ~/Applications
#   ./build-jsonl-preview.sh --build-only build into ./build, do not install
#   ./build-jsonl-preview.sh --uninstall  remove the installed app
#
set -euo pipefail

APP_NAME="JSONLPreview"
EXT_NAME="JSONLPreviewer"
APP_ID="nl.vincentbruijn.jsonlpreview"
EXT_ID="nl.vincentbruijn.jsonlpreview.previewer"
MIN_MACOS="13.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
DEST="$HOME/Applications/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

INSTALL=1
case "${1:-}" in
  --uninstall)
    pluginkit -r "$DEST/Contents/PlugIns/${EXT_NAME}.appex" 2>/dev/null || true
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$DEST" 2>/dev/null || true
    rm -rf "$DEST"
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    echo "Removed $DEST"
    exit 0
    ;;
  --build-only) INSTALL=0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${MIN_MACOS}"

APP="$BUILD/${APP_NAME}.app"
APPEX="$APP/Contents/PlugIns/${EXT_NAME}.appex"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

# ---------------------------------------------------------------- extension --

swiftc \
  -target "$TARGET" \
  -module-name "$EXT_NAME" \
  -O \
  -framework Cocoa -framework Quartz \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/$EXT_NAME" \
  "$HERE/PreviewViewController.swift" "$HERE/JSONLRenderer.swift"

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${EXT_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>JSONL Preview</string>
    <key>CFBundleIdentifier</key>
    <string>${EXT_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${EXT_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>nl.vincentbruijn.jsonl</string>
            </array>
            <key>QLSupportsSearchableItems</key>
            <false/>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>${EXT_NAME}.PreviewViewController</string>
    </dict>
</dict>
</plist>
PLIST

# --------------------------------------------------------------- host app ----

swiftc \
  -target "$TARGET" \
  -module-name "$APP_NAME" \
  -O \
  -framework Cocoa \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$HERE/JSONLPreviewApp.swift"

# The extension can only claim a type something on the system declares, so the
# host app declares it. Keep this in sync with install-dev-utis.sh, and install
# that one with --no-jsonl so only one bundle owns the type.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>JSONL Preview</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.jsonl</string>
            <key>UTTypeDescription</key>
            <string>JSON Lines Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>jsonl</string>
                    <string>ndjson</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/jsonl</string>
                    <string>application/x-ndjson</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APPEX/Contents/Info.plist" >/dev/null
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------- signing ----

# App Sandbox is required for app extensions. Quick Look hands the extension a
# sandbox extension for the file being previewed, so read access to that file
# needs no entitlement of its own.
SANDBOX_ENTS="$BUILD/sandbox.entitlements"
cat > "$SANDBOX_ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
PLIST

# Nested code first, then the container; otherwise the outer seal is stale.
codesign --force --sign - --timestamp=none --entitlements "$SANDBOX_ENTS" "$APPEX"
codesign --force --sign - --timestamp=none --entitlements "$SANDBOX_ENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"

# ---------------------------------------------------------------- install ----

if [ "$INSTALL" -eq 1 ]; then
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$DEST"

  "$LSREGISTER" -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/${EXT_NAME}.appex" 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true

  cat <<EOF

Installed $DEST

Next:
  ./install-dev-utis.sh --no-jsonl     # YAML only; this app now owns .jsonl
  open "$DEST"                         # run once to register, then quit

Verify:
  mdls -name kMDItemContentType some.jsonl   # expect nl.vincentbruijn.jsonl
  qlmanage -p some.jsonl
  pluginkit -m -p com.apple.quicklook.preview -v | grep -i jsonl
EOF
fi
