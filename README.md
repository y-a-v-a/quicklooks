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

No Xcode project. An app extension is a bundle with an `Info.plist` and a
binary, and `swiftc` produces both:

```
~/Applications/DevQuickLook.app
  Contents/Info.plist                    UTImportedTypeDeclarations for jsonl
  Contents/MacOS/DevQuickLook            host app, does nothing
  Contents/PlugIns/YAMLPreviewer.appex   claims public.yaml
  Contents/PlugIns/INIPreviewer.appex    claims com.microsoft.ini, public.toml
  Contents/PlugIns/JSONPreviewer.appex   claims public.json
  Contents/PlugIns/JSONLPreviewer.appex  claims nl.vincentbruijn.jsonl
```

- The host app exists for two reasons only: an app extension has to ship inside
  an app, and a UTI has to be declared by something LaunchServices knows about.
  It has no other function.
- One appex can claim several types, which is how `.ini` and `.toml` share a
  previewer.
- The appex links with `-e _NSExtensionMain` instead of the usual `main`. This
  is the one part of an app extension that is not plist wiring.
- `TextPreviewController` builds its view in `loadView()`, so there is no nib
  and no `NSExtensionMainStoryboard` key.
- Both bundles are ad-hoc signed with App Sandbox on. Quick Look hands the
  extension a sandbox extension for the file being previewed, so reading that
  file needs no entitlement of its own.
- No `CFBundleDocumentTypes` anywhere, so none of this becomes the default
  opener for your files. Your editor keeps that role.

### Source layout

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

Adding a format means a renderer, a controller subclass, and one line in the
`EXTENSIONS` array in `build-quicklooks.sh`.

### Adding it to an Xcode project instead

New macOS **App** named `DevQuickLook`, bundle id
`nl.vincentbruijn.devquicklook`, then File → New → Target → macOS → **Quick Look
Preview Extension** per format. Delete the generated `PreviewViewController.xib`,
drop in the shared files plus that format's renderer and controller, and copy
the `Info.plist` bodies out of `build-quicklooks.sh`. Sign to Run Locally is
fine.

## The renderers

All four share one palette in `PreviewStyle.swift`, so files of different types
sitting next to each other in Finder look like they came from the same tool.
All read a bounded prefix of the file — `quicklookd` kills slow previews — and
say so in the header when output was cut.

### JSON and JSONL

`JSONValue.swift` holds a hand-written parser because `JSONSerialization` loses
two things worth keeping:

- **Key order.** It returns an unordered dictionary. Sorting is right for JSONL,
  where records are log lines and sorted keys let you diff two previews by eye,
  but alphabetising a `package.json` is the kind of help nobody asked for. So
  `.json` keeps the order the author wrote and `.jsonl` sorts, one `JSONWriter`
  with a `sortKeys` flag.
- **Number text.** Round-tripping through `NSNumber` turns `1.0` into `1`, `1e3`
  into `1000`, and quietly mangles integers past 2^53. The parser keeps each
  number's source text and prints that back. Strings keep their source text too,
  escapes included, so you see what is in the file rather than a re-encoding.

**JSON** parses whole or not at all. On a syntax error the header gives
`invalid JSON at line L, column C` with the reason and still shows the raw text
underneath, so you can go look. Nesting deeper than 128 is refused rather than
recursed into. The header summarises the top level: `object, 14 keys`.

**JSONL** renders at most 300 records. A single malformed line becomes a red
`invalid JSON` marker plus the raw prefix instead of aborting the preview.

### YAML

Highlights rather than parses. A parser has to either succeed or fail, and Quick
Look gets pointed at half-written config files constantly; a line-oriented lexer
degrades one line at a time. It also keeps the file's own layout, because with
YAML the indentation, comments and key order are what you came to look at.

Handled, because each of these looks like markup and is not:

- `url: https://host/a:b` — a key colon has to be followed by whitespace.
- `"value # not a comment"` — `#` only opens a comment outside quotes.
- `|` and `>` block scalars, whose more-indented lines stay literal text even
  when they contain `foo:` or `#`. Chomping and indent variants too: `|-`,
  `>+`, `|2`.
- Anchors, aliases, tags and merge keys: `&base`, `*base`, `!!str`, `<<`.
- Flow collections, including the keys inside them: `{a: 1, b: [x, y]}`.
- An unterminated quote colours to end of line instead of running away.

### INI and TOML

One lexer, because `[section]` / `key = value` / comment lines are the same
shape either way. They differ in one place that changes colouring, so the
dialect comes from the extension rather than a sniff:

- Windows INI has **no inline comments**. In `path = C:\tmp ; note` the value
  really is `C:\tmp ; note`, and `php.ini` is full of lines like that. TOML ends
  the value at the `#`.
- Only `.toml` gets TOML rules. `.cfg` and `.config` resolve to `public.toml` on
  macOS but in practice hold configparser-style INI. Being wrong in the INI
  direction only under-colours a comment; being wrong the other way eats half a
  value.

Also handled:

- `[section]` and TOML `[[array of tables]]`, anchored on the *first* `]` so a
  trailing `# note ]` does not swallow the line. Rendered bold, brackets
  included — sections are what you scan a config file for, and hue alone did
  not separate them from keys at 12pt.
- `key = value` and configparser's `key: value`, where the colon has to be
  followed by whitespace, or `C:\Users` and `http://host` would split.
- TOML numbers in full: `1_000_000`, `0xDEADBEEF`, `0o755`, `0b1101`, `-17`,
  and datetimes like `1979-05-27T07:32:00Z`.
- `"""` and `'''` strings, whose lines stay literal even when they contain
  `foo:` or `#`. Single-quoted strings are literal in TOML, so only `"` takes
  escapes.
- Arrays, inline tables, and the keys inside them: `{ ip = "10.0.0.1" }`.

### Tuning

Byte and record caps are the `maxBytes` / `maxRecords` / `maxLines` defaults on
each `render` function. The palette is `PreviewStyle.swift`.

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
