import Foundation

/// A fresh directory under the temporary directory, removed when released. `path` has its symlinks resolved
/// (`/private/var/…`), as `pwd -P` and the process inspection APIs report it.
final class TemporaryDirectory: @unchecked Sendable {
    let path: String

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ATermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // `resolvingSymlinksInPath()` maps /private/var back to /var; realpath gives what processes report.
        guard let resolved = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        path = String(cString: resolved)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    func write(_ relative: String, _ content: String) throws {
        try write(relative, Data(content.utf8))
    }

    func write(_ relative: String, _ data: Data) throws {
        let target = file(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: target))
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: file(relative), withIntermediateDirectories: true)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: file(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: file(relative))
    }
}
