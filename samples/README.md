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
