import OpenTUICore
import Testing

// MARK: - UTF-16 & Scope Assertion Helpers

private func utf16Slice(_ content: String, _ h: SimpleHighlight) -> String {
    let units = Array(content.utf16)
    return String(decoding: units[h.start..<h.end], as: UTF16.self)
}

private func assertValidMonotonicUTF16(_ content: String, _ highlights: [SimpleHighlight], label: String) {
    let units = Array(content.utf16)
    var prevEnd = 0
    for h in highlights {
        #expect(h.start >= 0, "[\(label)] negative start \(h.start)")
        #expect(h.start < h.end, "[\(label)] empty/inverted range \(h.start)..<\(h.end)")
        #expect(h.end <= units.count, "[\(label)] end \(h.end) exceeds UTF-16 count \(units.count)")
        #expect(h.start >= prevEnd, "[\(label)] overlapping or unsorted range \(h.start) < \(prevEnd)")
        if h.start < units.count {
            let u = units[h.start]
            #expect(!(u >= 0xDC00 && u <= 0xDFFF), "[\(label)] start split surrogate pair at \(h.start)")
        }
        if h.end < units.count {
            let u = units[h.end]
            #expect(!(u >= 0xDC00 && u <= 0xDFFF), "[\(label)] end split surrogate pair at \(h.end)")
        }
        prevEnd = h.end
    }
}

private func hasToken(_ content: String, _ highlights: [SimpleHighlight], text: String, group: String) -> Bool {
    highlights.contains { utf16Slice(content, $0) == text && $0.group == group }
}

private func makeFullTreeSitterStyle() -> SyntaxStyle {
    SyntaxStyle.fromStyles([
        "default": StyleDefinition(fg: RGBA.fromInts(220, 220, 220, 255)),
        "keyword": StyleDefinition(fg: RGBA.fromInts(198, 120, 221, 255), bold: true),
        "keyword.function": StyleDefinition(fg: RGBA.fromInts(198, 120, 221, 255)),
        "keyword.return": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255), italic: true),
        "keyword.operator": StyleDefinition(fg: RGBA.fromInts(86, 182, 194, 255)),
        "type": StyleDefinition(fg: RGBA.fromInts(229, 192, 123, 255)),
        "type.builtin": StyleDefinition(fg: RGBA.fromInts(229, 192, 123, 255), italic: true),
        "function": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255)),
        "function.method": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255)),
        "function.macro": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255), bold: true),
        "string": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "string.escape": StyleDefinition(fg: RGBA.fromInts(86, 182, 194, 255)),
        "string.special.url": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255), underline: true),
        "comment": StyleDefinition(fg: RGBA.fromInts(92, 99, 112, 255), italic: true),
        "number": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255)),
        "boolean": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255), bold: true),
        "constant": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255)),
        "constant.builtin": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
        "operator": StyleDefinition(fg: RGBA.fromInts(86, 182, 194, 255)),
        "punctuation.bracket": StyleDefinition(fg: RGBA.fromInts(171, 178, 191, 255)),
        "punctuation.delimiter": StyleDefinition(fg: RGBA.fromInts(171, 178, 191, 255)),
        "tag": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
        "attribute": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255)),
        "property": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
        "variable.parameter": StyleDefinition(fg: RGBA.fromInts(229, 192, 123, 255), italic: true),
        "markup.heading": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255), bold: true),
        "markup.raw": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "markup.link.label": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255), underline: true),
        "markup.link.url": StyleDefinition(fg: RGBA.fromInts(86, 182, 194, 255), underline: true),
        "markup.strong": StyleDefinition(fg: RGBA.fromInts(255, 255, 255, 255), bold: true),
        "markup.italic": StyleDefinition(fg: RGBA.fromInts(198, 120, 221, 255), italic: true),
        "diff.plus": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "diff.minus": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
        "diff.delta": StyleDefinition(fg: RGBA.fromInts(229, 192, 123, 255)),
    ])
}

// MARK: - Complete 34 Upstream Languages + Aliases Coverage Suite

@Suite("TreeSitter34Languages")
struct TreeSitter34LanguagesTests {
    /// Exact 34 filetypes enumerated in `upstream/opencode/packages/tui/src/parsers-config.ts`.
    private static let all34UpstreamLanguages: [String] = [
        "python", "rust", "go", "cpp", "csharp", "bash", "c", "java",
        "kotlin", "ruby", "php", "scala", "html", "vue", "hcl", "json",
        "yaml", "haskell", "css", "julia", "lua", "ocaml", "clojure", "swift",
        "toml", "nix", "diff", "elixir", "fsharp", "r", "make", "vim",
        "xml", "agda",
    ]

    @Test("BuiltInSyntaxHighlighter and TreeSitterGrammars support all 34 upstream languages, OpenTUI built-ins, and resolve-ft aliases")
    func supportsAll34UpstreamLanguagesAndAliases() {
        #expect(TreeSitterGrammars.upstreamParserFiletypes.count == 34)
        #expect(TreeSitterGrammars.upstreamParserFiletypes == Self.all34UpstreamLanguages)

        let highlighter = BuiltInSyntaxHighlighter.shared
        for lang in Self.all34UpstreamLanguages {
            #expect(BuiltInSyntaxHighlighter.supportedFiletypes.contains(lang), "Missing canonical filetype \(lang)")
            #expect(BuiltInSyntaxHighlighter.supports(filetype: lang), "Static supports(filetype:) false for \(lang)")
            #expect(highlighter.supports(filetype: lang), "Instance supports(filetype:) false for \(lang)")
        }

        // OpenTUI built-in parsers
        for builtIn in ["javascript", "javascriptreact", "typescript", "typescriptreact", "markdown", "markdown_inline", "zig"] {
            #expect(BuiltInSyntaxHighlighter.supports(filetype: builtIn))
        }

        // Comprehensive aliases, extensions, basenames, paths, and fence info strings from parsers-config.ts & resolve-ft.ts
        let aliasExpectations: [(input: String, expectedCanonical: String)] = [
            ("py", "python"), ("pyi", "python"), ("src/main.py", "python"),
            ("rs", "rust"), ("Cargo/src/lib.rs", "rust"),
            ("golang", "go"), ("cmd/main.go", "go"),
            ("cc", "cpp"), ("cxx", "cpp"), ("hpp", "cpp"), ("hxx", "cpp"), ("h++", "cpp"), ("hh", "cpp"), ("c++", "cpp"),
            ("cs", "csharp"), ("c#", "csharp"), ("Program.cs", "csharp"),
            ("sh", "bash"), ("zsh", "bash"), ("ksh", "bash"), ("shell", "bash"), (".bashrc", "bash"), (".zshrc", "bash"),
            ("h", "c"), ("include/header.h", "c"),
            ("App.java", "java"),
            ("kt", "kotlin"), ("kts", "kotlin"),
            ("rb", "ruby"), ("rake", "ruby"), ("ru", "ruby"), ("gemspec", "ruby"), ("Gemfile", "ruby"), ("Rakefile", "ruby"),
            ("phtml", "php"), ("index.php", "php"),
            ("sc", "scala"), ("sbt", "scala"),
            ("htm", "html"), ("index.html", "html"),
            ("App.vue", "vue"),
            ("tf", "hcl"), ("tfvars", "hcl"), ("terraform", "hcl"),
            ("jsonc", "json"), ("config.json", "json"),
            ("yml", "yaml"), ("deploy.yml", "yaml"),
            ("hs", "haskell"), ("lhs", "haskell"),
            ("scss", "css"), ("sass", "css"), ("less", "css"),
            ("jl", "julia"),
            ("init.lua", "lua"),
            ("ml", "ocaml"), ("mli", "ocaml"),
            ("clj", "clojure"), ("cljs", "clojure"), ("cljc", "clojure"), ("edn", "clojure"),
            ("Package.swift", "swift"),
            ("Cargo.toml", "toml"),
            ("flake.nix", "nix"),
            ("patch", "diff"), ("udiff", "diff"), ("fix.patch", "diff"),
            ("ex", "elixir"), ("exs", "elixir"),
            ("fs", "fsharp"), ("fsx", "fsharp"), ("fsscript", "fsharp"), ("fsi", "fsharp"),
            ("analysis.R", "r"),
            ("makefile", "make"), ("Makefile", "make"), ("GNUmakefile", "make"), ("mk", "make"),
            (".vimrc", "vim"), ("gvimrc", "vim"), ("viml", "vim"), ("vimscript", "vim"),
            ("xsl", "xml"), ("xslt", "xml"), ("svg", "xml"), ("Info.plist", "xml"),
            ("lagda", "agda"),
            ("js", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"),
            ("jsx", "javascriptreact"), ("ts", "typescript"), ("mts", "typescript"), ("cts", "typescript"),
            ("tsx", "typescriptreact"), ("TSX title=App.tsx", "typescriptreact"),
            ("md", "markdown"), ("mdown", "markdown"), ("mkd", "markdown"),
            ("zon", "zig"),
        ]

        for (input, expected) in aliasExpectations {
            #expect(TreeSitterGrammars.canonicalFiletype(for: input) == expected, "Alias \(input) expected \(expected)")
            #expect(BuiltInSyntaxHighlighter.supports(filetype: input), "Alias \(input) should be supported")
        }

        // Unsupported language returns false & warning
        #expect(!BuiltInSyntaxHighlighter.supports(filetype: "brainfuck"))
        let unsupported = highlighter.highlight(content: "++++", filetype: "brainfuck")
        #expect(unsupported.highlights.isEmpty)
        #expect(unsupported.warning != nil)
    }

    @Test("Systems & JVM languages (python, rust, go, c, cpp, csharp, java, kotlin, scala, swift, zig) emit rich scopes & multi-line constructs")
    func systemsAndJVMLanguages() {
        let hl = BuiltInSyntaxHighlighter.shared

        // 1. Python — triple-quoted multiline string, escape, URL, decorator, keyword.return, keyword.operator, parameter, method
        let py = """
        # 日本語 🚀
        @dataclass
        def greet(user: str) -> bool:
            doc = \"\"\"line 1 🚀
            line 2 日本語\"\"\"
            msg = "hi\\n"
            url = "https://python.org/docs"
            return user.strip() is not None
        """
        let pyRes = hl.highlight(content: py, filetype: "python")
        #expect(pyRes.warning == nil)
        assertValidMonotonicUTF16(py, pyRes.highlights, label: "python")
        #expect(hasToken(py, pyRes.highlights, text: "@dataclass", group: "attribute"))
        #expect(hasToken(py, pyRes.highlights, text: "user", group: "variable.parameter"))
        #expect(hasToken(py, pyRes.highlights, text: "str", group: "type.builtin"))
        #expect(hasToken(py, pyRes.highlights, text: "\\n", group: "string.escape"))
        #expect(hasToken(py, pyRes.highlights, text: "https://python.org/docs", group: "string.special.url"))
        #expect(hasToken(py, pyRes.highlights, text: "return", group: "keyword.return"))
        #expect(hasToken(py, pyRes.highlights, text: "strip", group: "function.method"))
        #expect(hasToken(py, pyRes.highlights, text: "is", group: "keyword.operator"))
        #expect(hasToken(py, pyRes.highlights, text: "not", group: "keyword.operator"))

        // 2. Rust — nested block comment, attribute, raw multiline string, macro, lifetime, type.builtin, method, parameter
        let rs = """
        /* outer /* inner 🚀 */ end */
        #[derive(Debug)]
        pub fn run<'a>(buf: &'a str) -> usize {
            let s = r#"multi
        日本語"#;
            println!("hi\\t{}", s);
            return buf.len();
        }
        """
        let rsRes = hl.highlight(content: rs, filetype: "rust")
        assertValidMonotonicUTF16(rs, rsRes.highlights, label: "rust")
        #expect(hasToken(rs, rsRes.highlights, text: "/* outer /* inner 🚀 */ end */", group: "comment"))
        #expect(hasToken(rs, rsRes.highlights, text: "derive", group: "attribute"))
        #expect(hasToken(rs, rsRes.highlights, text: "fn", group: "keyword.function"))
        #expect(hasToken(rs, rsRes.highlights, text: "buf", group: "variable.parameter"))
        #expect(hasToken(rs, rsRes.highlights, text: "usize", group: "type.builtin"))
        #expect(hasToken(rs, rsRes.highlights, text: "println!", group: "function.macro"))
        #expect(hasToken(rs, rsRes.highlights, text: "\\t", group: "string.escape"))
        #expect(hasToken(rs, rsRes.highlights, text: "return", group: "keyword.return"))
        #expect(hasToken(rs, rsRes.highlights, text: "len", group: "function.method"))

        // 3. Go — multiline raw backtick string, block comment, keyword.function, type.builtin, constant.builtin (nil), parameter
        let go = """
        /* Go 🚀
           multiline */
        package main
        func fetch(url string) error {
            body := `line1
        日本語`
            _ = body
            return nil
        }
        """
        let goRes = hl.highlight(content: go, filetype: "go")
        assertValidMonotonicUTF16(go, goRes.highlights, label: "go")
        #expect(hasToken(go, goRes.highlights, text: "func", group: "keyword.function"))
        #expect(hasToken(go, goRes.highlights, text: "url", group: "variable.parameter"))
        #expect(hasToken(go, goRes.highlights, text: "string", group: "type.builtin"))
        #expect(hasToken(go, goRes.highlights, text: "error", group: "type.builtin"))
        #expect(hasToken(go, goRes.highlights, text: "return", group: "keyword.return"))
        #expect(hasToken(go, goRes.highlights, text: "nil", group: "constant.builtin"))

        // 4. C — preprocessor #include <stdio.h>, #define macro, pointer -> method/property, sizeof, NULL, parameters
        let c = """
        #include <stdio.h>
        #define MAX_BUF 256
        /* multi
           🚀 comment */
        size_t measure(const char *msg, int count) {
            if (msg == NULL) return sizeof(int);
            return count;
        }
        """
        let cRes = hl.highlight(content: c, filetype: "c")
        assertValidMonotonicUTF16(c, cRes.highlights, label: "c")
        #expect(hasToken(c, cRes.highlights, text: "#include", group: "keyword"))
        #expect(hasToken(c, cRes.highlights, text: "<stdio.h>", group: "string"))
        #expect(hasToken(c, cRes.highlights, text: "MAX_BUF", group: "function.macro"))
        #expect(hasToken(c, cRes.highlights, text: "size_t", group: "type.builtin"))
        #expect(hasToken(c, cRes.highlights, text: "msg", group: "variable.parameter"))
        #expect(hasToken(c, cRes.highlights, text: "count", group: "variable.parameter"))
        #expect(hasToken(c, cRes.highlights, text: "NULL", group: "constant.builtin"))
        #expect(hasToken(c, cRes.highlights, text: "sizeof", group: "keyword.operator"))
        #expect(hasToken(c, cRes.highlights, text: "return", group: "keyword.return"))

        // 5. C++ — [[nodiscard]], R"raw(...)raw" multiline raw string, arrow method call, co_return
        let cpp = """
        [[nodiscard]] int compute(int value) {
            auto text = R"raw(hello 🚀
        日本語)raw";
            return ptr->calc(value);
        }
        """
        let cppRes = hl.highlight(content: cpp, filetype: "cpp")
        assertValidMonotonicUTF16(cpp, cppRes.highlights, label: "cpp")
        #expect(hasToken(cpp, cppRes.highlights, text: "nodiscard", group: "attribute"))
        #expect(hasToken(cpp, cppRes.highlights, text: "value", group: "variable.parameter"))
        #expect(hasToken(cpp, cppRes.highlights, text: "R\"raw(hello 🚀\n日本語)raw\"", group: "string"))
        #expect(hasToken(cpp, cppRes.highlights, text: "calc", group: "function.method"))
        #expect(hasToken(cpp, cppRes.highlights, text: "return", group: "keyword.return"))

        // 6. C# — [Serializable] attribute, verbatim multiline @"...", typeof, null, parameter
        let cs = #"""
        #region Demo
        [Serializable]
        public class Greeter {
            public string Format(int count) {
                var raw = @"line 1 🚀
        line 2 ""quoted""";
                if (raw is null) return nameof(Greeter);
                return raw.Trim();
            }
        }
        #endregion
        """#
        let csRes = hl.highlight(content: cs, filetype: "csharp")
        assertValidMonotonicUTF16(cs, csRes.highlights, label: "csharp")
        #expect(hasToken(cs, csRes.highlights, text: "#region", group: "keyword"))
        #expect(hasToken(cs, csRes.highlights, text: "Serializable", group: "attribute"))
        #expect(hasToken(cs, csRes.highlights, text: "string", group: "type.builtin"))
        #expect(hasToken(cs, csRes.highlights, text: "count", group: "variable.parameter"))
        #expect(hasToken(cs, csRes.highlights, text: "is", group: "keyword.operator"))
        #expect(hasToken(cs, csRes.highlights, text: "null", group: "constant.builtin"))
        #expect(hasToken(cs, csRes.highlights, text: "nameof", group: "keyword.operator"))
        #expect(hasToken(cs, csRes.highlights, text: "Trim", group: "function.method"))

        // 7. Java — @Override annotation, text block """...""", instanceof, null, parameter
        let java = """
        /* JavaDoc 🚀 */
        @Override
        public String describe(int level) {
            String block = \"\"\"
                hello 日本語
                \"\"\";
            if (block instanceof String) return block.trim();
            return null;
        }
        """
        let javaRes = hl.highlight(content: java, filetype: "java")
        assertValidMonotonicUTF16(java, javaRes.highlights, label: "java")
        #expect(hasToken(java, javaRes.highlights, text: "@Override", group: "attribute"))
        #expect(hasToken(java, javaRes.highlights, text: "int", group: "type.builtin"))
        #expect(hasToken(java, javaRes.highlights, text: "level", group: "variable.parameter"))
        #expect(hasToken(java, javaRes.highlights, text: "instanceof", group: "keyword.operator"))
        #expect(hasToken(java, javaRes.highlights, text: "trim", group: "function.method"))
        #expect(hasToken(java, javaRes.highlights, text: "null", group: "constant.builtin"))

        // 8. Kotlin — nested block comments, @Composable, fun, triple-quoted multiline, null, parameter
        let kt = """
        /* outer /* inner 🚀 */ */
        @Composable
        fun render(title: String): Unit {
            val tpl = \"\"\"hello
        日本語\"\"\"
            if (title is String) return Unit
            val empty: String? = null
        }
        """
        let ktRes = hl.highlight(content: kt, filetype: "kotlin")
        assertValidMonotonicUTF16(kt, ktRes.highlights, label: "kotlin")
        #expect(hasToken(kt, ktRes.highlights, text: "/* outer /* inner 🚀 */ */", group: "comment"))
        #expect(hasToken(kt, ktRes.highlights, text: "@Composable", group: "attribute"))
        #expect(hasToken(kt, ktRes.highlights, text: "fun", group: "keyword.function"))
        #expect(hasToken(kt, ktRes.highlights, text: "title", group: "variable.parameter"))
        #expect(hasToken(kt, ktRes.highlights, text: "Unit", group: "type.builtin"))
        #expect(hasToken(kt, ktRes.highlights, text: "is", group: "keyword.operator"))
        #expect(hasToken(kt, ktRes.highlights, text: "null", group: "constant.builtin"))

        // 9. Scala — @tailrec, def, interpolated string, nested comments, Option/None
        let sc = """
        /* outer /* 🚀 */ */
        @tailrec
        def loop(acc: Int): Option[String] = {
            val s = s"val=\\n$acc"
            if (acc == 0) return None
            Some(s.trim())
        }
        """
        let scRes = hl.highlight(content: sc, filetype: "scala")
        assertValidMonotonicUTF16(sc, scRes.highlights, label: "scala")
        #expect(hasToken(sc, scRes.highlights, text: "@tailrec", group: "attribute"))
        #expect(hasToken(sc, scRes.highlights, text: "def", group: "keyword.function"))
        #expect(hasToken(sc, scRes.highlights, text: "acc", group: "variable.parameter"))
        #expect(hasToken(sc, scRes.highlights, text: "Int", group: "type.builtin"))
        #expect(hasToken(sc, scRes.highlights, text: "None", group: "constant.builtin"))
        #expect(hasToken(sc, scRes.highlights, text: "\\n", group: "string.escape"))

        // 10. Swift — @MainActor, #expect macro, multiline raw string, func, return, nil, parameter
        let sw = """
        @MainActor
        func verify(label: String) -> Bool {
            let raw = #\"\"\"🚀
        日本語\"\"\"#
            #expect(label.isEmpty == false)
            let nothing: Int? = nil
            return nothing == nil
        }
        """
        let swRes = hl.highlight(content: sw, filetype: "swift")
        assertValidMonotonicUTF16(sw, swRes.highlights, label: "swift")
        #expect(hasToken(sw, swRes.highlights, text: "@MainActor", group: "attribute"))
        #expect(hasToken(sw, swRes.highlights, text: "func", group: "keyword.function"))
        #expect(hasToken(sw, swRes.highlights, text: "label", group: "variable.parameter"))
        #expect(hasToken(sw, swRes.highlights, text: "#expect", group: "function.macro"))
        #expect(hasToken(sw, swRes.highlights, text: "nil", group: "constant.builtin"))
        #expect(hasToken(sw, swRes.highlights, text: "return", group: "keyword.return"))

        // 11. Zig (OpenTUI built-in) — @import macro, \\ multiline string, u32/usize builtin types, orelse
        let zig = """
        const std = @import("std");
        pub fn add(lhs: u32, rhs: u32) usize {
            const banner =
                \\\\hello 🚀 日本語
            ;
            return lhs + rhs;
        }
        """
        let zigRes = hl.highlight(content: zig, filetype: "zig")
        assertValidMonotonicUTF16(zig, zigRes.highlights, label: "zig")
        #expect(hasToken(zig, zigRes.highlights, text: "@import", group: "function.macro"))
        #expect(hasToken(zig, zigRes.highlights, text: "fn", group: "keyword.function"))
        #expect(hasToken(zig, zigRes.highlights, text: "lhs", group: "variable.parameter"))
        #expect(hasToken(zig, zigRes.highlights, text: "u32", group: "type.builtin"))
        #expect(hasToken(zig, zigRes.highlights, text: "usize", group: "type.builtin"))
        #expect(hasToken(zig, zigRes.highlights, text: "\\\\hello 🚀 日本語", group: "string"))
    }

    @Test("Scripting & dynamic languages (bash, ruby, php, lua, julia, elixir, r, vim) emit stateful multi-line constructs & scopes")
    func scriptingAndDynamicLanguages() {
        let hl = BuiltInSyntaxHighlighter.shared

        // 12. Bash — heredoc, flags, variables, keywords, command head
        let bash = """
        #!/usr/bin/env bash
        # 日本語 🚀
        function deploy() {
            NAME="hello\\nworld"
            cat <<EOF
        multi-line 🚀 heredoc
        EOF
            echo --verbose $NAME
            return 0
        }
        """
        let bashRes = hl.highlight(content: bash, filetype: "bash")
        assertValidMonotonicUTF16(bash, bashRes.highlights, label: "bash")
        #expect(hasToken(bash, bashRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(bash, bashRes.highlights, text: "NAME", group: "property"))
        #expect(hasToken(bash, bashRes.highlights, text: "\\n", group: "string.escape"))
        #expect(hasToken(bash, bashRes.highlights, text: "multi-line 🚀 heredoc\nEOF", group: "string"))
        #expect(hasToken(bash, bashRes.highlights, text: "--verbose", group: "variable.parameter"))
        #expect(hasToken(bash, bashRes.highlights, text: "$NAME", group: "constant"))
        #expect(hasToken(bash, bashRes.highlights, text: "return", group: "keyword.return"))

        // 13. Ruby — =begin..=end multiline comment, heredoc, symbols, ivars, def, nil, parameter
        let rb = """
        =begin
        Ruby multi-line 🚀 comment
        =end
        class Greeter
          def greet(name)
            @title = <<~TXT
              日本語 text
            TXT
            return nil if name.empty? and true
            puts({ status: :ok })
          end
        end
        """
        let rbRes = hl.highlight(content: rb, filetype: "ruby")
        assertValidMonotonicUTF16(rb, rbRes.highlights, label: "ruby")
        #expect(hasToken(rb, rbRes.highlights, text: "=begin\nRuby multi-line 🚀 comment\n=end", group: "comment"))
        #expect(hasToken(rb, rbRes.highlights, text: "def", group: "keyword.function"))
        #expect(hasToken(rb, rbRes.highlights, text: "name", group: "variable.parameter"))
        #expect(hasToken(rb, rbRes.highlights, text: "@title", group: "property"))
        #expect(hasToken(rb, rbRes.highlights, text: "return", group: "keyword.return"))
        #expect(hasToken(rb, rbRes.highlights, text: "nil", group: "constant.builtin"))
        #expect(hasToken(rb, rbRes.highlights, text: "and", group: "keyword.operator"))
        #expect(hasToken(rb, rbRes.highlights, text: "status", group: "property"))
        #expect(hasToken(rb, rbRes.highlights, text: ":ok", group: "constant.builtin"))

        // 14. PHP — <?php tag, #[Route] attribute, heredoc, $param, ->method(), type.builtin, null
        let php = """
        <?php
        /* PHP 🚀 block */
        #[Route("/api")]
        function handle(string $input): int {
            $doc = <<<EOT
        line 🚀 1
        EOT;
            $len = $obj->measure($input);
            return $len ?? null;
        }
        ?>
        """
        let phpRes = hl.highlight(content: php, filetype: "php")
        assertValidMonotonicUTF16(php, phpRes.highlights, label: "php")
        #expect(hasToken(php, phpRes.highlights, text: "<?php", group: "tag"))
        #expect(hasToken(php, phpRes.highlights, text: "?>", group: "tag"))
        #expect(hasToken(php, phpRes.highlights, text: "Route", group: "attribute"))
        #expect(hasToken(php, phpRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(php, phpRes.highlights, text: "string", group: "type.builtin"))
        #expect(hasToken(php, phpRes.highlights, text: "$input", group: "variable.parameter"))
        #expect(hasToken(php, phpRes.highlights, text: "measure", group: "function.method"))
        #expect(hasToken(php, phpRes.highlights, text: "null", group: "constant.builtin"))

        // 15. Lua — arbitrary-level long-bracket comment & string, ::label::, colon method, nil, parameter
        let lua = """
        --[=[ Lua multi-line 🚀
        comment with ]] inside ]=]
        local function render(ctx, text)
            local raw = [==[hello
        日本語]==]
            ::retry::
            ctx:draw(raw)
            if not text then return nil end
            return ctx.width
        end
        """
        let luaRes = hl.highlight(content: lua, filetype: "lua")
        assertValidMonotonicUTF16(lua, luaRes.highlights, label: "lua")
        #expect(hasToken(lua, luaRes.highlights, text: "--[=[ Lua multi-line 🚀\ncomment with ]] inside ]=]", group: "comment"))
        #expect(hasToken(lua, luaRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(lua, luaRes.highlights, text: "ctx", group: "variable.parameter"))
        #expect(hasToken(lua, luaRes.highlights, text: "text", group: "variable.parameter"))
        #expect(hasToken(lua, luaRes.highlights, text: "[==[hello\n日本語]==]", group: "string"))
        #expect(hasToken(lua, luaRes.highlights, text: "::retry::", group: "attribute"))
        #expect(hasToken(lua, luaRes.highlights, text: "draw", group: "function.method"))
        #expect(hasToken(lua, luaRes.highlights, text: "not", group: "keyword.operator"))
        #expect(hasToken(lua, luaRes.highlights, text: "nil", group: "constant.builtin"))
        #expect(hasToken(lua, luaRes.highlights, text: "width", group: "property"))

        // 16. Julia — nested #= =# comments, @show macro, triple string, type.builtin, nothing, parameter
        let jl = """
        #= outer #= inner 🚀 =# end =#
        function scale(x::Float64, factor::Int64)
            doc = \"\"\"日本語
            line 2\"\"\"
            @show :ok
            if x isa Float64
                return x * factor
            end
            return nothing
        end
        """
        let jlRes = hl.highlight(content: jl, filetype: "julia")
        assertValidMonotonicUTF16(jl, jlRes.highlights, label: "julia")
        #expect(hasToken(jl, jlRes.highlights, text: "#= outer #= inner 🚀 =# end =#", group: "comment"))
        #expect(hasToken(jl, jlRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(jl, jlRes.highlights, text: "x", group: "variable.parameter"))
        #expect(hasToken(jl, jlRes.highlights, text: "Float64", group: "type.builtin"))
        #expect(hasToken(jl, jlRes.highlights, text: "@show", group: "function.macro"))
        #expect(hasToken(jl, jlRes.highlights, text: ":ok", group: "constant.builtin"))
        #expect(hasToken(jl, jlRes.highlights, text: "isa", group: "keyword.operator"))
        #expect(hasToken(jl, jlRes.highlights, text: "nothing", group: "constant.builtin"))

        // 17. Elixir — @moduledoc attribute, heredoc, sigil ~r/.../, defp, :ok atom, keyword key, parameter
        let ex = """
        defmodule Demo do
          @moduledoc \"\"\"
          Elixir 🚀 docs
          \"\"\"
          defp parse(line) when is_binary(line) do
            rx = ~r/日本語+/u
            {:ok, matched: String.trim(line) |> IO.inspect()}
          end
        end
        """
        let exRes = hl.highlight(content: ex, filetype: "elixir")
        assertValidMonotonicUTF16(ex, exRes.highlights, label: "elixir")
        #expect(hasToken(ex, exRes.highlights, text: "defmodule", group: "keyword"))
        #expect(hasToken(ex, exRes.highlights, text: "@moduledoc", group: "attribute"))
        #expect(hasToken(ex, exRes.highlights, text: "defp", group: "keyword.function"))
        #expect(hasToken(ex, exRes.highlights, text: "line", group: "variable.parameter"))
        #expect(hasToken(ex, exRes.highlights, text: "when", group: "keyword.operator"))
        #expect(hasToken(ex, exRes.highlights, text: "~r/日本語+/u", group: "string"))
        #expect(hasToken(ex, exRes.highlights, text: ":ok", group: "constant.builtin"))
        #expect(hasToken(ex, exRes.highlights, text: "matched", group: "property"))
        #expect(hasToken(ex, exRes.highlights, text: "trim", group: "function.method"))

        // 18. R — raw string r"(...)", %in% infix operator, df$col property, NULL/TRUE, function/return, parameter
        let rCode = """
        # R 🚀 script
        summarize <- function(df, limit = 10L) {
          txt <- r"(line 1
        日本語)"
          if (TRUE && limit %in% c(1, 10)) {
            return(df$score)
          }
          NULL
        }
        """
        let rRes = hl.highlight(content: rCode, filetype: "r")
        assertValidMonotonicUTF16(rCode, rRes.highlights, label: "r")
        #expect(hasToken(rCode, rRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(rCode, rRes.highlights, text: "df", group: "variable.parameter"))
        #expect(hasToken(rCode, rRes.highlights, text: "limit", group: "variable.parameter"))
        #expect(hasToken(rCode, rRes.highlights, text: "r\"(line 1\n日本語)\"", group: "string"))
        #expect(hasToken(rCode, rRes.highlights, text: "TRUE", group: "boolean"))
        #expect(hasToken(rCode, rRes.highlights, text: "%in%", group: "operator"))
        #expect(hasToken(rCode, rRes.highlights, text: "return", group: "keyword.return"))
        #expect(hasToken(rCode, rRes.highlights, text: "score", group: "property"))
        #expect(hasToken(rCode, rRes.highlights, text: "NULL", group: "constant.builtin"))

        // 19. Vimscript — `"` line-start comment vs `"..."` string, function!, a:arg, g:var, &opt, v:null
        let vim = """
        " Vim 🚀 config
        let g:title = "日本語\\n"
        set &number
        function! Greet(msg)
          if a:msg == ''
            return v:null
          endif
          return v:true
        endfunction
        """
        let vimRes = hl.highlight(content: vim, filetype: "vim")
        assertValidMonotonicUTF16(vim, vimRes.highlights, label: "vim")
        #expect(hasToken(vim, vimRes.highlights, text: "\" Vim 🚀 config", group: "comment"))
        #expect(hasToken(vim, vimRes.highlights, text: "let", group: "keyword"))
        #expect(hasToken(vim, vimRes.highlights, text: "g:title", group: "property"))
        #expect(hasToken(vim, vimRes.highlights, text: "\\n", group: "string.escape"))
        #expect(hasToken(vim, vimRes.highlights, text: "&number", group: "property"))
        #expect(hasToken(vim, vimRes.highlights, text: "function!", group: "keyword.function"))
        #expect(hasToken(vim, vimRes.highlights, text: "a:msg", group: "variable.parameter"))
        #expect(hasToken(vim, vimRes.highlights, text: "v:null", group: "constant.builtin"))
        #expect(hasToken(vim, vimRes.highlights, text: "v:true", group: "boolean"))
    }

    @Test("Functional & formal languages (haskell, ocaml, fsharp, clojure, nix, agda) emit nested comments, pragmas, & rich scopes")
    func functionalAndFormalLanguages() {
        let hl = BuiltInSyntaxHighlighter.shared

        // 20. Haskell — {-# LANGUAGE #-}, nested {- ... -}, signature, type.builtin, Just/Nothing
        let hs = """
        {-# LANGUAGE OverloadedStrings #-}
        {- outer {- inner 🚀 -} end -}
        module Main where
        greet :: String -> Maybe Int
        greet name = if True then Just 42 else Nothing
        """
        let hsRes = hl.highlight(content: hs, filetype: "haskell")
        assertValidMonotonicUTF16(hs, hsRes.highlights, label: "haskell")
        #expect(hasToken(hs, hsRes.highlights, text: "{-# LANGUAGE OverloadedStrings #-}", group: "attribute"))
        #expect(hasToken(hs, hsRes.highlights, text: "{- outer {- inner 🚀 -} end -}", group: "comment"))
        #expect(hasToken(hs, hsRes.highlights, text: "module", group: "keyword"))
        #expect(hasToken(hs, hsRes.highlights, text: "greet", group: "function"))
        #expect(hasToken(hs, hsRes.highlights, text: "String", group: "type.builtin"))
        #expect(hasToken(hs, hsRes.highlights, text: "Maybe", group: "type.builtin"))
        #expect(hasToken(hs, hsRes.highlights, text: "Just", group: "constant.builtin"))
        #expect(hasToken(hs, hsRes.highlights, text: "Nothing", group: "constant.builtin"))

        // 21. OCaml — nested (* ... *), [@tailcall], {|...|} quoted string, 'a type var, fun, Some/None
        let ml = """
        (* outer (* inner 🚀 *) end *)
        let rec find (x : 'a) : int option =
          let raw = {|hello
        日本語|} in
          let f = fun n -> n mod 2 in
          [@tailcall]
          if true then Some (f 4) else None
        """
        let mlRes = hl.highlight(content: ml, filetype: "ocaml")
        assertValidMonotonicUTF16(ml, mlRes.highlights, label: "ocaml")
        #expect(hasToken(ml, mlRes.highlights, text: "(* outer (* inner 🚀 *) end *)", group: "comment"))
        #expect(hasToken(ml, mlRes.highlights, text: "'a", group: "type"))
        #expect(hasToken(ml, mlRes.highlights, text: "int", group: "type.builtin"))
        #expect(hasToken(ml, mlRes.highlights, text: "{|hello\n日本語|}", group: "string"))
        #expect(hasToken(ml, mlRes.highlights, text: "fun", group: "keyword.function"))
        #expect(hasToken(ml, mlRes.highlights, text: "mod", group: "keyword.operator"))
        #expect(hasToken(ml, mlRes.highlights, text: "@tailcall", group: "attribute"))
        #expect(hasToken(ml, mlRes.highlights, text: "Some", group: "constant.builtin"))
        #expect(hasToken(ml, mlRes.highlights, text: "None", group: "constant.builtin"))

        // 22. F# — nested (* ... *), [<EntryPoint>], verbatim string, return!, option/Some
        let fs = """
        (* outer (* 🚀 *) *)
        [<EntryPoint>]
        let main (argv: string array) =
            let raw = @"multi
        日本語"
            let work = async { return! Async.Sleep 10 }
            Some 0
        """
        let fsRes = hl.highlight(content: fs, filetype: "fsharp")
        assertValidMonotonicUTF16(fs, fsRes.highlights, label: "fsharp")
        #expect(hasToken(fs, fsRes.highlights, text: "(* outer (* 🚀 *) *)", group: "comment"))
        #expect(hasToken(fs, fsRes.highlights, text: "EntryPoint", group: "attribute"))
        #expect(hasToken(fs, fsRes.highlights, text: "string", group: "type.builtin"))
        #expect(hasToken(fs, fsRes.highlights, text: "@\"multi\n日本語\"", group: "string"))
        #expect(hasToken(fs, fsRes.highlights, text: "return!", group: "keyword.return"))
        #expect(hasToken(fs, fsRes.highlights, text: "Some", group: "constant.builtin"))

        // 23. Clojure — ; comment, ^:private meta, defn, param vector, :keyword, -> macro, nil, multi-line string
        let clj = """
        ; Clojure 🚀
        (defn ^:private greet [user title]
          (let [msg "hello
        日本語"]
            (-> {:name user :ok true}
                (or nil))))
        """
        let cljRes = hl.highlight(content: clj, filetype: "clojure")
        assertValidMonotonicUTF16(clj, cljRes.highlights, label: "clojure")
        #expect(hasToken(clj, cljRes.highlights, text: "; Clojure 🚀", group: "comment"))
        #expect(hasToken(clj, cljRes.highlights, text: "defn", group: "keyword.function"))
        #expect(hasToken(clj, cljRes.highlights, text: "^:private", group: "attribute"))
        #expect(hasToken(clj, cljRes.highlights, text: "greet", group: "function"))
        #expect(hasToken(clj, cljRes.highlights, text: "user", group: "variable.parameter"))
        #expect(hasToken(clj, cljRes.highlights, text: "title", group: "variable.parameter"))
        #expect(hasToken(clj, cljRes.highlights, text: "->", group: "function.macro"))
        #expect(hasToken(clj, cljRes.highlights, text: ":name", group: "property"))
        #expect(hasToken(clj, cljRes.highlights, text: "nil", group: "constant.builtin"))

        // 24. Nix — /* ... */, ''...'' indented multiline string, URL, <nixpkgs>, attr =, null
        let nix = """
        /* Nix 🚀 flake */
        { pkgs, lib }:
        let
          homepage = https://nixos.org;
          script = ''
            echo "日本語"
          '';
        in {
          src = <nixpkgs>;
          enabled = true;
          fallback = null;
        }
        """
        let nixRes = hl.highlight(content: nix, filetype: "nix")
        assertValidMonotonicUTF16(nix, nixRes.highlights, label: "nix")
        #expect(hasToken(nix, nixRes.highlights, text: "/* Nix 🚀 flake */", group: "comment"))
        #expect(hasToken(nix, nixRes.highlights, text: "let", group: "keyword"))
        #expect(hasToken(nix, nixRes.highlights, text: "homepage", group: "property"))
        #expect(hasToken(nix, nixRes.highlights, text: "https://nixos.org", group: "string.special.url"))
        #expect(hasToken(nix, nixRes.highlights, text: "<nixpkgs>", group: "string"))
        #expect(hasToken(nix, nixRes.highlights, text: "null", group: "constant.builtin"))

        // 25. Agda — {-# OPTIONS #-}, nested {- ... -}, Unicode ℕ/→/≡, typed hole {! ... !}, Set
        let agda = """
        {-# OPTIONS --safe #-}
        {- outer {- 🚀 -} end -}
        module Demo where
        data Bit : Set where
          zero : Bit
        add : ℕ → ℕ → ℕ
        add x y = {! todo !}
        """
        let agdaRes = hl.highlight(content: agda, filetype: "agda")
        assertValidMonotonicUTF16(agda, agdaRes.highlights, label: "agda")
        #expect(hasToken(agda, agdaRes.highlights, text: "{-# OPTIONS --safe #-}", group: "attribute"))
        #expect(hasToken(agda, agdaRes.highlights, text: "{- outer {- 🚀 -} end -}", group: "comment"))
        #expect(hasToken(agda, agdaRes.highlights, text: "module", group: "keyword"))
        #expect(hasToken(agda, agdaRes.highlights, text: "Set", group: "type.builtin"))
        #expect(hasToken(agda, agdaRes.highlights, text: "add", group: "function"))
        #expect(hasToken(agda, agdaRes.highlights, text: "ℕ", group: "type.builtin"))
        #expect(hasToken(agda, agdaRes.highlights, text: "→", group: "operator"))
        #expect(hasToken(agda, agdaRes.highlights, text: "{! todo !}", group: "attribute"))
    }

    @Test("Web, markup, config, build, & diff languages (html, vue, xml, css, json, yaml, toml, hcl, make, diff, tsx) emit rich scopes")
    func webMarkupConfigBuildAndDiffLanguages() {
        let hl = BuiltInSyntaxHighlighter.shared

        // 26. HTML — multi-line comment, tag, attribute, URL, entity escape, embedded <script> & <style>
        let html = """
        <!DOCTYPE html>
        <!-- multi-line
             🚀 comment -->
        <a href="https://opentui.dev">Open &amp; 日本語</a>
        <style>
          .hero { color: #ff7b72; }
        </style>
        <script>
          function init() { return true; }
        </script>
        """
        let htmlRes = hl.highlight(content: html, filetype: "html")
        assertValidMonotonicUTF16(html, htmlRes.highlights, label: "html")
        #expect(hasToken(html, htmlRes.highlights, text: "DOCTYPE", group: "keyword"))
        #expect(hasToken(html, htmlRes.highlights, text: "<!-- multi-line\n     🚀 comment -->", group: "comment"))
        #expect(hasToken(html, htmlRes.highlights, text: "a", group: "tag"))
        #expect(hasToken(html, htmlRes.highlights, text: "href", group: "attribute"))
        #expect(hasToken(html, htmlRes.highlights, text: "https://opentui.dev", group: "string.special.url"))
        #expect(hasToken(html, htmlRes.highlights, text: "&amp;", group: "string.escape"))
        #expect(hasToken(html, htmlRes.highlights, text: "color", group: "property"))
        #expect(hasToken(html, htmlRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(html, htmlRes.highlights, text: "return", group: "keyword.return"))

        // 27. Vue — SFC <template> directives + {{ expr }} + <script> TS + <style> CSS
        let vue = """
        <template>
          <button v-if="ready" @click="run" :title="label">{{ count + 1 }}</button>
        </template>
        <script setup lang="ts">
        const count: number = 42
        </script>
        <style scoped>
        button { padding: 8px; }
        </style>
        """
        let vueRes = hl.highlight(content: vue, filetype: "vue")
        assertValidMonotonicUTF16(vue, vueRes.highlights, label: "vue")
        #expect(hasToken(vue, vueRes.highlights, text: "template", group: "tag"))
        #expect(hasToken(vue, vueRes.highlights, text: "v-if", group: "attribute"))
        #expect(hasToken(vue, vueRes.highlights, text: "@click", group: "attribute"))
        #expect(hasToken(vue, vueRes.highlights, text: ":title", group: "attribute"))
        #expect(hasToken(vue, vueRes.highlights, text: "{{", group: "punctuation.bracket"))
        #expect(hasToken(vue, vueRes.highlights, text: "1", group: "number"))
        #expect(hasToken(vue, vueRes.highlights, text: "const", group: "keyword"))
        #expect(hasToken(vue, vueRes.highlights, text: "padding", group: "property"))
        #expect(hasToken(vue, vueRes.highlights, text: "8px", group: "number"))

        // 28. XML — <?xml ?>, <!-- -->, <![CDATA[...]]>, namespaced tags & xmlns URL
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- XML 🚀 -->
        <svg:root xmlns:svg="https://www.w3.org/2000/svg">
          <![CDATA[raw <data> 日本語]]>
        </svg:root>
        """
        let xmlRes = hl.highlight(content: xml, filetype: "xml")
        assertValidMonotonicUTF16(xml, xmlRes.highlights, label: "xml")
        #expect(hasToken(xml, xmlRes.highlights, text: "xml", group: "keyword"))
        #expect(hasToken(xml, xmlRes.highlights, text: "version", group: "attribute"))
        #expect(hasToken(xml, xmlRes.highlights, text: "<!-- XML 🚀 -->", group: "comment"))
        #expect(hasToken(xml, xmlRes.highlights, text: "svg:root", group: "tag"))
        #expect(hasToken(xml, xmlRes.highlights, text: "https://www.w3.org/2000/svg", group: "string.special.url"))
        #expect(hasToken(xml, xmlRes.highlights, text: "raw <data> 日本語", group: "markup.raw"))

        // 29. CSS — /* */, @media, .class, :hover, property, #hex, units, url(...), !important
        let css = """
        /* Theme 🚀 */
        @media (min-width: 768px) {
          .card:hover {
            background-color: #1e293b !important;
            background-image: url(https://cdn.example.com/bg.png);
            gap: 1.5rem;
          }
        }
        """
        let cssRes = hl.highlight(content: css, filetype: "css")
        assertValidMonotonicUTF16(css, cssRes.highlights, label: "css")
        #expect(hasToken(css, cssRes.highlights, text: "/* Theme 🚀 */", group: "comment"))
        #expect(hasToken(css, cssRes.highlights, text: "@media", group: "keyword"))
        #expect(hasToken(css, cssRes.highlights, text: "768px", group: "number"))
        #expect(hasToken(css, cssRes.highlights, text: ".card", group: "type"))
        #expect(hasToken(css, cssRes.highlights, text: "background-color", group: "property"))
        #expect(hasToken(css, cssRes.highlights, text: "#1e293b", group: "number"))
        #expect(hasToken(css, cssRes.highlights, text: "!important", group: "keyword"))
        #expect(hasToken(css, cssRes.highlights, text: "https://cdn.example.com/bg.png", group: "string.special.url"))
        #expect(hasToken(css, cssRes.highlights, text: "1.5rem", group: "number"))

        // 30. JSON — escapes, URL, brackets, delimiters, property, number, boolean, constant
        let json = """
        {
          "homepage": "https://opentui.dev",
          "note": "line1\\n日本語 🚀",
          "ok": true,
          "empty": null
        }
        """
        let jsonRes = hl.highlight(content: json, filetype: "json")
        assertValidMonotonicUTF16(json, jsonRes.highlights, label: "json")
        #expect(hasToken(json, jsonRes.highlights, text: "\"homepage\"", group: "property"))
        #expect(hasToken(json, jsonRes.highlights, text: "https://opentui.dev", group: "string.special.url"))
        #expect(hasToken(json, jsonRes.highlights, text: "\\n", group: "string.escape"))
        #expect(hasToken(json, jsonRes.highlights, text: "{", group: "punctuation.bracket"))
        #expect(hasToken(json, jsonRes.highlights, text: ":", group: "punctuation.delimiter"))

        // 31. YAML — document marker, anchor, tag, multi-line block scalar `|`, URL, null, boolean
        let yaml = """
        ---
        # Deploy 🚀
        defaults: &base
          url: https://api.example.com
          notes: |
            line one 日本語
            line two 🚀
          retries: 3
          active: true
          extra: null
        """
        let yamlRes = hl.highlight(content: yaml, filetype: "yaml")
        assertValidMonotonicUTF16(yaml, yamlRes.highlights, label: "yaml")
        #expect(hasToken(yaml, yamlRes.highlights, text: "---", group: "punctuation.delimiter"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "&base", group: "attribute"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "https://api.example.com", group: "string.special.url"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "line one 日本語", group: "string"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "line two 🚀", group: "string"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "3", group: "number"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "true", group: "boolean"))
        #expect(hasToken(yaml, yamlRes.highlights, text: "null", group: "constant.builtin"))

        // 32. TOML — [table], [[array]], triple-quoted multiline string, URL, date, boolean
        let toml = """
        # Config 🚀
        [package]
        name = "opentui"
        homepage = "https://opentui.dev"
        published = 2026-11-19T12:00:00Z
        enabled = true
        desc = \"\"\"
        日本語 multiline
        \"\"\"
        [[bin]]
        name = "cli"
        """
        let tomlRes = hl.highlight(content: toml, filetype: "toml")
        assertValidMonotonicUTF16(toml, tomlRes.highlights, label: "toml")
        #expect(hasToken(toml, tomlRes.highlights, text: "package", group: "type"))
        #expect(hasToken(toml, tomlRes.highlights, text: "bin", group: "type"))
        #expect(hasToken(toml, tomlRes.highlights, text: "homepage", group: "property"))
        #expect(hasToken(toml, tomlRes.highlights, text: "https://opentui.dev", group: "string.special.url"))
        #expect(hasToken(toml, tomlRes.highlights, text: "2026-11-19T12:00:00Z", group: "number"))
        #expect(hasToken(toml, tomlRes.highlights, text: "true", group: "boolean"))

        // 33. HCL — resource, variable, builtin types, heredoc, null, function
        let hcl = """
        # Terraform 🚀
        variable "region" {
          type    = string
          default = null
        }
        resource "aws_s3_bucket" "app" {
          policy = <<EOF
        {"日本語": true}
        EOF
          tags = merge(var.base, { env = "prod" })
        }
        """
        let hclRes = hl.highlight(content: hcl, filetype: "hcl")
        assertValidMonotonicUTF16(hcl, hclRes.highlights, label: "hcl")
        #expect(hasToken(hcl, hclRes.highlights, text: "variable", group: "keyword"))
        #expect(hasToken(hcl, hclRes.highlights, text: "resource", group: "keyword"))
        #expect(hasToken(hcl, hclRes.highlights, text: "string", group: "type.builtin"))
        #expect(hasToken(hcl, hclRes.highlights, text: "null", group: "constant.builtin"))
        #expect(hasToken(hcl, hclRes.highlights, text: "merge", group: "function"))

        // 34. Make — .PHONY directive, variable assignment, $(wildcard ...), target, $@, recipe
        let make = """
        # Build 🚀
        .PHONY: all
        CC := clang
        SRCS := $(wildcard src/*.c)
        all: $(SRCS)
        \t$(CC) -o $@ "日本語"
        """
        let makeRes = hl.highlight(content: make, filetype: "make")
        assertValidMonotonicUTF16(make, makeRes.highlights, label: "make")
        #expect(hasToken(make, makeRes.highlights, text: ".PHONY", group: "keyword"))
        #expect(hasToken(make, makeRes.highlights, text: "CC", group: "property"))
        #expect(hasToken(make, makeRes.highlights, text: "wildcard", group: "function"))
        #expect(hasToken(make, makeRes.highlights, text: "all", group: "function"))
        #expect(hasToken(make, makeRes.highlights, text: "$@", group: "constant.builtin"))

        // 35. Diff — diff.plus, diff.minus, diff.delta, markup.heading, comment
        let diff = """
        --- a/main.swift
        +++ b/main.swift
        @@ -1,3 +1,3 @@
        -old 🚀
        +new 日本語
        ! changed context line
        Binary files a/icon.png and b/icon.png differ
        """
        let diffRes = hl.highlight(content: diff, filetype: "diff")
        assertValidMonotonicUTF16(diff, diffRes.highlights, label: "diff")
        #expect(hasToken(diff, diffRes.highlights, text: "@@ -1,3 +1,3 @@", group: "markup.heading"))
        #expect(hasToken(diff, diffRes.highlights, text: "-old 🚀", group: "diff.minus"))
        #expect(hasToken(diff, diffRes.highlights, text: "+new 日本語", group: "diff.plus"))
        #expect(hasToken(diff, diffRes.highlights, text: "! changed context line", group: "diff.delta"))
        #expect(hasToken(diff, diffRes.highlights, text: "Binary files a/icon.png and b/icon.png differ", group: "diff.delta"))

        // Bonus: TSX JSX tags
        let tsx = """
        export function Badge({ label }: Props) {
          return <span className="pill" data-ok={true}>{label}</span>
        }
        """
        let tsxRes = hl.highlight(content: tsx, filetype: "tsx")
        assertValidMonotonicUTF16(tsx, tsxRes.highlights, label: "tsx")
        #expect(hasToken(tsx, tsxRes.highlights, text: "function", group: "keyword.function"))
        #expect(hasToken(tsx, tsxRes.highlights, text: "span", group: "tag"))
        #expect(hasToken(tsx, tsxRes.highlights, text: "className", group: "attribute"))
        #expect(hasToken(tsx, tsxRes.highlights, text: "true", group: "boolean"))
    }

    @Test("Markdown & markdown_inline emit conceal captures, strong/italic/link scopes, and integrate with treeSitterToTextChunks & detectLinks")
    func markdownConcealAndLinks() {
        let hl = BuiltInSyntaxHighlighter.shared
        let style = makeFullTreeSitterStyle()

        let md = """
        # OpenTUI 🚀
        See **bold** and *italic* and [Docs 日本語](https://opentui.dev/docs) or https://swift.org
        ```rust
        println!("hi");
        ```
        """
        let res = hl.highlight(content: md, filetype: "markdown")
        #expect(res.warning == nil)
        assertValidMonotonicUTF16(md, res.highlights, label: "markdown")

        #expect(hasToken(md, res.highlights, text: "# OpenTUI 🚀", group: "markup.heading"))
        #expect(hasToken(md, res.highlights, text: "bold", group: "markup.strong"))
        #expect(hasToken(md, res.highlights, text: "italic", group: "markup.italic"))
        #expect(hasToken(md, res.highlights, text: "Docs 日本語", group: "markup.link.label"))
        #expect(hasToken(md, res.highlights, text: "https://opentui.dev/docs", group: "markup.link.url"))
        #expect(hasToken(md, res.highlights, text: "https://swift.org", group: "string.special.url"))
        #expect(res.highlights.contains { $0.group == "conceal" && $0.meta?.conceal == "" })
        #expect(res.highlights.contains { $0.group == "conceal" && $0.meta?.conceal == " " })
        #expect(res.highlights.contains { utf16Slice(md, $0) == "```rust" && $0.meta?.concealLines == "" })

        // With conceal enabled: ** / * / [ ] ( ) / fence lines are concealed cleanly
        let concealedChunks = treeSitterToTextChunks(
            content: md,
            highlights: res.highlights,
            syntaxStyle: style,
            conceal: ConcealOptions(enabled: true)
        )
        let concealedText = concealedChunks.map(\.text).joined()
        #expect(concealedText.contains("See bold and italic and Docs 日本語 https://opentui.dev/docs"))
        #expect(!concealedText.contains("**bold**"))
        #expect(!concealedText.contains("```rust"))
        #expect(concealedText.contains("println!(\"hi\");"))

        // With conceal disabled: 100% lossless round-trip of original Markdown
        let rawChunks = treeSitterToTextChunks(
            content: md,
            highlights: res.highlights,
            syntaxStyle: style,
            conceal: ConcealOptions(enabled: false)
        )
        #expect(rawChunks.map(\.text).joined() == md)

        // markdown_inline highlights inline links, entities, and conceal captures directly
        let inline = "Visit [OpenTUI](https://opentui.dev) &amp; *fast* **pure Swift**"
        let inlineRes = hl.highlight(content: inline, filetype: "markdown_inline")
        assertValidMonotonicUTF16(inline, inlineRes.highlights, label: "markdown_inline")
        #expect(hasToken(inline, inlineRes.highlights, text: "OpenTUI", group: "markup.link.label"))
        #expect(hasToken(inline, inlineRes.highlights, text: "https://opentui.dev", group: "markup.link.url"))
        #expect(hasToken(inline, inlineRes.highlights, text: "fast", group: "markup.italic"))
        #expect(hasToken(inline, inlineRes.highlights, text: "pure Swift", group: "markup.strong"))
        #expect(inlineRes.highlights.contains { utf16Slice(inline, $0) == "&amp;" && $0.meta?.conceal == "&" })

        // Verify detectLinks attaches OSC 8 hyperlinks to concealed Markdown link chunks
        let mdWithMeta = treeSitterToTextChunksWithMetadata(
            content: inline,
            highlights: inlineRes.highlights,
            syntaxStyle: style,
            conceal: ConcealOptions(enabled: true)
        )
        let linked = detectLinks(
            mdWithMeta.chunks,
            context: DetectLinksContext(
                content: inline,
                highlights: inlineRes.highlights,
                sourceRanges: mdWithMeta.ranges.map { LinkSourceRange(start: $0.lowerBound, end: $0.upperBound) },
                syntaxStyle: style
            )
        )
        #expect(linked.contains { $0.text == "OpenTUI" && $0.link?.url == "https://opentui.dev" })
    }

    @Test("Emits every required upstream Tree-Sitter capture scope across the grammar suite")
    func emitsAllRequiredTreeSitterCaptureScopes() {
        let hl = BuiltInSyntaxHighlighter.shared
        let snippets: [(String, String)] = [
            ("rust", "/* c */\n#[derive(Debug)]\npub fn f(x: usize) -> Option<usize> { println!(\"hi\\n\"); return Some(x.count_ones() as usize); }"),
            ("swift", "let u = \"https://swift.org\"\nlet n: Int? = nil\nlet ok = true && 42 > 0\nlet p = u.count"),
            ("html", "<div data-id=\"1\">hi</div>"),
            ("markdown", "# Title\n**bold** *italic* `raw` [OpenTUI](https://opentui.dev)"),
            ("diff", "+added\n-removed\n! changed"),
        ]

        var observedScopes: Set<String> = []
        for (ft, src) in snippets {
            let res = hl.highlight(content: src, filetype: ft)
            assertValidMonotonicUTF16(src, res.highlights, label: "scopes-\(ft)")
            for h in res.highlights {
                observedScopes.insert(h.group)
            }
        }

        let requiredScopes: [String] = [
            "keyword", "keyword.function", "keyword.return", "keyword.operator",
            "type", "type.builtin", "function", "function.method", "function.macro",
            "string", "string.escape", "string.special.url", "comment", "number",
            "boolean", "constant.builtin", "operator", "punctuation.bracket",
            "punctuation.delimiter", "tag", "attribute", "property", "variable.parameter",
            "markup.heading", "markup.raw", "markup.link.label", "markup.link.url",
            "markup.strong", "markup.italic", "conceal", "diff.plus", "diff.minus", "diff.delta",
        ]

        for scope in requiredScopes {
            #expect(observedScopes.contains(scope), "Missing required Tree-Sitter scope: \(scope)")
        }
    }

    @Test("All 34 upstream languages preserve exact UTF-16 CJK/emoji round-trip through treeSitterToTextChunks and TreeSitterClient")
    func all34LanguagesUTF16RoundTripAndTreeSitterClient() async throws {
        let hl = BuiltInSyntaxHighlighter.shared
        let style = makeFullTreeSitterStyle()

        let samples: [(String, String)] = [
            ("python", "# 日本語 🚀\ndef f(x: int) -> str:\n    return \"🇺🇸\""),
            ("rust", "// 日本語 🚀\npub fn f(x: usize) -> bool { println!(\"{}\", x); true }"),
            ("go", "// 日本語 🚀\npackage main\nfunc f(s string) error { return nil }"),
            ("cpp", "// 日本語 🚀\n#include <vector>\nint f(int n) { return n; }"),
            ("csharp", "// 日本語 🚀\npublic class A { public string F(int n) { return \"🇺🇸\"; } }"),
            ("bash", "# 日本語 🚀\nexport MSG=\"hi 🇺🇸\"\necho $MSG"),
            ("c", "/* 日本語 🚀 */\n#include <stdio.h>\nint f(const char *s) { return 0; }"),
            ("java", "/* 日本語 🚀 */\nclass A { int f(int n) { return n; } }"),
            ("kotlin", "// 日本語 🚀\nfun f(s: String): Int { return 1 }"),
            ("ruby", "# 日本語 🚀\ndef f(x)\n  return \"🇺🇸\"\nend"),
            ("php", "<?php\n// 日本語 🚀\nfunction f(string $s): int { return 1; }\n?>"),
            ("scala", "// 日本語 🚀\ndef f(n: Int): Option[Int] = Some(n)"),
            ("html", "<!-- 日本語 🚀 -->\n<div class=\"x\">🇺🇸</div>"),
            ("vue", "<template><p :title=\"t\">{{ n + 1 }} 🚀</p></template>"),
            ("hcl", "# 日本語 🚀\nresource \"null_resource\" \"a\" { count = 1 }"),
            ("json", "{\"日本語\": \"🚀🇺🇸\", \"n\": 42, \"ok\": true}"),
            ("yaml", "# 日本語 🚀\nname: \"🇺🇸\"\ncount: 7"),
            ("haskell", "-- 日本語 🚀\nf :: Int -> Maybe Int\nf x = Just x"),
            ("css", "/* 日本語 🚀 */\n.box { width: 100%; color: #fff; }"),
            ("julia", "# 日本語 🚀\nfunction f(x::Int64)\n  return x + 1\nend"),
            ("lua", "-- 日本語 🚀\nlocal function f(x) return x or nil end"),
            ("ocaml", "(* 日本語 🚀 *)\nlet f (x : int) = Some x"),
            ("clojure", "; 日本語 🚀\n(defn f [x] {:v x :ok true})"),
            ("swift", "// 日本語 🚀\nfunc f(x: Int) -> Bool { return x > 0 }"),
            ("toml", "# 日本語 🚀\n[app]\nname = \"🇺🇸\"\ncount = 3"),
            ("nix", "# 日本語 🚀\nlet x = \"🇺🇸\"; in { enabled = true; }"),
            ("diff", "@@ -1 +1 @@\n-旧 🚀\n+新 🇺🇸"),
            ("elixir", "# 日本語 🚀\ndefmodule M do\n  def f(x), do: {:ok, x}\nend"),
            ("fsharp", "// 日本語 🚀\nlet f (x: int) = Some x"),
            ("r", "# 日本語 🚀\nf <- function(x) { return(TRUE) }"),
            ("make", "# 日本語 🚀\nCC := clang\nall:\n\t$(CC) --version"),
            ("vim", "\" 日本語 🚀\nlet g:msg = '🇺🇸'\nfunction! F()\n  return v:true\nendfunction"),
            ("xml", "<!-- 日本語 🚀 -->\n<root id=\"1\">🇺🇸</root>"),
            ("agda", "-- 日本語 🚀\nmodule M where\nf : ℕ → ℕ\nf x = x"),
        ]

        #expect(samples.count == 34)
        #expect(Set(samples.map(\.0)) == Set(TreeSitterGrammars.upstreamParserFiletypes))

        let client = TreeSitterClient(options: TreeSitterClientOptions(dataPath: "/virtual/34-langs"))
        try await client.initialize()

        for (lang, source) in samples {
            let result = hl.highlight(content: source, filetype: lang)
            #expect(result.warning == nil, "Unexpected warning for \(lang): \(result.warning ?? "")")
            #expect(!result.highlights.isEmpty, "Expected non-empty highlights for \(lang)")
            assertValidMonotonicUTF16(source, result.highlights, label: lang)

            let chunks = treeSitterToTextChunks(
                content: source,
                highlights: result.highlights,
                syntaxStyle: style,
                conceal: ConcealOptions(enabled: false)
            )
            #expect(chunks.map(\.text).joined() == source, "UTF-16 round-trip failed for \(lang)")

            let outcome = await client.highlightOnce(source, filetype: lang)
            #expect(outcome.warning == nil, "TreeSitterClient warning for \(lang)")
            #expect(outcome.highlights == result.highlights)
        }

        await client.destroy()
    }
}

// MARK: - Custom Grammar Registration Suite

@Suite("TreeSitterCustomGrammarRegistration", .serialized)
struct TreeSitterCustomGrammarRegistrationTests {
    @Test("Isolated TreeSitterGrammarRegistry supports custom grammar registration, aliases, built-in override, and unregister")
    func isolatedCustomGrammarRegistration() {
        let registry = TreeSitterGrammarRegistry()
        let hl = BuiltInSyntaxHighlighter(registry: registry)

        #expect(!hl.supports(filetype: "kdl"))
        #expect(!hl.supports(filetype: "kdlfile"))

        registry.register(filetype: "kdl", aliases: ["kdlfile"]) { units in
            guard !units.isEmpty else { return [] }
            return [SimpleHighlight(0, min(4, units.count), "keyword")]
        }

        #expect(hl.supports(filetype: "kdl"))
        #expect(hl.supports(filetype: "kdlfile"))
        #expect(registry.registeredCustomFiletypes() == ["kdl"])

        let res = hl.highlight(content: "node \"🚀\"", filetype: "kdlfile")
        #expect(res.warning == nil)
        #expect(res.highlights == [SimpleHighlight(0, 4, "keyword")])

        // Overriding a built-in grammar routes through custom grammar until unregistered
        registry.register(filetype: "toml") { units in
            [SimpleHighlight(0, units.count, "comment")]
        }
        let overridden = hl.highlight(content: "a = 1", filetype: "toml")
        #expect(overridden.highlights == [SimpleHighlight(0, 5, "comment")])

        registry.unregister(filetype: "toml")
        let restored = hl.highlight(content: "a = 1", filetype: "toml")
        #expect(restored.highlights.contains { $0.group == "property" })

        registry.resetCustomGrammars()
        #expect(!hl.supports(filetype: "kdl"))
        #expect(hl.supports(filetype: "rust"))
    }

    @Test("Shared TreeSitterGrammars.registerGrammar integrates directly with BuiltInSyntaxHighlighter.shared")
    func sharedCustomGrammarRegistration() {
        defer { TreeSitterGrammars.resetCustomGrammars() }

        struct ToyGrammar: TreeSitterGrammar {
            let filetype = "toyscript"
            let aliases = ["toy"]
            func highlight(utf16 units: [UInt16]) -> [SimpleHighlight] {
                guard units.count >= 3 else { return [] }
                return [SimpleHighlight(0, 3, "function.macro")]
            }
        }

        TreeSitterGrammars.registerGrammar(ToyGrammar())
        #expect(BuiltInSyntaxHighlighter.supports(filetype: "toyscript"))
        #expect(BuiltInSyntaxHighlighter.supports(filetype: "toy"))

        let res = BuiltInSyntaxHighlighter.shared.highlight(content: "run!", filetype: "toy")
        #expect(res.warning == nil)
        #expect(res.highlights == [SimpleHighlight(0, 3, "function.macro")])

        TreeSitterGrammars.unregisterGrammar(filetype: "toyscript")
        #expect(!BuiltInSyntaxHighlighter.supports(filetype: "toy"))
    }
}
