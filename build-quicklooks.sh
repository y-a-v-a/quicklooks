#!/usr/bin/env bash
#
# Builds DevQuickLook.app with two Quick Look preview extensions embedded and
# installs it into ~/Applications:
#
#   YAMLPreviewer.appex   public.yaml                          .yaml .yml
#   INIPreviewer.appex    com.microsoft.ini, public.toml       .ini .cfg .config .toml
#   JSONLPreviewer.appex  nl.vincentbruijn.jsonl               .jsonl .ndjson
#
# No Xcode project: an app extension is a bundle with an Info.plist and a
# binary, and swiftc produces both. The only non-obvious part is the entry
# point, which must be NSExtensionMain instead of main.
#
#   ./build-quicklooks.sh              build + install to ~/Applications
#   ./build-quicklooks.sh --build-only build into ./build, do not install
#   ./build-quicklooks.sh --uninstall  remove the installed app
#
set -euo pipefail

APP_NAME="DevQuickLook"
APP_ID="nl.vincentbruijn.devquicklook"
MIN_MACOS="13.0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
DEST="$HOME/Applications/${APP_NAME}.app"
LEGACY="$HOME/Applications/JSONLPreview.app"   # pre-YAML layout
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# name : bundle-id-suffix : comma-separated UTIs : sources
EXTENSIONS=(
  "YAMLPreviewer:yaml:public.yaml:YAMLRenderer.swift YAMLPreviewViewController.swift"
  "INIPreviewer:ini:com.microsoft.ini,public.toml:INIRenderer.swift INIPreviewViewController.swift"
  "JSONLPreviewer:jsonl:nl.vincentbruijn.jsonl:JSONLRenderer.swift JSONLPreviewViewController.swift"
)
SHARED="PreviewStyle.swift TextPreviewController.swift"

unregister() {
  local app="$1"
  [ -d "$app" ] || return 0
  for appex in "$app"/Contents/PlugIns/*.appex; do
    [ -d "$appex" ] && pluginkit -r "$appex" 2>/dev/null || true
  done
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$app" 2>/dev/null || true
  rm -rf "$app"
}

INSTALL=1
case "${1:-}" in
  --uninstall)
    unregister "$DEST"
    unregister "$LEGACY"
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    echo "Removed $DEST"
    exit 0
    ;;
  --build-only) INSTALL=0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac

TARGET="$(uname -m)-apple-macos${MIN_MACOS}"
APP="$BUILD/${APP_NAME}.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns"

# --------------------------------------------------------------- extensions --

for spec in "${EXTENSIONS[@]}"; do
  IFS=":" read -r EXT_NAME SUFFIX UTIS SOURCES <<< "$spec"
  APPEX="$APP/Contents/PlugIns/${EXT_NAME}.appex"
  mkdir -p "$APPEX/Contents/MacOS"

  UTI_XML=""
  while IFS= read -r uti; do
    UTI_XML="${UTI_XML}                <string>${uti}</string>"$'\n'
  done < <(tr ',' '\n' <<< "$UTIS")

  # shellcheck disable=SC2086
  swiftc \
    -target "$TARGET" \
    -module-name "$EXT_NAME" \
    -O \
    -framework Cocoa -framework Quartz \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/$EXT_NAME" \
    $(for f in $SHARED $SOURCES; do echo "$HERE/$f"; done)

  cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${EXT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_ID}.${SUFFIX}</string>
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
${UTI_XML}            </array>
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
  plutil -lint "$APPEX/Contents/Info.plist" >/dev/null
done

# ---------------------------------------------------------------- host app ---

swiftc \
  -target "$TARGET" \
  -module-name "$APP_NAME" \
  -O \
  -framework Cocoa \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$HERE/DevQuickLookApp.swift"

# An extension can only claim a type something on the system declares.
# public.yaml is declared by macOS itself (CoreTypes.bundle), so only JSONL
# needs a declaration here. Keep it in sync with install-dev-utis.sh, and run
# that one with --no-jsonl so exactly one bundle owns the type.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Dev Quick Look</string>
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
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------- signing ----

# App Sandbox is required for app extensions. Quick Look hands the extension a
# sandbox extension for the file being previewed, so read access to that file
# needs no entitlement of its own.
ENTS="$BUILD/sandbox.entitlements"
cat > "$ENTS" <<'PLIST'
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
for appex in "$APP"/Contents/PlugIns/*.appex; do
  codesign --force --sign - --timestamp=none --entitlements "$ENTS" "$appex"
done
codesign --force --sign - --timestamp=none --entitlements "$ENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"

# ---------------------------------------------------------------- install ----

if [ "$INSTALL" -eq 1 ]; then
  unregister "$LEGACY"
  unregister "$DEST"
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$DEST"

  "$LSREGISTER" -f "$DEST"
  for appex in "$DEST"/Contents/PlugIns/*.appex; do
    pluginkit -a "$appex" 2>/dev/null || true
  done
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true

  cat <<EOF

Installed $DEST

Next:
  open "$DEST"          # run once to register, then quit

Verify:
  pluginkit -m -p com.apple.quicklook.preview -v | grep devquicklook
  qlmanage -p some.yaml
EOF
fi
