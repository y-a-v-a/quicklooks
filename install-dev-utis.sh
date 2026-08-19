#!/usr/bin/env bash
#
# Declares UTIs for .yaml/.yml and .jsonl/.ndjson so that macOS treats them as
# plain text. That is enough for the built-in Quick Look text previewer, the
# Finder preview pane and the Info panel to render them.
#
#   ./install-dev-utis.sh              install (yaml + jsonl)
#   ./install-dev-utis.sh --no-jsonl   install yaml only (use with the JSONL appex)
#   ./install-dev-utis.sh --uninstall  remove
#
set -euo pipefail

APP_NAME="DevUTIs"
BUNDLE_ID="nl.vincentbruijn.devutis"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

WITH_JSONL=1
case "${1:-}" in
  --uninstall)
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP_DIR" 2>/dev/null || true
    rm -rf "$APP_DIR"
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    echo "Removed $APP_DIR"
    exit 0
    ;;
  --no-jsonl) WITH_JSONL=0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

# The bundle never actually runs; LaunchServices only reads its Info.plist.
printf '#!/bin/sh\nexit 0\n' > "$APP_DIR/Contents/MacOS/devutis"
chmod +x "$APP_DIR/Contents/MacOS/devutis"

JSONL_DECL=""
if [ "$WITH_JSONL" -eq 1 ]; then
  JSONL_DECL=$(cat <<'PLIST'
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
PLIST
)
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>devutis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>public.yaml</string>
            <key>UTTypeDescription</key>
            <string>YAML Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>yaml</string>
                    <string>yml</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/yaml</string>
                    <string>text/yaml</string>
                    <string>text/x-yaml</string>
                </array>
            </dict>
        </dict>
${JSONL_DECL}
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP_DIR" 2>/dev/null || echo "note: ad-hoc signing failed, continuing"

"$LSREGISTER" -f "$APP_DIR"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall Finder 2>/dev/null || true

cat <<EOF

Installed $APP_DIR

Verify with:
  mdls -name kMDItemContentType some.yaml     # expect public.yaml
  mdls -name kMDItemContentType some.jsonl    # expect nl.vincentbruijn.jsonl
  qlmanage -p some.yaml

If the UTI still shows as dyn.*, log out and back in: LaunchServices caches
aggressively and lsregister does not always win on the first try.
EOF
