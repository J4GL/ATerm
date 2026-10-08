import Foundation
import Testing
import ATermCore

@Test("ASSIST-CONTEXT-003 the login shell environment is resolved with a time limit")
func ASSIST_CONTEXT_003() async throws {
    let directory = try TemporaryDirectory()
    try directory.write("fake-shell", """
        #!/bin/bash
        # Behaves like a login shell run as: fake -i -l -c CMD
        echo 'welcome!'
        export FROM_PROFILE=yes
        export PATH=/opt/fake/bin:$PATH
        eval "$4"

        """)
    try directory.write("slow-shell", "#!/bin/bash\nsleep 30\n")
    for name in ["fake-shell", "slow-shell"] {
        chmod(directory.file(name), 0o755)
    }

    let resolved = await LoginEnvironment.resolve(shell: directory.file("fake-shell"),
                                                  base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                  timeout: 5)
    let environment = try #require(resolved)
    #expect(environment["FROM_PROFILE"] == "yes")
    #expect(environment["PATH"]?.hasPrefix("/opt/fake/bin:") == true)
    #expect(!environment.keys.contains { $0.contains("welcome") })

    let started = Date()
    let slow = await LoginEnvironment.resolve(shell: directory.file("slow-shell"),
                                              base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                              timeout: 0.5)
    #expect(slow == nil)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(await eventually(timeout: 3) {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", directory.file("slow-shell")]
        check.standardOutput = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        return check.terminationStatus != 0
    })
}
