# Quick Look for config formats on macOS

Space-bar previews, syntax coloured, in `~/Applications` — no sudo, no
`/Applications` clutter.

| Extensions | Type | Previewer |
| --- | --- | --- |
| `.yaml` `.yml` | `public.yaml` | `YAMLPreviewer` |
| `.ini` | `com.microsoft.ini` | `INIPreviewer` |
| `.cfg` `.config` `.toml` | `public.toml` | `INIPreviewer` |
| `.jsonl` `.ndjson` | `nl.vincentbruijn.jsonl` | `JSONLPreviewer` |

```sh
./build-quicklooks.sh
open ~/Applications/DevQuickLook.app   # run once to register, then quit
```

That is the whole thing. Part 1 below is the older, Xcode-free approach; it
still earns its place for JSONL, and is worth reading for why it is not enough.

## Part 1 — UTI declarations (no Xcode needed)

```sh
chmod +x install-dev-utis.sh
./install-dev-utis.sh
```

This writes a stub `~/Applications/DevUTIs.app` whose only purpose is to carry
`UTImportedTypeDeclarations`. LaunchServices reads them, `.yaml`/`.yml` becomes
`public.yaml` and `.jsonl`/`.ndjson` becomes `nl.vincentbruijn.jsonl`.

Deliberate choices:

- No `CFBundleDocumentTypes`, so the stub never becomes the default opener for
  these files. Your editor keeps that role.
- JSONL conforms to `public.plain-text`, **not** `public.json`. Conforming to
  JSON would let the built-in JSON previewer claim it, and it would fail —
  JSONL is not valid JSON. Conforming to plain text is what gets the built-in
  text previewer to render it.
- Bundle lives in `~/Applications`, so no sudo.

Uninstall: `./install-dev-utis.sh --uninstall`

### Why this only works for JSONL

The JSONL half works: nothing else declares that type, so the declaration lands
and the text previewer picks the file up.

The YAML half is inert, and the same trick would fail for INI and TOML. macOS
already declares those types itself, in
`/System/Library/CoreServices/CoreTypes.bundle` and elsewhere, and a *declared*
type beats an *imported* one — the import is ignored. Worse, every one of those
declarations conforms to `public.text`, while the built-in text previewer binds
`public.plain-text`:

```sh
mdls -name kMDItemContentTypeTree some.yaml   # public.text, no public.plain-text
```

| Extension | Resolves to | Conforms to | Previewed? |
| --- | --- | --- | --- |
| `.yaml` `.yml` | `public.yaml` | `public.text` | no |
| `.ini` | `com.microsoft.ini` | `public.text` | no |
| `.cfg` `.config` `.toml` | `public.toml` | `public.text` | no |
| `.jsonl` `.ndjson` | undeclared, so ours lands | `public.plain-text` | yes, as text |

So these files resolve to perfectly good UTIs that no previewer claims, and you
get nothing. There is no fix at the UTI layer: you cannot restate the
conformance of a type you do not own. A preview extension names the type it
handles directly, so conformance stops mattering — which is Part 2.

(Checked on macOS 26.5. `.conf` and `.properties` are still undeclared and
resolve to `dyn.*`; if you want those, declare a UTI for them the way
`install-dev-utis.sh` does for JSONL, and add it to the INI previewer.)

## Part 2 — the preview extensions

```sh
./build-quicklooks.sh          # build + install to ~/Applications
open ~/Applications/DevQuickLook.app   # run once to register, then quit
```

Uninstall: `./build-quicklooks.sh --uninstall`

If you also installed Part 1, reinstall it with `--no-jsonl`. The host app
declares the JSONL type now, and two declarations make which previewer wins a
coin toss. Part 1 is otherwise redundant.

### What gets built

No Xcode project. An app extension is a bundle with an `Info.plist` and a
binary, and `swiftc` produces both:

```
~/Applications/DevQuickLook.app
  Contents/Info.plist                    UTImportedTypeDeclarations for jsonl
  Contents/MacOS/DevQuickLook            host app, does nothing
  Contents/PlugIns/YAMLPreviewer.appex   claims public.yaml
  Contents/PlugIns/INIPreviewer.appex    claims com.microsoft.ini, public.toml
  Contents/PlugIns/JSONLPreviewer.appex  claims nl.vincentbruijn.jsonl
```

- `DevQuickLookApp.swift` is the host. An app extension has to ship inside an
  app, and a UTI has to be declared by something LaunchServices knows about;
  the host exists for those two reasons only.
- Each appex declares its type in `QLSupportedContentTypes` and gets it — an
  extension claims a type by name, so `public.yaml` not conforming to
  `public.plain-text` is no longer an obstacle.
- Only JSONL needs `UTImportedTypeDeclarations` in the host. The others are
  already system types; declaring them again would be ignored anyway.
- One appex can claim several types, which is how `.ini` and `.toml` share a
  previewer.
- `TextPreviewController` builds its view in `loadView()`, so there is no nib
  and no `NSExtensionMainStoryboard` key.
- The appex links with `-e _NSExtensionMain` instead of the usual `main` — the
  one thing about extensions that is not just plist wiring.
- Both bundles are ad-hoc signed with App Sandbox on. Quick Look hands the
  extension a sandbox extension for the file being previewed, so read access to
  that file needs no entitlement of its own.

Check they appear under System Settings → General → Login Items & Extensions →
Quick Look.

### Building it in Xcode instead

If you would rather have a project: new macOS **App** named `DevQuickLook`,
bundle id `nl.vincentbruijn.devquicklook`, then File → New → Target → macOS →
**Quick Look Preview Extension** per format. Delete the generated
`PreviewViewController.xib`, drop in the shared files plus that format's
renderer and controller, and copy the `Info.plist` bodies out of
`build-quicklooks.sh`. Sign to Run Locally is fine.

## Renderer behavior

Shared palette in `PreviewStyle.swift`, so a `.jsonl` and a `.yaml` side by side
in Finder look like they came from the same tool.

### JSONL — `JSONLRenderer.swift`

- Reads at most 4 MB and renders at most 300 records, whichever comes first.
  `quicklookd` kills slow previews, and session logs get large.
- Header shows filename, record count, file size, and whether output was cut.
- Keys sorted, so diffing two previews by eye actually works.
- A malformed line renders as a red `invalid JSON` marker plus the raw prefix
  instead of aborting the whole preview.

Tune `maxBytes` / `maxRecords` in `JSONLRenderer.render`.

### YAML — `YAMLRenderer.swift`

Highlights, does not parse. A parser has to either succeed or fail, and Quick
Look gets pointed at half-written config files constantly; a line-oriented lexer
degrades one line at a time. It also keeps the file's own layout, because with
YAML the indentation, comments and key order are what you came to look at —
re-serialising the way the JSONL side does would lose the point.

Handled, because each one looks like a key or a comment and is not:

- `url: https://host/a:b` — a key colon has to be followed by whitespace.
- `"value # not a comment"` — `#` only opens a comment outside quotes.
- `|` and `>` block scalars, whose more-indented lines stay literal text even
  when they contain `foo:` or `#`. Chomping and indent variants (`|-`, `>+`,
  `|2`) too.
- Anchors, aliases, tags and merge keys: `&base`, `*base`, `!!str`, `<<`.
- Flow collections, including keys inside them: `{a: 1, b: [x, y]}`.
- An unterminated quote colours to end of line instead of running away.

Reads at most 4 MB and 5000 lines. Tune in `YAMLRenderer.render`.

### INI and TOML — `INIRenderer.swift`

Also highlights rather than parses, and keeps the file's layout, for the same
reasons. One lexer covers both, because `[section]` / `key = value` / comment
lines are the same shape either way.

They differ in one place that changes colouring, so the dialect comes from the
extension rather than a sniff:

- Windows INI has **no inline comments**. In `path = C:\tmp ; note` the value
  really is `C:\tmp ; note`, and `php.ini` is full of lines like that. TOML
  ends the value at the `#`.
- Only `.toml` gets TOML rules. `.cfg` and `.config` resolve to `public.toml`
  on macOS but in practice hold configparser-style INI. Being wrong in the INI
  direction only under-colours a comment; being wrong the other way eats half a
  value.

Handled:

- `[section]` and TOML `[[array of tables]]`, anchored on the *first* `]` so a
  trailing `# note ]` does not swallow the line.
- `key = value` and configparser's `key: value`, where the colon has to be
  followed by whitespace — otherwise `C:\Users` and `http://host` would split.
- TOML numbers in full: `1_000_000`, `0xDEADBEEF`, `0o755`, `0b1101`, `-17`,
  and datetimes like `1979-05-27T07:32:00Z`.
- `"""` and `'''` strings, whose lines stay literal even when they contain `foo:`
  or `#`. Single-quoted strings are literal in TOML, so only `"` takes escapes.
- Arrays, inline tables, and the keys inside them: `{ ip = "10.0.0.1" }`.

Section headers are bold, brackets included. They are what you scan a config
file for, and teal-against-blue alone did not separate them from keys at 12pt.

Reads at most 4 MB and 5000 lines. Tune in `INIRenderer.render`.

## Debugging

```sh
qlmanage -m plugins                 # what is registered
pluginkit -m -p com.apple.quicklook.preview -v | grep devquicklook
qlmanage -p some.yaml               # preview in a window, stderr visible
mdls -name kMDItemContentType f     # confirm the UTI resolved
log stream --predicate 'process == "quicklookd" OR process == "QuickLookUIService"'
```

A `dyn.ah62d4rv4…` content type means LaunchServices has not picked up the
declaration. Re-run `lsregister -f`, then log out and back in.
