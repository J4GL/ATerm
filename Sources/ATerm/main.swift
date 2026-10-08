import Foundation
import ATermApp
import ATermCore

if CommandLine.arguments.contains("--version") {
    print("ATerm \(ATermVersion.string)")
    exit(0)
}

ATermMain.run()
