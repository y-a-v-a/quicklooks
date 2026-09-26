#!/usr/bin/env bash
#
# Builds DevQuickLook.app with its Quick Look preview extensions embedded and
# installs it into ~/Applications:
#
#   YAMLPreviewer.appex   public.yaml                          .yaml .yml
#   INIPreviewer.appex    com.microsoft.ini, public.toml       .ini .cfg .config .toml
#   JSONPreviewer.appex   public.json, nl.vincentbruijn.jsonc, .json .jsonc .json5
#                         nl.vincentbruijn.json5
#   JSONLPreviewer.appex  nl.vincentbruijn.jsonl               .jsonl .ndjson
#   DockerfilePreviewer   nl.vincentbruijn.dockerfile          *.Dockerfile *.Containerfile
#   DotfilePreviewer      public.data,                         .zshrc .gitconfig Dockerfile,
#                         nl.vincentbruijn.config-text,        .conf .env .go .rs .tf …
#                         nl.vincentbruijn.source-text
#   SQLitePreviewer       nl.vincentbruijn.sqlite              .sqlite .sqlite3 .db .db3 .s3db
#                                                              .sl3 .gpkg .mbtiles
#   PlistPreviewer        com.apple.property-list and the      .plist .entitlements .xcprivacy
#                         Xcode subtypes below                 .stringsdict
#   XMLPreviewer          public.xml,                          .xml .xsd .xsl .xslt .jrxml .wsdl
#                         nl.vincentbruijn.xml-text            .iml .pom
#   ArchivePreviewer      public.zip-archive, java archives,   .zip .jar .war .ear .tar .tgz .gz
#                         tar and gzip
#   ImpexPreviewer        nl.vincentbruijn.impex               .impex
#   ClassFilePreviewer    com.sun.java-class                   .class
#   LogPreviewer          com.apple.log                        .log
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
  "JSONPreviewer:json:public.json,nl.vincentbruijn.jsonc,nl.vincentbruijn.json5:JSONValue.swift JSONLRenderer.swift JSONCRenderer.swift JSONRenderer.swift JSONPreviewViewController.swift"
  "JSONLPreviewer:jsonl:nl.vincentbruijn.jsonl:JSONValue.swift JSONLRenderer.swift JSONLPreviewViewController.swift"
  "DockerfilePreviewer:dockerfile:nl.vincentbruijn.dockerfile:DockerfileRenderer.swift DockerfilePreviewViewController.swift"
  "DotfilePreviewer:dotfile:public.data,nl.vincentbruijn.config-text,nl.vincentbruijn.source-text:DockerfileRenderer.swift INIRenderer.swift YAMLRenderer.swift JSONValue.swift JSONLRenderer.swift JSONCRenderer.swift JSONRenderer.swift PlainTextRenderer.swift SQLiteRenderer.swift DotfileRenderer.swift DotfilePreviewViewController.swift"
  "SQLitePreviewer:sqlite:nl.vincentbruijn.sqlite:SQLiteRenderer.swift SQLitePreviewViewController.swift"
  "PlistPreviewer:plist:com.apple.property-list,com.apple.xcode.entitlements-property-list,com.apple.xcode.app-privacy-property-list,com.apple.xcode.strings-dictionary:ByteReader.swift XMLHighlighter.swift PlistRenderer.swift PlistPreviewViewController.swift"
  "XMLPreviewer:xml:public.xml,nl.vincentbruijn.xml-text:ByteReader.swift XMLHighlighter.swift XMLRenderer.swift XMLPreviewViewController.swift"
  "ArchivePreviewer:archive:public.zip-archive,com.sun.java-archive,com.sun.web-application-archive,nl.vincentbruijn.ear,public.tar-archive,org.gnu.gnu-zip-tar-archive,org.gnu.gnu-zip-archive:ByteReader.swift ClassFileRenderer.swift ArchiveRenderer.swift ArchivePreviewViewController.swift"
  "ImpexPreviewer:impex:nl.vincentbruijn.impex:ByteReader.swift XMLHighlighter.swift XMLRenderer.swift ImpexRenderer.swift ImpexPreviewViewController.swift"
  "ClassFilePreviewer:classfile:com.sun.java-class:ByteReader.swift ClassFileRenderer.swift ClassFilePreviewViewController.swift"
  "LogPreviewer:log:com.apple.log:ByteReader.swift LogRenderer.swift LogPreviewViewController.swift"
)
SHARED="PreviewStyle.swift TextPreviewController.swift"

# Extensions nothing on macOS declares, so they resolve to dyn.* and reach no
# previewer at all — not even a public.data claim. Declared below as two types
# for DotfilePreviewer. Keep in sync with byExtension in DotfileRenderer.swift,
# and check a new one resolves to dyn.* first: declaring an extension the
# system already owns does nothing.
CONFIG_EXTS="env envrc conf properties lock service socket timer mount target desktop
  gitconfig editorconfig npmrc gitignore gitattributes dockerignore tf tfvars hcl nomad"
SOURCE_EXTS="go rs kt kts dart zig gradle groovy scala sc cs fsx jsx cjs v sv svh sol
  prisma cue scss less styl hx vala wgsl cu ino jsonnet libsonnet nix lua hs elm purs
  clj cljs cljc el lisp scm rkt asm vim fish zsh-theme cmake bzl bazel star rake gemspec
  podspec awk sed ps1 psm1 jl ex exs rego just gql graphql vue svelte astro mdx
  vm jsp snap http drl"

ext_xml() {
  for e in $1; do printf '                    <string>%s</string>\n' "$e"; done
}

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
    -framework Cocoa -framework Quartz -lsqlite3 \
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
# public.yaml is declared by macOS itself (CoreTypes.bundle), so only JSONL,
# JSONC, JSON5, SQLite, *.Dockerfile, ImpEx, .ear, the XML dialects and the
# dyn.* extensions need a
# declaration here. Keep JSONL in sync
# with install-dev-utis.sh, and run that one with --no-jsonl so exactly one
# bundle owns the type. Dotfiles and a bare Dockerfile have no extension to
# declare; they resolve to public.data, which DotfilePreviewer claims and
# filters by content.
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
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.jsonc</string>
            <key>UTTypeDescription</key>
            <string>JSON with Comments</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>jsonc</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.json5</string>
            <key>UTTypeDescription</key>
            <string>JSON5 Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>json5</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/json5</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.config-text</string>
            <key>UTTypeDescription</key>
            <string>Configuration File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
$(ext_xml "$CONFIG_EXTS")
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.source-text</string>
            <key>UTTypeDescription</key>
            <string>Source Code</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.source-code</string>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
$(ext_xml "$SOURCE_EXTS")
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.sqlite</string>
            <key>UTTypeDescription</key>
            <string>SQLite Database</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.database</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>sqlite</string>
                    <string>sqlite3</string>
                    <string>db</string>
                    <string>db3</string>
                    <string>s3db</string>
                    <string>sl3</string>
                    <string>gpkg</string>
                    <string>mbtiles</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/vnd.sqlite3</string>
                    <string>application/x-sqlite3</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.dockerfile</string>
            <key>UTTypeDescription</key>
            <string>Dockerfile</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>dockerfile</string>
                    <string>containerfile</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.xml-text</string>
            <key>UTTypeDescription</key>
            <string>XML Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.xml</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>xsd</string>
                    <string>xsl</string>
                    <string>xslt</string>
                    <string>jrxml</string>
                    <string>wsdl</string>
                    <string>iml</string>
                    <string>pom</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.impex</string>
            <key>UTTypeDescription</key>
            <string>SAP Commerce ImpEx Script</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>impex</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>nl.vincentbruijn.ear</string>
            <key>UTTypeDescription</key>
            <string>Java Enterprise Archive</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>com.sun.java-archive</string>
                <string>public.zip-archive</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>ear</string>
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
