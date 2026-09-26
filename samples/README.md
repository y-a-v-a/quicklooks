# Samples

Deliberately awkward files, one per previewer. Each contains the cases that
make a naive highlighter get it wrong — colons that are not key separators,
`#` inside quoted strings, block scalars holding text that looks like markup.
Space-bar them after installing to check nothing regressed. `lines.json` is
JSONL behind a `.json` extension and should come out as three records.
`Dockerfile` has a heredoc body full of instruction keywords that must stay
literal, and a comment inside a `RUN` continuation.
`tsconfig.json` is JSONC behind a `.json` name and should keep its comments;
`sample.json5` is highlighted unvalidated. The dotfiles check routing by name:
`.gitconfig` renders as INI, `.prettierrc` as JSONC, `.zshrc` and `.vimrc` with
their own comment styles. `.binaryrc` is binary and should get the icon view.
`sample.sqlite` is built from `sample.sql` (`sqlite3 sample.sqlite < sample.sql`)
and holds a quoted table name, a `WITHOUT ROWID` table, an FTS5 table whose
storage tables should fold away, generated and foreign-key columns, blobs,
multi-line and wide Unicode text, a view and a trigger.
`sample.plist` has a comment and a CDATA section holding `<key>` markup that
must not be coloured as structure, entities, a key spanning two lines and
every value type. `sample-binary.plist` is the same file converted with
`plutil -convert binary1`, and `sample-openstep.plist` is the pre-XML format;
both should show as XML with a note in the header.
`sample.xml` has comments and CDATA full of markup, entities (one of them
unknown) and an attribute value spanning lines. `minified.xml` is a single line
and should come out broken up and indented. `sample.impex` has an aligned block,
one too wide to align, a quoted value spanning lines, a `\` continuation and
`#%` code execution. `sample.log` mixes log formats, a stack trace, a line that
mentions `ERRORS` after `INFO` (it counts as info), and a service-wrapper line.
`Sample.class` and `sample.jar` are built from a Java 17 class with varargs,
`throws` and `transient volatile`. `sample.zip`, `sample.tar`, `sample.tgz` and
`sample.log.gz` are small archives of the other samples. `sample.vm`,
`sample.jsp`, `sample.http`, `sample.drl` and `sample.snap` check that `//` in a
URL is not a comment, and that each language's own comment syntax is.
