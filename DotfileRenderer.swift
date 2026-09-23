import AppKit

/// Files with no type of their own: `.zshrc`, `.gitconfig`, `Brewfile`, a bare
/// `Dockerfile`, and the extensions macOS has never heard of, like `main.go`
/// and `nginx.conf`, which the host app declares for us.
///
/// A type can only be matched on extension, never on filename or content, so
/// no declaration can reach a dotfile. It resolves to `public.data`, and
/// claiming that brings every other extensionless file with it, binaries
/// included. So the bytes decide
/// first whether this is text at all — or a SQLite database, which has a
/// magic header of its own, and the name then picks the renderer.
/// Anything that is not text is thrown back, and Quick Look shows its usual
/// icon view.
enum DotfileRenderer {

    struct NotText: Error {}

    private enum Kind {
        case dockerfile, ini, toml, jsonOrYAML
        case text(PlainTextRenderer.Syntax)
    }

    static func render(url: URL) throws -> NSAttributedString {
        if SQLiteRenderer.isSQLite(url) { return try SQLiteRenderer.render(url: url) }
        guard try looksLikeText(url) else { throw NotText() }

        switch kind(of: url) {
        case .dockerfile:  return try DockerfileRenderer.render(url: url)
        case .ini:         return try INIRenderer.render(url: url, dialect: .ini)
        case .toml:        return try INIRenderer.render(url: url, dialect: .toml)
        case .jsonOrYAML:  return try firstByteIsBracket(url)
                               ? JSONRenderer.render(url: url) : YAMLRenderer.render(url: url)
        case .text(let syntax): return try PlainTextRenderer.render(url: url, syntax: syntax)
        }
    }

    // MARK: - is it text

    /// No NUL in the first 8 KB, and those bytes are UTF-8 apart from a
    /// character cut in half at the end. That rejects nearly every binary
    /// format on its first block and accepts ASCII, which is what config
    /// files are. Latin-1 text is refused, which beats rendering mojibake.
    private static func looksLikeText(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8192) ?? Data()

        if head.contains(0) { return false }
        for cut in 0...min(3, head.count) where String(data: head.dropLast(cut), encoding: .utf8) != nil {
            return true
        }
        return false
    }

    private static func firstByteIsBracket(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4096) ?? Data()
        let first = head.first { !" \t\r\n".utf8.contains($0) }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    // MARK: - which renderer

    private static func kind(of url: URL) -> Kind {
        if DockerfileRenderer.handles(url) { return .dockerfile }

        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent

        if name == "config", parent == ".git" { return .ini }
        if name == "config", parent == ".ssh" { return .text(.hash) }
        if let kind = byName[name] { return kind }
        if name.hasPrefix(".env.") { return .text(.shell) }            // .env.local, .env.production
        if let kind = byExtension[ext] { return kind }
        // An unknown dotfile is far more often `#`-commented than not.
        return name.hasPrefix(".") ? .text(.hash) : .text(.plain)
    }

    private static let byName: [String: Kind] = {
        var map: [String: Kind] = [:]
        for n in [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
                  ".bash_login", ".bash_logout", ".bash_aliases", ".profile", ".kshrc", ".mkshrc",
                  ".aliases", ".exports", ".functions", ".envrc", ".env", ".xinitrc", ".xprofile",
                  ".xsession", "pkgbuild", "apkbuild"] {
            map[n] = .text(.shell)
        }
        for n in [".gitconfig", ".gitmodules", ".editorconfig", ".npmrc", ".pypirc", ".flake8",
                  ".pylintrc", ".coveragerc", ".hgrc", ".wgetrc", ".mrconfig", ".gitconfig.local"] {
            map[n] = .ini
        }
        for n in ["pipfile", "cargo.lock", "poetry.lock", "uv.lock", "pdm.lock", "gopkg.lock"] {
            map[n] = .toml
        }
        // Ruby DSLs and friends: `#` comments, no extension.
        for n in ["brewfile", "gemfile", "podfile", "rakefile", "vagrantfile", "fastfile", "appfile",
                  "dangerfile", "guardfile", "capfile", "berksfile", "procfile", "codeowners",
                  "build", "workspace", "justfile", "gnumakefile"] {
            map[n] = .text(.hash)
        }
        // The rc files of JavaScript tooling take JSON or YAML under one name.
        for n in [".prettierrc", ".babelrc", ".eslintrc", ".jshintrc", ".jscsrc", ".stylelintrc",
                  ".swcrc", ".lintstagedrc", ".markdownlintrc", ".htmlhintrc", ".releaserc",
                  ".nycrc", ".c8rc", ".bowerrc", ".watchmanconfig", ".mocharc", ".remarkrc",
                  ".clang-format", ".clang-tidy", ".yamllint", ".gemrc", ".condarc",
                  "flake.lock", "composer.lock"] {
            map[n] = .jsonOrYAML
        }
        for n in [".vimrc", ".gvimrc", ".exrc", ".ideavimrc", "_vimrc", "_gvimrc"] {
            map[n] = .text(.vim)
        }
        map["jenkinsfile"] = .text(.cLike)
        return map
    }()

    /// Unknown extensions resolve to `dyn.*`, which a `public.data` claim does
    /// not reach, so each of these also needs a declaration in the host app.
    /// Keep in sync with CONFIG_EXTS and SOURCE_EXTS in build-quicklooks.sh.
    private static let byExtension: [String: Kind] = {
        var map: [String: Kind] = [:]
        for e in ["env", "envrc", "fish", "zsh-theme"] { map[e] = .text(.shell) }
        for e in ["service", "socket", "timer", "mount", "target", "desktop", "gitconfig",
                  "editorconfig", "npmrc"] {
            map[e] = .ini
        }
        for e in ["conf", "properties", "lock", "cmake", "bzl", "bazel", "star", "rake", "gemspec",
                  "podspec", "awk", "sed", "ps1", "psm1", "jl", "ex", "exs", "rego", "just",
                  "gql", "graphql", "dockerignore", "gitignore", "gitattributes"] {
            map[e] = .text(.hash)
        }
        for e in ["go", "rs", "kt", "kts", "dart", "zig", "gradle", "groovy", "scala", "sc", "cs",
                  "fsx", "jsx", "cjs", "v", "sv", "svh", "sol", "prisma", "cue", "scss", "less",
                  "styl", "hx", "vala", "wgsl", "cu", "ino", "jsonnet", "libsonnet"] {
            map[e] = .text(.cLike)
        }
        for e in ["tf", "tfvars", "hcl", "nomad", "nix"] { map[e] = .text(.hcl) }
        for e in ["lua", "hs", "elm", "purs"] { map[e] = .text(.dashes) }
        for e in ["clj", "cljs", "cljc", "el", "lisp", "scm", "rkt", "asm"] {
            map[e] = .text(.semicolon)
        }
        map["vim"] = .text(.vim)
        return map
    }()
}
