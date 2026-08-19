# Quick Look for YAML and JSONL on macOS

Two independent pieces. Part 1 alone already gives you working previews for both
formats (plain monospace text). Part 2 replaces the JSONL half with a real
previewer that pretty-prints and colors each record.

## Part 1 — UTI declarations (no Xcode needed)

```sh
chmod +x install-dev-utis.sh
./install-dev-utis.sh
```

This writes a stub `~/Applications/DevUTIs.app` whose only purpose is to carry
`UTImportedTypeDeclarations`. LaunchServices reads them, `.yaml`/`.yml` becomes
`public.yaml` and `.jsonl`/`.ndjson` becomes `nl.vincentbruijn.jsonl`, both
conforming to `public.plain-text`. The system text previewer then claims them.

Deliberate choices:

- No `CFBundleDocumentTypes`, so the stub never becomes the default opener for
  these files. Your editor keeps that role.
- JSONL conforms to `public.plain-text`, **not** `public.json`. Conforming to
  JSON would let the built-in JSON previewer claim it, and it would fail —
  JSONL is not valid JSON.
- Bundle lives in `~/Applications`, so no sudo and no `/Applications` clutter.

Uninstall: `./install-dev-utis.sh --uninstall`

If you go on to build Part 2, reinstall with `--no-jsonl` so only one bundle
declares the JSONL type.

## Part 2 — JSONL Quick Look extension

### Create the project

1. Xcode → new macOS **App**, Swift, name `JSONLPreview`, bundle id
   `nl.vincentbruijn.jsonlpreview`. The app itself does nothing; it is a host
   for the extension.
2. File → New → Target → macOS → **Quick Look Preview Extension**, name
   `JSONLPreviewer`. Let Xcode embed it in the host app.
3. Delete the generated `PreviewViewController.xib` and replace the generated
   `PreviewViewController.swift`. Drop both files from this directory into the
   extension target.

### Extension Info.plist

```xml
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
    <string>$(PRODUCT_MODULE_NAME).PreviewViewController</string>
</dict>
```

Remove any `NSExtensionMainStoryboard` / nib key the template added — the
controller builds its view in `loadView()`.

### Host app Info.plist

Copy the `UTImportedTypeDeclarations` array for `nl.vincentbruijn.jsonl` out of
`install-dev-utis.sh` into the **host app's** Info.plist. The extension can only
claim a type that something on the system declares. Then run Part 1 again with
`--no-jsonl` so the stub only owns YAML.

### Install

Signing "Sign to Run Locally" (ad-hoc) is fine. App Sandbox stays on with the
template defaults — Quick Look hands the extension a sandbox extension for the
file it asks you to preview, so no extra entitlement is needed.

```sh
cp -R ~/Library/Developer/Xcode/DerivedData/JSONLPreview-*/Build/Products/Debug/JSONLPreview.app /Applications/
open /Applications/JSONLPreview.app   # run once to register, then quit
qlmanage -r && qlmanage -r cache
```

Check it appears under System Settings → General → Login Items & Extensions →
Quick Look.

## Renderer behavior

- Reads at most 4 MB and renders at most 300 records, whichever comes first.
  `quicklookd` kills slow previews, and session logs get large.
- Header shows filename, record count, file size, and whether output was cut.
- Keys sorted, so diffing two previews by eye actually works.
- A malformed line renders as a red `invalid JSON` marker plus the raw prefix
  instead of aborting the whole preview.

Tune `maxBytes` / `maxRecords` in `JSONLRenderer.render`.

## Debugging

```sh
qlmanage -m plugins                 # what is registered
qlmanage -p some.jsonl              # preview in a window, stderr visible
mdls -name kMDItemContentType f     # confirm the UTI resolved
log stream --predicate 'process == "quicklookd" OR process == "QuickLookUIService"'
```

A `dyn.ah62d4rv4…` content type means LaunchServices has not picked up the
declaration. Re-run `lsregister -f`, then log out and back in.
