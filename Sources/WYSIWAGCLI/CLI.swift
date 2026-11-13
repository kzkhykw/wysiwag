import Foundation
import WYSIWAGCore

@main struct WYSIWAGCLI {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "check-packaged-resources":
                guard OCR.fixtureURL.path.contains(".app/"), try OCR.recognize(file: OCR.fixtureURL).contains("日本語") else { throw SafeFailure.invalidConfiguration }
                print("PASS: packaged resources and bilingual OCR")
            case "verify": try await VerificationDriver.run()
            case "capture": try await capture()
            default: print("Usage: wysiwag-cli capture --once --dry-run [--live | --image PATH]\n       wysiwag-cli verify --mock-base http://127.0.0.1:PORT --output PATH")
            }
        } catch {
            FileHandle.standardError.write(Data((Diagnostics.message(for: error) + "\n").utf8))
            exit(1)
        }
    }
    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    static func capture() async throws {
        guard CommandLine.arguments.contains("--once") else { throw SafeFailure.invalidConfiguration }
        let screen: ScreenSnapshot
        if CommandLine.arguments.contains("--live") { screen = try await ScreenCapture().capture(settings: AppSettings()) }
        else {
            let file = argument("--image").map { URL(fileURLWithPath: $0) } ?? OCR.fixtureURL
            let text = try await Task.detached { try OCR.recognize(file: file) }.value
            screen = ScreenSnapshot(app: "Bundled OCR fixture", bundleID: "com.wysiwag.fixture", title: "English + 日本語", text: text)
        }
        let row = CaptureRow(screen: screen, previousWrittenAt: nil)
        if CommandLine.arguments.contains("--dry-run") { print(CSV.header + CSV.encode(row), terminator: "") }
        else {
            let folder = argument("--output") ?? AppSettings().localFolder
            try await CSVWriter(folder: URL(fileURLWithPath: folder)).append(row)
            print("Saved one local CSV row.")
        }
    }
}
