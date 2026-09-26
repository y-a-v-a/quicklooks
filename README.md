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
| `.jsonc` `.json5` | `nl.vincentbruijn.jsonc`, `nl.vincentbruijn.json5` | `JSONPreviewer` | nothing |
| `.jsonl` `.ndjson` | `nl.vincentbruijn.jsonl` | `JSONLPreviewer` | nothing |
| `*.Dockerfile` `*.Containerfile` | `nl.vincentbruijn.dockerfile` | `DockerfilePreviewer` | nothing |
| dotfiles, `Dockerfile`, `Brewfile` and other extensionless text | `public.data` | `DotfilePreviewer` | nothing |
| `.conf` `.env` `.tf` `.lock` `.properties` `.service` … | `nl.vincentbruijn.config-text` | `DotfilePreviewer` | nothing |
| `.go` `.rs` `.kt` `.dart` `.zig` `.lua` `.nix` `.vue` `.vm` `.jsp` `.snap` `.http` `.drl` … | `nl.vincentbruijn.source-text` | `DotfilePreviewer` | nothing |
| `.sqlite` `.sqlite3` `.db` `.db3` `.s3db` `.sl3` `.gpkg` `.mbtiles` | `nl.vincentbruijn.sqlite` | `SQLitePreviewer` | nothing |
| `.plist` `.entitlements` `.xcprivacy` `.stringsdict` | `com.apple.property-list` and its Xcode subtypes | `PlistPreviewer` | plain built-in preview |
| `.xml` | `public.xml` | `XMLPreviewer` | plain built-in preview |
| `.xsd` `.xsl` `.xslt` `.jrxml` `.wsdl` `.iml` `.pom` | `nl.vincentbruijn.xml-text` | `XMLPreviewer` | nothing |
| `.zip` `.jar` `.war` `.ear` | `public.zip-archive`, `com.sun.java-archive`, `com.sun.web-application-archive`, `nl.vincentbruijn.ear` | `ArchivePreviewer` | icon only |
| `.tar` `.tgz` `.tar.gz` `.gz` | `public.tar-archive`, `org.gnu.gnu-zip-tar-archive`, `org.gnu.gnu-zip-archive` | `ArchivePreviewer` | icon only |
| `.class` | `com.sun.java-class` | `ClassFilePreviewer` | icon only |
| `.impex` | `nl.vincentbruijn.impex` | `ImpexPreviewer` | nothing |
| `.log` | `com.apple.log` | `LogPreviewer` | plain built-in preview |

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
nothing else should treat it as one document. The reverse does happen: log
buffers and exports are often JSONL behind a `.json` name, so `JSONPreviewer`
retries as JSONL when the whole-document parse fails and every line parses on
its own.

`.jsonc`, `.json5`, `.sqlite`, `app.Dockerfile` and a list of developer extensions
(`.go`, `.conf`, `.tf`, …) are undeclared too, so the host app declares them.
Undeclared, they resolve to `dyn.*` types that no previewer can reach.

Dotfiles cannot be declared at all. `.zshrc`, `.gitconfig` and a bare
`Dockerfile` have no extension, and a type can only be matched on extension or
MIME type, never on a filename. They resolve to `public.data`. So
`DotfilePreviewer` claims `public.data` and checks the content: text if the
first 8 KB has no NUL byte and decodes as UTF-8. The filename then picks the
renderer. It also checks for SQLite's 16-byte magic header, so Chrome's
`History` and other extensionless databases get the SQLite preview. Anything
else is thrown back, and Quick Look shows its usual icon view. A `dyn.*` type is *not* matched by a `public.data` claim, so
`Dockerfile.prod` and other unlisted extensions still get nothing.

## What gets built

No Xcode project. An app extension is an `Info.plist` plus a binary, and
`swiftc` produces both.

```
~/Applications/DevQuickLook.app
  Contents/Info.plist                    UTImportedTypeDeclarations for jsonl,
                                         jsonc, json5, sqlite, dockerfile, config, source,
                                         xml-text, impex, ear
  Contents/MacOS/DevQuickLook            host app, does nothing
  Contents/PlugIns/YAMLPreviewer.appex   claims public.yaml
  Contents/PlugIns/INIPreviewer.appex    claims com.microsoft.ini, public.toml
  Contents/PlugIns/JSONPreviewer.appex   claims public.json, jsonc, json5
  Contents/PlugIns/JSONLPreviewer.appex  claims nl.vincentbruijn.jsonl
  Contents/PlugIns/DockerfilePreviewer.appex
                                         claims nl.vincentbruijn.dockerfile
  Contents/PlugIns/DotfilePreviewer.appex
                                         claims public.data, config, source
  Contents/PlugIns/SQLitePreviewer.appex claims nl.vincentbruijn.sqlite
  Contents/PlugIns/PlistPreviewer.appex  claims com.apple.property-list
  Contents/PlugIns/XMLPreviewer.appex    claims public.xml, xml-text
  Contents/PlugIns/ArchivePreviewer.appex
                                         claims zip, java archives, tar, gzip
  Contents/PlugIns/ClassFilePreviewer.appex
                                         claims com.sun.java-class
  Contents/PlugIns/ImpexPreviewer.appex  claims nl.vincentbruijn.impex
  Contents/PlugIns/LogPreviewer.appex    claims com.apple.log
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
| `XMLHighlighter.swift` | XML tokenizer shared by the plist and XML previewers |
| `ByteReader.swift` | bounds-checked binary reads, and the report header |
| `*Renderer.swift` | one per format: file bytes to attributed string |
| `DotfileRenderer.swift` | text sniffing, and filename → renderer |
| `*PreviewViewController.swift` | four-line subclass naming its renderer |
| `install-dev-utis.sh` | superseded, see below |

Adding a format takes a renderer, a controller subclass and one line in the
`EXTENSIONS` array. For an Xcode project instead, make one Quick Look Preview
Extension target per format and copy the plist bodies out of that script.

## The renderers

All share the palette in `PreviewStyle.swift` and read a bounded prefix —
`quicklookd` kills slow previews — noting in the header when output was cut.
Caps are the `render` defaults. Each renderer comments the cases that look like
markup but are not.

**JSON and JSONL** share a hand-written parser. `JSONSerialization` returns an
unordered dictionary and pushes numbers through `NSNumber`, turning `1.0` into
`1`. `JSONValue.swift` keeps both order and source text, and one `sortKeys`
flag decides the rest: JSONL sorts so records diff by eye; `.json` keeps its
author's order. Malformed documents report line and column, and still show it.
JSONC, like `tsconfig.json`, is shown as written, comments kept.

**YAML** and **INI/TOML** highlight rather than parse, so half-written files
degrade one line at a time and keep their layout. INI and TOML share a lexer
but split on inline comments — in INI, `path = C:\tmp ; note` is all value — so
the dialect comes from the extension.

**Dockerfile** is highlighted the same way. It follows backslash continuations,
BuildKit heredocs (`RUN <<EOF`), whose bodies are literal, and the
`# escape=` directive.

**Dotfiles** reuse these by name — `.gitconfig` is INI — or get comments and
strings highlighted.

**Property lists** are XML, so they are highlighted like markup, with the text
inside `<key>`, `<string>`, `<integer>`, `<real>` and `<date>` coloured by
element. Binary (`bplist00`, which is how most of `~/Library/Preferences` is
stored) and OpenStep plists have no readable source; they are decoded with
`PropertyListSerialization` and shown as XML, which sorts the keys. The header
says when that happened.

**XML** uses the same tokenizer as plists, with attribute names coloured instead
of element text. UTF-16 is read by its byte order mark, and a document that is
not UTF-8 is read as Latin-1 rather than shown with replacement marks. A
minified document, with a line over 5,000 characters, gets line breaks between
adjacent tags, indented by depth, before the 5,000-line cap applies; the header
says so. SVG, XHTML and other types conform to `public.xml`, but claiming it
does not take them over: SVG still gets Apple's own preview.

**Archives** are listed, never unpacked. A zip keeps its table of contents at
the end of the file, so a 3.7 GB zip64 archive lists as fast as a small one.
An archive with more than 40 entries also gets a size summary per top-level
folder, and the entry list shows the first 1,500 by path; the totals count all. A jar, war or ear also shows its manifest and the Java
version of up to five sampled classes. A tar has no index, so each header is
read and the member data is skipped: a seek for `.tar`, decompress-and-discard
for `.tar.gz`. Like the SQLite counts, that runs under a 2-second budget, and a
listing cut short says how far it got. A plain `.gz` shows the original name,
its size and, if it is text, its first 200 lines. A damaged or truncated
archive shows what was read and what went wrong. A file that is not an archive
at all is thrown back for the icon view.

**Class files** are shown as the declaration they compile from: modifiers,
supertypes, fields, and method signatures with `throws`, plus the Java version
(major 61 is Java 17). Only the constant pool and member tables are read.
Generics are shown erased, as in plain `javap`, and synthetic members are
counted but not listed. A universal Mach-O binary shares the `0xCAFEBABE` magic
and is told apart by its next field.

**ImpEx** colours header lines (`INSERT_UPDATE Product;code[unique=true]`),
their modifiers, `$macro` definitions and references, `#%` code execution, and
quoted values, including ones that span lines. A header and its rows line up in
columns when the block has at most 1,000 rows and every cell is at most 48
characters. Wider blocks, like translation exports, are left as written. The
preview scrolls sideways instead of wrapping.

**Logs** are read from the end, the last 1 MB and at most 5,000 lines, since
that is where the recent lines are. The first level word on a line (`ERROR`,
`WARN`, `SEVERE`, …) is coloured and counted in the header, and timestamps,
exception names and stack frames are picked out. The Java Service Wrapper
prefix that Hybris console logs carry (`INFO | jvm 1 | main | … |`) is dimmed,
and the level after it is used. A `.log` that is binary shows metadata only.

**SQLite** shows the header metadata, then every table with its row count, and
columns, indexes and 10 rows for the first 20. The database is opened
read-only with `immutable=1`, so WAL writes not yet checkpointed are not shown.
Counts use `count(1)`, which a deadline can interrupt, unlike `count(*)`.

## install-dev-utis.sh

The original approach, kept for reference. It writes a stub
`~/Applications/DevUTIs.app` carrying `UTImportedTypeDeclarations` for YAML and
JSONL and nothing else, which needs no Xcode at all.

It is superseded. Its YAML half never worked, for the reason above, and the host
app now declares the JSONL type itself. If you have it installed, remove it:

```sh
./install-dev-utis.sh --uninstall
```

To preview another undeclared extension, add it to `CONFIG_EXTS` or
`SOURCE_EXTS` in `build-quicklooks.sh` and, for highlighting, to
`DotfileRenderer.swift`.

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
