import AppKit
// Older SDKs lack Sendable annotations; framework objects remain confined to ScreenCapture.
@preconcurrency import ScreenCaptureKit
import Vision
import ApplicationServices
import Carbon

public struct ActiveWindow: Sendable, Equatable {
    public var pid: pid_t
    public var app: String
    public var bundleID: String
    public var windowID: CGWindowID
    public var title: String
}

public enum PrivacyGuard {
    public static func isExcluded(app: String, bundleID: String, exclusions: [String]) -> Bool {
        exclusions.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame || $0.caseInsensitiveCompare(app) == .orderedSame }
    }
    @MainActor public static func activeWindow(settings: AppSettings) throws -> ActiveWindow {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              session[kCGSessionOnConsoleKey as String] as? Bool != false else { throw SafeFailure.privacySkip }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        guard idle < settings.idleMinutes * 60, !IsSecureEventInputEnabled() else { throw SafeFailure.privacySkip }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw SafeFailure.noWindow }
        let bundle = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundle
        // Never capture our credential entry sheets (or any WYSIWAG window).
        guard bundle != "com.wysiwag.app",
              !isExcluded(app: name, bundleID: bundle, exclusions: settings.excludedApps) else { throw SafeFailure.privacySkip }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = window[kCGWindowNumber as String] as? UInt32 else { throw SafeFailure.noWindow }
        return ActiveWindow(pid: app.processIdentifier, app: name, bundleID: bundle, windowID: id,
                            title: window[kCGWindowName as String] as? String ?? "")
    }

    public static func secureFieldFocused(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeDowncast(element, to: AXUIElement.self)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        if subrole as? String == kAXSecureTextFieldSubrole as String { return true }
        var protected: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, "AXProtectedContent" as CFString, &protected)
        return protected as? Bool == true
    }
}

public actor ScreenCapture {
    public init() {}
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @MainActor public static func requestPermission() { CGRequestScreenCaptureAccess() }

    public func capture(settings: AppSettings) async throws -> ScreenSnapshot {
        guard Self.hasPermission else { throw SafeFailure.permission }
        let active = try await PrivacyGuard.activeWindow(settings: settings)
        guard !PrivacyGuard.secureFieldFocused(pid: active.pid) else { throw SafeFailure.privacySkip }
        let capturedAt = Date()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == active.windowID }),
                  let app = window.owningApplication else { throw SafeFailure.noWindow }
            let frame = window.frame
            guard let display = content.displays.max(by: { Self.intersectionArea($0.frame, frame) < Self.intersectionArea($1.frame, frame) }),
                  Self.intersectionArea(display.frame, frame) > 0 else { throw SafeFailure.noWindow }
            // Display composition, restricted to the active app and its visible window bounds.
            // Never use desktopIndependentWindow, which could capture an obscured window's content.
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let config = SCStreamConfiguration()
            let rect = display.frame.intersection(window.frame)
            config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = max(1, Int(rect.width * 2))
            config.height = max(1, Int(rect.height * 2))
            config.showsCursor = false
            config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let text = try OCR.recognize(image)
            try Task.checkCancellation()
            let after = try await PrivacyGuard.activeWindow(settings: settings)
            guard after == active, !PrivacyGuard.secureFieldFocused(pid: after.pid) else { throw SafeFailure.privacySkip }
            return ScreenSnapshot(timestamp: capturedAt, app: active.app, bundleID: active.bundleID,
                                  title: window.title ?? active.title, text: text)
        } catch let error as SafeFailure { throw error }
        catch is CancellationError { throw SafeFailure.cancelled }
        catch { throw SafeFailure.capture }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

public enum OCR {
    private static var resources: Bundle {
        if let base = Bundle.main.resourceURL,
           let packaged = Bundle(url: base.appendingPathComponent("WYSIWAG_WYSIWAGCore.bundle")) { return packaged }
        return Bundle.module
    }
    public static var fixtureURL: URL { resources.url(forResource: "ocr-fixture", withExtension: "png")! }
    public static var changedFixtureURL: URL { resources.url(forResource: "ocr-changed", withExtension: "png")! }
    public static func recognize(file: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SafeFailure.capture }
        return try recognize(image)
    }
    public static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ja-JP"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        // Group text into visual lines, then read top-to-bottom, left-to-right within each line.
        // Avoid a tolerance-based sort comparator (which is not a strict ordering).
        let ordered = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[VNRecognizedTextObservation]] = []
        for item in ordered {
            if let last = lines.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - item.boundingBox.midY) < min(anchor.boundingBox.height, item.boundingBox.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else { lines.append([item]) }
        }
        return TextNormalizer.normalize(lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }.joined(separator: "\n"))
    }
}
