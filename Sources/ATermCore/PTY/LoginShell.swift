import Foundation

/// Resolves the user's login shell. See SPEC/pty/pty.md.
public enum LoginShell {
    public static let fallback = "/bin/zsh"

    /// The shell to run and its argument vector; argv[0] starts with `-` so it runs as a login shell.
    public static func command(environment: [String: String], accountShell: String?,
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:))
        -> (executable: String, arguments: [String]) {
        let candidates = [environment["SHELL"], accountShell].compactMap { $0 }.filter { !$0.isEmpty }
        let shell = candidates.first(where: isExecutable) ?? fallback
        let name = (shell as NSString).lastPathComponent
        return (shell, ["-" + name])
    }

    /// The shell recorded in the user's account (`pw_shell`).
    public static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }
}
