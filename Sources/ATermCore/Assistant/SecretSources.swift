import Foundation

/// A secret value known in advance, and the name its placeholder shows.
public struct KnownSecret: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Finds the secrets present on the machine: secret-named variables, `.env` files and credential files.
/// See SPEC/assistant/redaction.md.
public enum SecretSources {
    public static func collect(environments: [[String: String]], dotEnvDirectories: [String],
                               credentialFiles: [String]) -> [KnownSecret] {
        var secrets: [KnownSecret] = []
        for environment in environments {
            for (name, value) in environment.sorted(by: { $0.key < $1.key })
            where isSecretName(name) && isCandidate(value) {
                secrets.append(KnownSecret(name: name, value: value))
            }
        }
        for directory in Set(dotEnvDirectories).sorted() {
            for file in dotEnvFiles(in: directory) {
                secrets += dotEnvSecrets(in: (directory as NSString).appendingPathComponent(file))
            }
        }
        for file in credentialFiles {
            secrets += credentialFileSecrets(in: file)
        }
        return secrets
    }

    /// Files holding tokens for common tools.
    public static func defaultCredentialFiles(home: String) -> [String] {
        [".aws/credentials", ".npmrc", ".docker/config.json", ".kube/config", ".netrc", ".git-credentials",
         ".config/gh/hosts.yml"].map { (home as NSString).appendingPathComponent($0) }
    }

    /// Words that make a variable or key name secret. See SPEC/assistant/contract.md.
    static let secretWords: Set<String> = ["TOKEN", "SECRET", "SECRETS", "PASSWORD", "PASSWD", "PASS", "KEY", "APIKEY",
                                           "CREDENTIAL", "CREDENTIALS", "AUTH", "PRIVATE", "SESSION", "COOKIE", "DSN"]

    /// True when a part of the name (split on `_`, `-`, `.` and lower→upper case changes) is a secret word.
    public static func isSecretName(_ name: String) -> Bool {
        nameParts(name).contains { secretWords.contains($0) }
    }

    static func nameParts(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previousIsLower = false
        for character in name {
            if character == "_" || character == "-" || character == "." {
                parts.append(current)
                current = ""
                previousIsLower = false
                continue
            }
            if character.isUppercase && previousIsLower {
                parts.append(current)
                current = ""
            }
            current.append(character)
            previousIsLower = character.isLowercase
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }.map { $0.uppercased() }
    }

    /// A value long enough to be a secret, and not a path, a number or a boolean.
    static func isCandidate(_ value: String) -> Bool {
        guard value.count >= 8 else { return false }
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return false
        }
        if value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) { return false }
        let lowered = value.lowercased()
        return lowered != "true" && lowered != "false"
    }

    // MARK: - .env files

    private static let excludedDotEnvSuffixes = [".example", ".sample", ".template"]

    static func dotEnvFiles(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { name in
            (name == ".env" || name.hasPrefix(".env.")) && !excludedDotEnvSuffixes.contains { name.hasSuffix($0) }
        }.sorted()
    }

    private static func dotEnvSecrets(in path: String) -> [KnownSecret] {
        guard let text = readSmallFile(path) else { return [] }
        var secrets: [KnownSecret] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = unquoted(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            if isSecretName(name) && isCandidate(value) {
                secrets.append(KnownSecret(name: name, value: value))
            }
        }
        return secrets
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Credential files

    private static let keyValuePattern = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9_.-]*(?:token|secret|password|passwd|key|auth)[A-Za-z0-9_.-]*)"?\s*[:=]\s*"?([^"\s,]+)"#,
        options: [.caseInsensitive])
    private static let netrcPattern = try! NSRegularExpression(pattern: #"\bpassword\s+(\S+)"#)
    private static let urlPasswordPattern = try! NSRegularExpression(pattern: #"://[^\s:/@]+:([^\s@/]+)@"#)

    private static func credentialFileSecrets(in path: String) -> [KnownSecret] {
        guard let text = readSmallFile(path) else { return [] }
        var secrets: [KnownSecret] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            for match in keyValuePattern.matches(in: line, range: range) {
                guard let name = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line)
                else { continue }
                secrets.append(KnownSecret(name: String(line[name]), value: String(line[value])))
            }
            for pattern in [netrcPattern, urlPasswordPattern] {
                for match in pattern.matches(in: line, range: range) {
                    guard let value = Range(match.range(at: 1), in: line) else { continue }
                    secrets.append(KnownSecret(name: "PASSWORD", value: String(line[value])))
                }
            }
        }
        return secrets.filter { isCandidate($0.value) }
    }

    private static func readSmallFile(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= 1_048_576,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
