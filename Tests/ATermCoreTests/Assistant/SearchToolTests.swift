import Foundation
import Testing
import ATermCore

struct SearchCase: CustomTestStringConvertible, Sendable {
    let name: String
    let request: SearchRequest
    let expected: String

    var testDescription: String { name }
}

private func lines(_ lines: String...) -> String {
    lines.joined(separator: "\n")
}

private let searchCases: [SearchCase] = [
    SearchCase(name: "regex", request: SearchRequest(pattern: "alpha"),
               expected: lines("notes.txt:1:alpha", "notes.txt:3:alphabet", "src/main.swift:1:let alpha = 1")),
    SearchCase(name: "ignore case", request: SearchRequest(pattern: "alpha", ignoreCase: true),
               expected: lines("notes.txt:1:alpha", "notes.txt:3:alphabet", "src/main.swift:1:let alpha = 1",
                               "src/main.swift:3:let x = ALPHA + 2")),
    SearchCase(name: "literal", request: SearchRequest(pattern: "call(x)", literal: true),
               expected: "src/util.txt:2:call(x)"),
    SearchCase(name: "regex with parentheses", request: SearchRequest(pattern: "call(x)"), expected: "No matches found."),
    SearchCase(name: "context", request: SearchRequest(pattern: "mark", path: "ctx.txt", context: 1),
               expected: lines("ctx.txt-2-two", "ctx.txt:3:mark A", "ctx.txt-4-four", "--", "ctx.txt-7-seven",
                               "ctx.txt:8:mark B", "ctx.txt-9-nine")),
    SearchCase(name: "limit", request: SearchRequest(pattern: "hit", path: "many.txt", limit: 2),
               expected: lines("many.txt:1:hit 1", "many.txt:2:hit 2",
                               "[2 matches limit reached. Use limit=4 for more, or refine the pattern]")),
    SearchCase(name: "long line", request: SearchRequest(pattern: "y+", path: "long.txt"),
               expected: "long.txt:1:" + String(repeating: "y", count: 500) + "... [truncated]"),
    SearchCase(name: "no match", request: SearchRequest(pattern: "zzz"), expected: "No matches found."),
    SearchCase(name: "missing path", request: SearchRequest(pattern: "x", path: "missing"),
               expected: "Error: no such file or directory: missing"),
]

private func matchingTree() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory()
    try directory.write("notes.txt", "alpha\nBeta\nalphabet\n")
    try directory.write("src/main.swift", "let alpha = 1\n// TODO: fix\nlet x = ALPHA + 2\n")
    try directory.write("src/util.txt", "nothing here\ncall(x)\n")
    try directory.write("ctx.txt", "one\ntwo\nmark A\nfour\nfive\nsix\nseven\nmark B\nnine\n")
    try directory.write("long.txt", String(repeating: "y", count: 600) + "\n")
    try directory.write("many.txt", (1...150).map { "hit \($0)\n" }.joined())
    return directory
}

@Test("ASSIST-SEARCH-001 matching lines come back sorted with options and notices", arguments: searchCases)
func ASSIST_SEARCH_001(_ testCase: SearchCase) throws {
    let directory = try matchingTree()
    #expect(SearchTool.run(testCase.request, workingDirectory: directory.path) == testCase.expected)

    let token = "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    try directory.write("secret.txt", String(repeating: "s", count: 480) + " " + token + "\n")
    let redacted = SearchTool.run(SearchRequest(pattern: "ghp_", path: "secret.txt"), workingDirectory: directory.path,
                                  redact: SecretRedactor(knownSecrets: []).redact)
    #expect(redacted.contains("<GITHUB_TOKEN_1:40chars>"))
    #expect(!redacted.contains("ghp_"))
    try directory.write("wide.txt", (1...1000).map { "w \($0) " + String(repeating: "x", count: 400) + "\n" }.joined())
    let wide = SearchTool.run(SearchRequest(pattern: "w", path: "wide.txt", limit: 1000), workingDirectory: directory.path)
    #expect(wide.utf8.count <= 24 * 1024 + 200)
    #expect(wide.hasSuffix("[Output limit of 24 KiB reached. Use path, glob or a narrower pattern]"))

    let invalid = SearchTool.run(SearchRequest(pattern: "("), workingDirectory: directory.path)
    #expect(invalid.hasPrefix("Error: invalid regular expression"))
    #expect(!invalid.contains("\n"))

    let defaultLimit = SearchTool.run(SearchRequest(pattern: "hit"), workingDirectory: directory.path)
    #expect(defaultLimit == (1...100).map { "many.txt:\($0):hit \($0)" }.joined(separator: "\n")
        + "\n[100 matches limit reached. Use limit=200 for more, or refine the pattern]")
}

struct FileSelectionCase: CustomTestStringConvertible, Sendable {
    let name: String
    let request: SearchRequest
    let paths: [String]

    var testDescription: String { name }
}

private let selectionCases: [FileSelectionCase] = [
    FileSelectionCase(name: "whole tree", request: SearchRequest(pattern: "needle"),
                      paths: [".env.example", ".hidden/h.txt", "docs/readme.md", "keep.log", "local.txt",
                              "src/a.swift", "src/b.ts", "src/gen/c.swift", "sub/root-only.txt"]),
    FileSelectionCase(name: "glob", request: SearchRequest(pattern: "needle", glob: "*.swift"),
                      paths: ["src/a.swift", "src/gen/c.swift"]),
    FileSelectionCase(name: "glob with exclusion", request: SearchRequest(pattern: "needle", glob: "src/** !src/gen/**"),
                      paths: ["src/a.swift", "src/b.ts"]),
    FileSelectionCase(name: "glob with braces", request: SearchRequest(pattern: "needle", glob: "*.{swift,ts}"),
                      paths: ["src/a.swift", "src/b.ts", "src/gen/c.swift"]),
    FileSelectionCase(name: "subdirectory", request: SearchRequest(pattern: "needle", path: "sub"),
                      paths: ["sub/root-only.txt"]),
    FileSelectionCase(name: "ignored file given explicitly", request: SearchRequest(pattern: "needle", path: "app.log"),
                      paths: ["app.log"]),
]

@Test("ASSIST-SEARCH-002 hidden files are searched and ignored git and binary files are not", arguments: selectionCases)
func ASSIST_SEARCH_002(_ testCase: FileSelectionCase) throws {
    let directory = try TemporaryDirectory()
    try directory.write(".gitignore", "*.log\nbuild/\n/root-only.txt\n!keep.log\ndocs/**/*.tmp\n")
    try directory.write("sub/.gitignore", "local.txt\n")
    try directory.write("bin.dat", Data("needle\n".utf8) + Data([0, 1, 2]))
    for file in [".git/config", "app.log", "keep.log", "root-only.txt", "sub/root-only.txt", "build/out.txt",
                 "sub/build/x.txt", "docs/a/b/c.tmp", "docs/c.tmp", "docs/readme.md", "sub/local.txt", "local.txt",
                 ".hidden/h.txt", ".env.example", "src/a.swift", "src/b.ts", "src/gen/c.swift"] {
        try directory.write(file, "needle\n")
    }
    let output = SearchTool.run(testCase.request, workingDirectory: directory.path)
    #expect(output == testCase.paths.map { "\($0):1:needle" }.joined(separator: "\n"))
}
