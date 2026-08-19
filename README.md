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

A real previewer that pretty-prints and colors each record. It replaces the
plain-text preview from Part 1 for `.jsonl`/`.ndjson` only.

```sh
./build-jsonl-preview.sh          # build + install to ~/Applications
./install-dev-utis.sh --no-jsonl  # hand .jsonl over to the extension
open ~/Applications/JSONLPreview.app   # run once to register, then quit
```

Uninstall: `./build-jsonl-preview.sh --uninstall`

### What gets built

No Xcode project. An app extension is a bundle with an `Info.plist` and a
binary, and `swiftc` produces both:

```
~/Applications/JSONLPreview.app
  Contents/Info.plist                    UTImportedTypeDeclarations for jsonl
  Contents/MacOS/JSONLPreview            host app, does nothing
  Contents/PlugIns/JSONLPreviewer.appex  the previewer
```

- `JSONLPreviewApp.swift` is the host. An app extension has to ship inside an
  app, and a UTI has to be declared by something LaunchServices knows about;
  the host exists for those two reasons only.
- `PreviewViewController.swift` builds its view in `loadView()`, so there is no
  nib and no `NSExtensionMainStoryboard` key.
- The appex links with `-e _NSExtensionMain` instead of the usual `main` — the
  one thing about extensions that is not just plist wiring.
- Both bundles are ad-hoc signed with App Sandbox on. Quick Look hands the
  extension a sandbox extension for the file being previewed, so read access to
  that file needs no entitlement of its own.
- The host declares `nl.vincentbruijn.jsonl` itself, duplicating the block in
  `install-dev-utis.sh`. Run the stub with `--no-jsonl` so exactly one bundle
  owns the type; two declarations make which previewer wins a coin toss.

`~/Applications` throughout, so no sudo and no `/Applications` clutter.
LaunchServices scans it and Quick Look loads extensions from there fine.

Check it appears under System Settings → General → Login Items & Extensions →
Quick Look.

### Building it in Xcode instead

If you would rather have a project: new macOS **App** named `JSONLPreview`,
bundle id `nl.vincentbruijn.jsonlpreview`, then File → New → Target → macOS →
**Quick Look Preview Extension** named `JSONLPreviewer`. Delete the generated
`PreviewViewController.xib`, drop in `PreviewViewController.swift` and
`JSONLRenderer.swift`, and copy the two `Info.plist` bodies out of
`build-jsonl-preview.sh`. Sign to Run Locally is fine.

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
pluginkit -m -p com.apple.quicklook.preview -v | grep jsonl
qlmanage -p some.jsonl              # preview in a window, stderr visible
mdls -name kMDItemContentType f     # confirm the UTI resolved
log stream --predicate 'process == "quicklookd" OR process == "QuickLookUIService"'
```

A `dyn.ah62d4rv4…` content type means LaunchServices has not picked up the
declaration. Re-run `lsregister -f`, then log out and back in.
