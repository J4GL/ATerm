import Foundation

/// Flags commands that can destroy data, change the system or publish something. See SPEC/assistant/safety.md.
///
/// The patterns match the raw command text: a false positive costs one confirmation, while parsing the
/// command would miss `xargs`, `$(…)`, `eval` or a command run over `ssh`.
public enum CommandRisk {
    /// A short reason when the command needs the user's approval, else nil.
    public static func assess(_ command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for rule in rules where rule.pattern.firstMatch(in: command, range: range) != nil {
            return rule.reason
        }
        return nil
    }

    private struct Rule {
        let pattern: NSRegularExpression
        let reason: String
    }

    /// The start of a command word: the text start or a shell separator.
    private static let start = #"(?:^|[\s;&|(`$])(?:[^\s;&|()`$]*/|\\)?"#
    /// Text up to the end of the current simple command.
    private static let sameCommand = #"[^;&|\n]*"#

    private static let rules: [Rule] = [
        rule(start + #"(sudo|su|doas)(\s|$)"#, "runs a command as another user"),
        rule(start + #"rm(\s"# + sameCommand + #")?\s(-[a-zA-Z]*[rRf][a-zA-Z]*|--recursive|--force)\b"#,
             "deletes files recursively or without confirmation"),
        rule(start + #"git(\s+-[^\s]+(\s+[^-\s][^\s]*)?)*\s+push\b"#, "publishes commits to a remote"),
        rule(start + #"git\s"# + sameCommand + #"\breset\s"# + sameCommand + #"--hard\b"#,
             "discards commits and uncommitted changes"),
        rule(start + #"git\s"# + sameCommand + #"\bclean\b"# + sameCommand + #"\s-[a-zA-Z]*f"#,
             "deletes untracked files"),
        rule(start + #"git\s"# + sameCommand + #"\bbranch\b"# + sameCommand + #"\s-D\b"#, "deletes a branch"),
        rule(start + #"git\s"# + sameCommand + #"\bcheckout\s"# + sameCommand + #"\s(--|\.)(\s|$)"#,
             "discards uncommitted changes"),
        rule(start + #"git\s"# + sameCommand + #"\brestore\b(?!"# + sameCommand + #"--staged)"#,
             "discards uncommitted changes"),
        rule(start + #"dd\b"# + sameCommand + #"\bof="#, "writes raw data to a file or a disk"),
        rule(start + #"(mkfs(\.\w+)?|newfs\w*|fdisk)\b"#, "formats a disk"),
        rule(start + #"diskutil\s+(erase\w*|partition\w*|zeroDisk|randomDisk|secureErase|reformat)\b"#,
             "erases or partitions a disk"),
        rule(start + #"(shutdown|reboot|halt)(\s|$)"#, "shuts the computer down or restarts it"),
        rule(start + #"launchctl\b"#, "changes system services"),
        rule(start + #"kill\b"# + sameCommand + #"\s-1(\s|$)"#, "kills every process"),
        rule(start + #"(killall|pkill)\s"#, "kills processes by name"),
        rule(start + #"(chmod|chown|chgrp)\b"# + sameCommand + #"\s-[a-zA-Z]*R"#,
             "changes permissions recursively"),
        rule(#"\b(curl|wget)\b[^;&\n]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|fish|python3?|perl|ruby)\b"#,
             "runs a script downloaded from the network"),
        rule(start + #"find\b"# + sameCommand + #"\s(-delete|-exec\s+rm)\b"#, "deletes the files it finds"),
        rule(start + #"(npm|pnpm|yarn|cargo|gem|poetry)\s+publish\b|\btwine\s+upload\b"#, "publishes a package"),
        rule(start + #"docker\s+push\b"#, "publishes an image"),
        rule(start + #"kubectl\s"# + sameCommand + #"\bdelete\b"#, "deletes cluster resources"),
        rule(start + #"terraform\s+(apply|destroy)\b"#, "changes cloud infrastructure"),
        rule(start + #"gh\s+(repo\s+delete|release\s+(create|delete|upload|edit)|pr\s+merge)\b"#,
             "changes a GitHub repository"),
        rule(#"(?i)\b(drop\s+(database|table|schema)|truncate\s+table)\b"#, "deletes database data"),
        rule(start + #"security\b"# + sameCommand + #"(\s-[a-zA-Z]*w\b|\bdump-keychain\b|\bdelete-\w+)"#,
             "reads or deletes keychain secrets"),
        rule(start + #"defaults\s+delete\b"#, "deletes preferences"),
        rule(start + #"crontab\b"# + sameCommand + #"\s-r\b"#, "deletes the crontab"),
        rule(#">\s*/dev/r?disk"#, "writes to a disk device"),
        rule(#":\(\)\s*\{"#, "defines a fork bomb"),
        rule(#"(?s)(?=.*<[A-Z0-9_]+_\d+(?::\d+chars)?>)(?=.*\b(curl|wget|nc|ncat|ssh|scp|sftp|rsync|ftp|http|telnet)\b)"#,
             "sends a secret over the network"),
    ]

    private static func rule(_ pattern: String, _ reason: String) -> Rule {
        // The patterns are constants: a failure here is a programming error caught by the tests.
        Rule(pattern: try! NSRegularExpression(pattern: pattern), reason: reason)
    }
}
