# Quick Look for config formats on macOS

Space-bar previews for the config and data formats macOS leaves blank or
renders plain, syntax coloured, installed to `~/Applications` — no sudo, no
`/Applications` clutter, no Xcode project.

| Extensions | Type | Previewer | Before |
| --- | --- | --- | --- |
| `.yaml` `.yml` | `public.yaml` | `YAMLPreviewer` | nothing |
| `.ini` | `com.microsoft.ini` | `INIPreviewer` | nothing |
| `.cfg` `.config` `.toml` | `public.toml` | `INIPreviewer` | nothing |
| `.json` | `public.json` | `JSONPreviewer` | plain built-in preview |
| `.jsonl` `.ndjson` | `nl.vincentbruijn.jsonl` | `JSONLPreviewer` | nothing |

Requires macOS 13 or later and Xcode's command line tools for `swiftc`.
Developed and verified on macOS 26.5.

![Quick Look previewing a YAML file: keys in blue, strings in red, numbers in
purple, comments in green, with a line-number gutter and a header showing the
filename, line count and file size.](docs/yaml-preview.png)

## Install

```sh
git clone https://github.com/y-a-v-a/quicklooks.git
cd quicklooks
./build-quicklooks.sh
open ~/Applications/DevQuickLook.app   # run once to register, then quit
```

Then select a file in Finder and press space. Check the previewers appear under
System Settings → General → Login Items & Extensions → Quick Look, where you
can also turn any of them off individually.

```sh
./build-quicklooks.sh --build-only   # build into ./build, do not install
./build-quicklooks.sh --uninstall    # remove it again
```

Sample files with the awkward cases live in `samples/`. Space-bar them after
installing to check nothing regressed.

## Why this is needed at all

Most of these files resolve to a perfectly good type that simply has no
previewer attached.

macOS ships a previewer bound to `public.plain-text`, and a file gets it by
*conforming* to that type. But the system already declares `public.yaml`,
`com.microsoft.ini` and `public.toml` itself, and every one of them conforms to
`public.text` — the parent — rather than to `public.plain-text`:

```sh
mdls -name kMDItemContentTypeTree some.yaml   # public.text, no public.plain-text
```

So the type resolves, nothing claims it, and you get an empty preview pane.

The obvious fix does not work. You can ship a bundle carrying
`UTImportedTypeDeclarations` to restate the conformance, but a **declared** type
beats an **imported** one, so the system's version wins and the import is
ignored. You cannot restate the conformance of a type you do not own.

A Quick Look preview extension names the type it handles directly, in
`QLSupportedContentTypes`. Conformance stops mattering, which is what this
project uses. It also works for a type the system already previews — that is how
`JSONPreviewer` takes `.json` over from the built-in one.

The exception is JSONL. Nothing declares it, so the host app declares
`nl.vincentbruijn.jsonl` in its Info.plist, conforming to `public.plain-text`
and deliberately **not** to `public.json` — a JSONL file is not valid JSON, so
letting the JSON previewer claim it would only produce an error.

## What gets built

No Xcode project. An app extension is an `Info.plist` plus a binary, and
`swiftc` produces both.

```
~/Applications/DevQuickLook.app
  Contents/Info.plist                    UTImportedTypeDeclarations for jsonl
  Contents/MacOS/DevQuickLook            host app, does nothing
  Contents/PlugIns/YAMLPreviewer.appex   claims public.yaml
  Contents/PlugIns/INIPreviewer.appex    claims com.microsoft.ini, public.toml
  Contents/PlugIns/JSONPreviewer.appex   claims public.json
  Contents/PlugIns/JSONLPreviewer.appex  claims nl.vincentbruijn.jsonl
```

The host app exists only because an extension must ship inside an app, and a
UTI must be declared by something LaunchServices knows about. One appex can
claim several types, which is how `.ini` and `.toml` share a previewer. Each
links with `-e _NSExtensionMain` rather than `main` — the one part that is not
plist wiring — and is ad-hoc signed with App Sandbox on. Nothing declares
`CFBundleDocumentTypes`, so your editor stays the default opener.

| File | Role |
| --- | --- |
| `build-quicklooks.sh` | builds, signs and installs everything |
| `DevQuickLookApp.swift` | the host app |
| `PreviewStyle.swift` | shared palette and the `t()` append helper |
| `TextPreviewController.swift` | scrolling monospace view, base class |
| `JSONValue.swift` | order-preserving JSON parser and pretty-printer |
| `*Renderer.swift` | one per format: file bytes to attributed string |
| `*PreviewViewController.swift` | four-line subclass naming its renderer |
| `install-dev-utis.sh` | superseded, see below |

Adding a format takes a renderer, a controller subclass and one line in the
`EXTENSIONS` array. For an Xcode project instead, make one Quick Look Preview
Extension target per format and copy the plist bodies out of that script.

## The renderers

All four share the palette in `PreviewStyle.swift` and read a bounded prefix —
`quicklookd` kills slow previews — noting in the header when output was cut.
Caps are the `render` defaults. Each renderer comments the cases that look like
markup but are not.

**JSON and JSONL** share a hand-written parser. `JSONSerialization` returns an
unordered dictionary and pushes numbers through `NSNumber`, turning `1.0` into
`1`. `JSONValue.swift` keeps both order and source text, and one `sortKeys`
flag decides the rest: JSONL sorts so records diff by eye; `.json` keeps its
author's order. Malformed documents report line and column, and still show it.

**YAML** and **INI/TOML** highlight rather than parse, so half-written files
degrade one line at a time and keep their layout. INI and TOML share a lexer
but split on inline comments — in INI, `path = C:\tmp ; note` is all value — so
the dialect comes from the extension.

## install-dev-utis.sh

The original approach, kept for reference. It writes a stub
`~/Applications/DevUTIs.app` carrying `UTImportedTypeDeclarations` for YAML and
JSONL and nothing else, which needs no Xcode at all.

It is superseded. Its YAML half never worked, for the reason above, and the host
app now declares the JSONL type itself. If you have it installed, remove it:

```sh
./install-dev-utis.sh --uninstall
```

It is still the right tool if you only want a type *declared* rather than
previewed — adding `.conf` or `.properties`, say, which are undeclared and
resolve to `dyn.*`. Declare a UTI for them there, then add it to the relevant
appex in `build-quicklooks.sh`.

## Debugging

```sh
pluginkit -m -p com.apple.quicklook.preview -v | grep devquicklook   # registered?
qlmanage -p some.yaml                     # preview in a window, stderr visible
mdls -name kMDItemContentType some.yaml   # confirm the UTI resolved
qlmanage -r && qlmanage -r cache          # previews are cached per file
log stream --predicate 'process == "quicklookd" OR process == "QuickLookUIService"'
```

A `dyn.ah62d4rv4…` content type means LaunchServices has not picked up a
declaration. Re-run `lsregister -f`, then log out and back in — it caches
aggressively and does not always win on the first try.

---

MIT licensed — see [LICENSE](LICENSE).

© 2026 Vincent Bruijn
