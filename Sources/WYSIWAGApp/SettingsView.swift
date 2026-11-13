import SwiftUI
import AppKit
import WYSIWAGCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppSettings()
    @State private var secretAccount: SecretAccount?
    @State private var exclusionText = ""
    private let sections = [("Capture", "viewfinder"), ("Destinations", "tray.and.arrow.down"), ("Privacy", "hand.raised"), ("General", "gearshape")]
    private func t(_ key: String) -> String { model.tr(key) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "viewfinder.circle.fill").font(.system(size: 28)).foregroundStyle(.teal)
                    Text("WYSIWAG").font(.headline)
                }.padding(.vertical, 24).padding(.horizontal, 14)
                ForEach(sections, id: \.0) { section in
                    Button { model.selectedSection = section.0 } label: {
                        Label(t(section.0), systemImage: section.1).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.selectedSection == section.0 ? Color.teal.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("section-" + section.0).accessibilityLabel(t(section.0))
                }
                Spacer()
                Label(t("Local first"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
                Text("v0.1.0").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.bottom, 16)
            }.padding(.horizontal, 12).frame(width: 174).background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header; Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch model.selectedSection {
                        case "Destinations": destinations
                        case "Privacy": privacy
                        case "General": general
                        default: capture
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Text(t("Changes apply when saved.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(t("Save changes")) { Task { _ = await save() } }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.applying)
                        .keyboardShortcut("s").accessibilityIdentifier("save-settings").accessibilityLabel(t("Save changes"))
                }.padding(20)
            }
        }.frame(width: 900, height: 740)
        .onAppear { draft = model.settings; exclusionText = draft.excludedApps.joined(separator: "\n") }
        .sheet(item: $secretAccount) { account in SecretEditor(model: model, account: account) }
        .alert(t("Attention"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(t("OK")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func save() async -> Bool {
        draft.excludedApps = exclusionText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if await model.apply(draft) { draft = model.settings; return true }
        return false
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t(model.selectedSection)).font(.system(size: 27, weight: .semibold))
                    Text(t("A plain table of what was on screen.")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(t(model.running ? "Pause capture" : "Resume capture")) { model.toggle() }.controlSize(.large).accessibilityIdentifier("toggle-capture").accessibilityLabel(t(model.running ? "Pause capture" : "Resume capture"))
            }
            HStack(spacing: 8) {
                Circle().fill(model.running ? Color.red : Color.secondary).frame(width: 7, height: 7)
                Text(t(model.status)).font(.caption).accessibilityIdentifier("capture-status")
                Spacer(); Text(t("Rows saved") + ": \(model.rowsWritten)").font(.caption).monospacedDigit()
            }.foregroundStyle(.secondary)
            if let failure = model.classifierFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.padding(28)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(t(title)).font(.headline); content() }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
    private var capture: some View {
        Group {
            card("Capture rhythm") {
                HStack {
                    Text(t("Interval (seconds)")); Spacer()
                    TextField("", value: $draft.interval, format: .number).frame(width: 70).accessibilityIdentifier("interval")
                    Stepper("", value: $draft.interval, in: 1...3600, step: 1).labelsHidden()
                }
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases, id: \.self) { mode in
                        Button {
                            draft.mode = mode
                        } label: {
                            Text(mode.rawValue).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(draft.mode == mode ? Color.teal.opacity(0.17) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(draft.mode == mode ? Color.teal : .clear))
                        }.buttonStyle(.plain).disabled(mode == .smart && !model.secrets.contains(.jevKey))
                            .accessibilityIdentifier("mode-" + mode.rawValue).accessibilityLabel(mode.rawValue)
                            .accessibilityValue(draft.mode == mode ? t("Selected") : t("Not selected"))
                    }
                }
                Text(t("ALL saves every capture. AUTO detects changes locally. SMART asks Jev on every capture.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.secrets.contains(.jevKey) { Text(t("SMART requires a TypeSafe key")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack { Text(t("AUTO text similarity threshold")); Spacer(); Text(draft.similarityThreshold, format: .number.precision(.fractionLength(2))).monospacedDigit() }
                Slider(value: $draft.similarityThreshold, in: 0.1...0.97, step: 0.01).tint(.teal).accessibilityIdentifier("auto-threshold")
            }
            card("SMART · TypeSafe Jev") {
                Text(t("Sends previous and current app, title and text to TypeSafe on every capture. Errors keep the row and retry with backoff.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                secretRow("TypeSafe API key", account: .jevKey)
                HStack {
                    Text(t("Changed probability")); Spacer()
                    TextField("", value: $draft.jevProbabilityThreshold, format: .number).frame(width: 70).accessibilityIdentifier("jev-threshold")
                }
            }
            if !ScreenCapture.hasPermission {
                HStack {
                    Label(t("Screen Recording permission required"), systemImage: "rectangle.badge.exclamationmark")
                    Spacer(); Button(t("Grant access")) { model.requestPermission() }
                }.font(.caption)
                Text(t("Restart WYSIWAG after granting Screen Recording.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var destinations: some View {
        Group {
            card("Local CSV · Always on") {
                Text(t("The local CSV is saved before any cloud write.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(draft.localFolder).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    Spacer(); Button(t("Choose folder…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        panel.begin { response in if response == .OK, let url = panel.url { draft.localFolder = url.path } }
                    }
                }
            }
            card("Notion") {
                Toggle(t("Enable Notion"), isOn: $draft.notionEnabled)
                    .disabled(!draft.notionEnabled && (!model.secrets.contains(.notionAccessToken) || draft.notionDatabaseID.isEmpty || draft.notionDataSourceID.isEmpty))
                    .accessibilityIdentifier("notion-enabled")
                field("Notion OAuth client ID", text: $draft.notionClientID)
                secretRow("Notion OAuth client secret", account: .notionClientSecret)
                HStack {
                    Text(t("Notion access token")); Spacer()
                    Text(t(model.secrets.contains(.notionAccessToken) ? "Set" : "Not set")).foregroundStyle(.secondary)
                    Button(t("Connect Notion")) { Task { if await save() { model.signIn(notion: true) } } }.disabled(model.signingIn || model.applying)
                    Button(t("Delete")) { model.deleteSecret(.notionAccessToken) }.disabled(!model.secrets.contains(.notionAccessToken))
                }
                HStack {
                    Text(t("Granted databases")); Spacer(); Button(t("Refresh list")) { Task { if await save() { model.loadDatabases() } } }
                }
                Picker(t("Target database"), selection: $draft.notionDataSourceID) {
                    Text(t("Choose a database")).tag("")
                    if !draft.notionDataSourceID.isEmpty && !model.databases.contains(where: { $0.id == draft.notionDataSourceID }) {
                        Text(draft.notionDatabaseID).tag(draft.notionDataSourceID)
                    }
                    ForEach(model.databases) { database in Text(database.title).tag(database.id) }
                }.onChange(of: draft.notionDataSourceID) { _, value in
                    if value.isEmpty { draft.selectNotionDatabase(nil) }
                    else if let match = model.databases.first(where: { $0.id == value }) { draft.selectNotionDatabase(match) }
                }
                Text(t("Grant access during OAuth, then select a database. Required properties: Name, Timestamp, App, Dwell.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("Google Sheets") {
                Toggle(t("Enable Google Sheets"), isOn: $draft.googleEnabled)
                    .disabled(!draft.googleEnabled && (!model.secrets.contains(.googleRefreshToken) || draft.spreadsheetID.isEmpty || draft.sheetName.isEmpty))
                    .accessibilityIdentifier("google-enabled")
                field("OAuth desktop client ID", text: $draft.googleClientID)
                secretRow("OAuth client secret (optional)", account: .googleClientSecret)
                HStack {
                    Text(t("Google refresh token")); Spacer()
                    Text(t(model.secrets.contains(.googleRefreshToken) ? "Set" : "Not set")).foregroundStyle(.secondary)
                    Button(t("Sign in with Google")) { Task { if await save() { model.signIn(notion: false) } } }.disabled(model.signingIn || model.applying)
                    Button(t("Delete")) { model.deleteSecret(.googleRefreshToken) }.disabled(!model.secrets.contains(.googleRefreshToken))
                }
                field("Spreadsheet ID", text: $draft.spreadsheetID); field("Sheet name", text: $draft.sheetName)
            }
            if model.signingIn { Button(t("Cancel sign-in")) { model.cancelSignIn() } }
            card("Cloud retry queue") {
                HStack {
                    Text(t("Pending") + ": \(model.pending) · " + t("Needs attention") + ": \(model.blocked)")
                    Spacer(); Button(t("Retry blocked writes")) { model.retryQueue() }
                }
                Text(t("Failed writes stay on this Mac. Disabled destinations stop sending queued rows.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var privacy: some View {
        Group {
            card("Keep private screens private") {
                Text(t("Locked screens, secure input and idle sessions are skipped. WYSIWAG never records its own windows."))
                HStack { Text(t("Skip after idle minutes")); Spacer(); TextField("", value: $draft.idleMinutes, format: .number).frame(width: 70) }
                Text(t("Secure-field detection also uses Accessibility when granted. Detection depends on the app.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("Excluded apps") {
                Text(t("One bundle ID or exact app name per line. System Settings is excluded entirely by default.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $exclusionText).font(.system(.body, design: .monospaced)).frame(height: 160).padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            Label(t("No screenshots are saved. OCR runs on this Mac."), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var general: some View {
        Group {
            card("Language") {
                Picker(t("App language"), selection: $draft.language) {
                    Text(t("Follow system")).tag("system"); Text(t("English")).tag("en"); Text(t("Japanese")).tag("ja")
                }.accessibilityIdentifier("language")
                Text(t("Language changes take effect when saved.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("About WYSIWAG") {
                Text(t("What you see is what AI Get.")).font(.headline)
                Text(t("A local-first, open-source screen-to-table recorder for macOS. Your CSV is the source of truth.")).foregroundStyle(.secondary)
                Link(t("Source code and setup guide"), destination: URL(string: "https://github.com/kzkhykw/wysiwag")!)
            }
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(t(title)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); TextField("", text: text).textFieldStyle(.roundedBorder) }
    }
    private func secretRow(_ title: String, account: SecretAccount) -> some View {
        HStack {
            Text(t(title)); Spacer()
            Text(t(model.secrets.contains(account) ? "Set" : "Not set")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("secret-status-" + account.rawValue)
            Button(t("Replace…")) { secretAccount = account }.accessibilityIdentifier("replace-" + account.rawValue).accessibilityLabel(t("Replace…"))
            Button(t("Delete")) { model.deleteSecret(account) }.disabled(!model.secrets.contains(account)).accessibilityIdentifier("delete-" + account.rawValue).accessibilityLabel(t("Delete"))
        }
    }
}

extension SecretAccount: Identifiable { public var id: String { rawValue } }
struct SecretEditor: View {
    @ObservedObject var model: AppModel
    let account: SecretAccount
    @State private var value = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.tr("Replace credential")).font(.title2.bold())
            Text(model.tr("Stored only in macOS Keychain. The saved value is never displayed.")).foregroundStyle(.secondary)
            SecureField(model.tr("New credential"), text: $value).textFieldStyle(.roundedBorder).accessibilityIdentifier("credential-input")
            HStack {
                Spacer(); Button(model.tr("Cancel")) { value = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.tr("Save to Keychain")) {
                    saving = true
                    Task { if await model.saveSecret(value, account: account) { value = ""; dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).disabled(value.isEmpty || saving).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-credential")
            }
        }.padding(28).frame(width: 460).onDisappear { value = "" }
    }
}
