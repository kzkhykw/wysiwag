import Foundation
import Testing
@testable import WYSIWAGCore

extension CoreTests {
    @Test func noSecretsInRepositoryOrBuildAndCompleteLocalization() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for script in ["scripts/check-no-secrets.sh", "scripts/check-localization.py"] {
            let process = Process()
            process.currentDirectoryURL = root
            process.executableURL = URL(fileURLWithPath: script.hasSuffix(".sh") ? "/bin/bash" : "/usr/bin/env")
            process.arguments = script.hasSuffix(".sh") ? [script] : ["python3", script]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
