import Foundation

public enum ATermVersion {
    public static let string = "1.0.0"
}

/// Environment of the shell started in a terminal. See SPEC/pty/pty.md.
public enum ShellEnvironment {
    public static let termProgram = "ATerm"

    /// Variables describing another terminal or shell nesting, never passed on.
    static let removed = ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "SHLVL", "OLDPWD",
                          "COLUMNS", "LINES", "TERM_PROGRAM_VERSION"]

    public static func make(base: [String: String], localeIdentifier: String,
                            localeExists: (String) -> Bool = ShellEnvironment.isInstalledLocale) -> [String: String] {
        var environment = base
        for key in removed { environment[key] = nil }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = termProgram
        environment["TERM_PROGRAM_VERSION"] = ATermVersion.string
        if environment["LANG"]?.isEmpty ?? true {
            environment["LANG"] = utf8Locale(for: localeIdentifier, exists: localeExists)
        }
        return environment
    }

    static func utf8Locale(for identifier: String, exists: (String) -> Bool) -> String {
        let base = identifier.split(separator: "@").first.map(String.init) ?? identifier
        let candidate = "\(base).UTF-8"
        return exists(candidate) ? candidate : "en_US.UTF-8"
    }

    public static func isInstalledLocale(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)")
    }
}
