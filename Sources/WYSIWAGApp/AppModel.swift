import AppKit
import SwiftUI
import WYSIWAGCore

@MainActor final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()
    @Published var settings: AppSettings
    @Published var running = false
    @Published var status = "Ready to capture"
    @Published var rowsWritten = 0
    @Published var pending = 0
    @Published var blocked = 0
    @Published var quarantined = 0
    @Published var recovering = 0
    @Published var secrets: Set<SecretAccount> = []
    @Published var signingIn = false
    @Published var applying = false
    @Published var errorMessage: String?
    @Published var classifierFailure: String?
    @Published var selectedSection = "Capture"
    @Published var databases: [NotionDatabase] = []
    private let defaults: UserDefaults
    private let capture = ScreenCapture()
    private let oauth: GoogleOAuth
    private let notionOAuth: NotionOAuth
    private let keychain: KeychainStore
    private var queue: RetryQueue!
    private var recorder: CaptureRecorder!
    private var classifier: JevClassifier!
    private let captureTask = SerialTask()
    private var queueTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var signInGeneration = 0
    private var suspended = false
    private let evidenceMode: Bool
    @Published private var catalog: [String: [String: String]] = [:]
    private var generation = 0
    private var settingsWindow: NSWindow?

    override init() {
        let args = ProcessInfo.processInfo.arguments
        evidenceMode = args.contains("--evidence")
        defaults = evidenceMode ? UserDefaults(suiteName: "com.wysiwag.evidence")! : .standard
        keychain = KeychainStore(service: evidenceMode ? "com.wysiwag.evidence" : "com.wysiwag.app")
        oauth = GoogleOAuth(keychain: keychain)
        notionOAuth = NotionOAuth(keychain: keychain)
        var loaded = (defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }) ?? AppSettings()
        if args.contains("--reset-evidence"), evidenceMode { loaded = AppSettings(); loaded.localFolder = "/tmp/WYSIWAG-Evidence" }
        if let i = args.firstIndex(of: "--language"), args.indices.contains(i + 1) { loaded.language = args[i + 1] }
        if let i = args.firstIndex(of: "--capture-folder"), args.indices.contains(i + 1) {
            loaded.localFolder = args[i + 1]; loaded.mode = .all; loaded.interval = 5
        }
        if let i = args.firstIndex(of: "--capture-mode"), args.indices.contains(i + 1), let mode = CaptureMode(rawValue: args[i + 1]) { loaded.mode = mode }
        loaded.validate(); settings = loaded
        super.init()
        configureRecorder()
        let store = keychain
        classifier = JevClassifier(probabilityThreshold: settings.jevProbabilityThreshold,
                                   stateURL: applicationFolder.appendingPathComponent("jev-cooldown.state"), key: { try store.read(.jevKey) })
        startQueue()
        Task { catalog = await Task.detached { Self.readCatalog() }.value }
        Task { await refreshSecrets() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockScreen), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlockScreen), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockScreen), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unlockScreen), name: NSWorkspace.didWakeNotification, object: nil)
        if let i = args.firstIndex(of: "--capture-seconds"), args.indices.contains(i + 1) {
            let duration = min(300, max(1, Double(args[i + 1]) ?? 30))
            Task {
                // Give the evidence fixture window time to become frontmost.
                try? await Task.sleep(for: .seconds(3)); start()
                try? await Task.sleep(for: .seconds(duration)); pause()
            }
        }
    }
    var effectiveLanguage: String {
        if settings.language == "en" || settings.language == "ja" { return settings.language }
        return Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "WYSIWAG"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func tr(_ key: String) -> String { catalog[key]?[effectiveLanguage] ?? key }
    nonisolated private static func readCatalog() -> [String: [String: String]] {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("WYSIWAG_WYSIWAGApp.bundle")) }
        guard let url = (packaged ?? Bundle.module).url(forResource: "Localizable", withExtension: "xcstrings"), let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let strings = root["strings"] as? [String: [String: Any]] else { return [:] }
        return strings.mapValues { entry in
            (entry["localizations"] as? [String: [String: Any]] ?? [:]).mapValues { ($0["stringUnit"] as? [String: String])?["value"] ?? "" }
        }
    }
    private var applicationFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(evidenceMode ? "WYSIWAG-Evidence" : "WYSIWAG")
    }
    private func configureRecorder(previous: ScreenSnapshot? = nil) {
        let base = applicationFolder
        let notionOAuth = notionOAuth, notionClientID = settings.notionClientID, oauth = oauth
        let notion = NotionWriter(refresh: { try await notionOAuth.refresh(clientID: notionClientID) },
                                  token: { try await notionOAuth.accessToken(clientID: notionClientID) })
        let sheets = SheetsWriter { clientID in try await oauth.accessToken(clientID: clientID) }
        queue = RetryQueue(folder: base.appendingPathComponent("Outbox"), notion: notion, sheets: sheets)
        recorder = CaptureRecorder(csv: CSVWriter(folder: URL(fileURLWithPath: settings.localFolder)), queue: queue, previous: previous)
    }
    func apply(_ newSettings: AppSettings) async -> Bool {
        guard !applying else { return false }
        guard newSettings.mode != .smart || secrets.contains(.jevKey) else { status = "SMART requires a TypeSafe key"; return false }
        guard !newSettings.notionEnabled || (!newSettings.notionClientID.isEmpty && !newSettings.notionDatabaseID.isEmpty && !newSettings.notionDataSourceID.isEmpty && secrets.contains(.notionAccessToken)),
              !newSettings.googleEnabled || (!newSettings.googleClientID.isEmpty && !newSettings.spreadsheetID.isEmpty && !newSettings.sheetName.isEmpty && secrets.contains(.googleRefreshToken)) else {
            show(SafeFailure.invalidConfiguration); return false
        }
        applying = true
        defer { applying = false }
        let wasRunning = running
        let oldCapture = captureTask, oldQueue = queueTask, oldFolder = settings.localFolder
        pause(); queueTask?.cancel(); cancelSignIn()
        await oldCapture.wait(); await oldQueue?.value; await signInTask?.value
        let previous: ScreenSnapshot?
        do { previous = oldFolder == newSettings.localFolder ? try await recorder.lastWrittenScreen() : nil }
        catch { show(error); startQueue(); return false }
        settings = newSettings; settings.validate()
        if settings.mode != .smart { classifierFailure = nil }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
        configureRecorder(previous: previous); await classifier.setThreshold(settings.jevProbabilityThreshold); startQueue()
        applying = false
        if wasRunning { start() }
        return true
    }
    func toggle() { running ? pause() : start() }
    func pause() { generation += 1; running = false; captureTask.cancel(); status = "Paused" }
    @objc private func lockScreen() { suspended = true; generation += 1; captureTask.cancel(); status = "Skipped for privacy" }
    @objc private func unlockScreen() { suspended = false; if running { running = false; start() } }
    func start() {
        guard !running, !applying, !suspended else { return }
        guard settings.mode != .smart || secrets.contains(.jevKey) else { status = "SMART requires a TypeSafe key"; return }
        guard ScreenCapture.hasPermission else { status = "Screen Recording permission required"; return }
        running = true; generation += 1
        let token = generation, currentSettings = settings, recorder = recorder!, classifier = classifier!
        captureTask.start { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.running && self.generation == token {
                let started = Date()
                if self.suspended { self.status = "Skipped for privacy" }
                else {
                    do {
                        self.status = "Capturing"
                        let screen = try await self.capture.capture(settings: currentSettings)
                        try Task.checkCancellation()
                        let written = try await recorder.record(screen, settings: currentSettings, classifier: classifier)
                        guard self.generation == token else { return }
                        if written { self.rowsWritten += 1 }
                        if currentSettings.mode == .smart, let failure = await classifier.lastFailure {
                            self.classifierFailure = self.tr("SMART error; row kept, retrying with backoff.") + " " + self.localizedError(failure)
                        } else { self.classifierFailure = nil }
                        self.status = written ? "Saved locally" : "No meaningful change"
                    } catch {
                        if Task.isCancelled || self.generation != token { return }
                        switch error as? SafeFailure {
                        case .privacySkip, .noWindow: self.status = "Skipped for privacy"
                        case .permission: self.status = "Screen Recording permission required"; self.running = false
                        case .localWrite, .queueWrite: self.show(error); self.running = false; self.status = "Capture paused after an error"
                        default: self.status = "Capture unavailable; will retry"
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(max(0.1, currentSettings.interval - Date().timeIntervalSince(started)))) } catch { return }
            }
        }
    }
    private func startQueue() {
        guard !signingIn else { return }
        let queue = queue!, snapshot = settings
        queueTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await queue.drain(settings: snapshot)
                    let state = try await queue.status()
                    if Task.isCancelled { return }
                    self.pending = state.pending; self.blocked = state.blocked; self.quarantined = state.quarantined; self.recovering = state.recovering
                } catch { if !Task.isCancelled { self.show(error) } }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func retryQueue() { Task { do { try await queue.retryBlocked() } catch { show(error) } } }
    func requestPermission() { ScreenCapture.requestPermission() }
    func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: settings.localFolder)) }
    private func localizedError(_ error: any Error) -> String {
        if case let SafeFailure.http(status, _) = error { return tr("Cloud request failed. Local CSV is safe.") + " (HTTP \(status))" }
        return tr(Diagnostics.message(for: error))
    }
    func show(_ error: any Error) { errorMessage = localizedError(error) }
    func refreshSecrets() async {
        let store = keychain
        secrets = await Task.detached { Set(SecretAccount.allCases.filter { store.contains($0) }) }.value
    }
    func saveSecret(_ value: String, account: SecretAccount) async -> Bool {
        let store = keychain
        do {
            try await Task.detached { try store.set(value, for: account) }.value
            await oauth.invalidate(); await notionOAuth.invalidate(); await refreshSecrets(); return true
        } catch { show(error); return false }
    }
    func deleteSecret(_ account: SecretAccount) {
        let store = keychain
        Task {
            do {
                if account == .googleRefreshToken { try await oauth.signOut() }
                else if account == .notionAccessToken { try await notionOAuth.signOut() }
                else {
                    try await Task.detached { try store.delete(account) }.value
                    await oauth.invalidate(); await notionOAuth.invalidate()
                }
                await refreshSecrets()
                if account == .jevKey && settings.mode == .smart { pause(); status = "SMART requires a TypeSafe key" }
            } catch { show(error) }
        }
    }
    func signIn(notion: Bool) {
        guard !signingIn else { return }; signingIn = true
        signInGeneration += 1
        let token = signInGeneration
        signInTask = Task {
            defer {
                if token == signInGeneration { signingIn = false; if !applying { startQueue() } }
            }
            let retiringQueue = queueTask
            retiringQueue?.cancel()
            await retiringQueue?.value
            do {
                try Task.checkCancellation()
                let openBrowser: @Sendable (URL) async -> Bool = { url in await MainActor.run { NSWorkspace.shared.open(url) } }
                if notion {
                    try await notionOAuth.authorize(clientID: settings.notionClientID, openBrowser: openBrowser)
                    databases = try await notionOAuth.databases(clientID: settings.notionClientID)
                } else { try await oauth.authorize(clientID: settings.googleClientID, openBrowser: openBrowser) }
                await refreshSecrets()
            } catch { if !Task.isCancelled { show(error) } }
        }
    }
    func loadDatabases() {
        Task { do { databases = try await notionOAuth.databases(clientID: settings.notionClientID) } catch { show(error) } }
    }
    func cancelSignIn() { signInTask?.cancel() }
}
