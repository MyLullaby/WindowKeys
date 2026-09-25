import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

// All callers run on the main thread. Write each entry immediately so a later
// crash does not discard an in-memory queue; keep at most two 1 MiB files.
private final class DiagnosticLog {
    static let shared = DiagnosticLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WindowKeys", isDirectory: true))
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "diagnosticLoggingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "diagnosticLoggingEnabled") }
    }
    private let directory: URL
    private let limit = 1_048_576
    private var current: URL { directory.appendingPathComponent("current.log") }
    private var previous: URL { directory.appendingPathComponent("previous.log") }

    init(directory: URL) { self.directory = directory }

    func write(_ message: String) {
        guard Self.isEnabled else { return }
        do {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message.prefix(4096))\n"
            let data = Data(line.utf8)
            let size = (try? files.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > limit {
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                try files.moveItem(at: current, to: previous)
            }
            if !files.fileExists(atPath: current.path) {
                guard files.createFile(atPath: current.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("WindowKeys: cannot save diagnostic log: %@", error.localizedDescription)
        }
    }

    func export(to destination: URL) throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        var data = Data("WindowKeys \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nExported: \(Date())\nLogging enabled: \(Self.isEnabled)\nInput switching enabled: \(InputMethodPreferences.isEnabled)\nAccessibility trusted: \(AXIsProcessTrusted())\nLogs contain app/input-source identifiers, not typed text or window titles.\n\n".utf8)
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            data.append(try Data(contentsOf: url))
        }
        try data.write(to: destination, options: .atomic)
    }
}

private func diagnosticLog(_ format: String, _ arguments: CVarArg...) {
    let message = String(format: format, arguments: arguments)
    NSLog("%@", message)
    DiagnosticLog.shared.write(message)
}

private enum WindowCommand: UInt32, CaseIterable {
    case resize = 1
    case center
    case maximize
    case leftHalf
    case rightHalf
    case fullscreen

    var title: String {
        switch self {
        case .center: return "居中"
        case .resize: return "调整大小"
        case .maximize: return "最大化"
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        case .fullscreen: return "进入/退出全屏"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .resize: return UInt32(kVK_ANSI_C)
        case .center: return UInt32(kVK_DownArrow)
        case .maximize: return UInt32(kVK_UpArrow)
        case .leftHalf: return UInt32(kVK_LeftArrow)
        case .rightHalf: return UInt32(kVK_RightArrow)
        case .fullscreen: return UInt32(kVK_ANSI_F)
        }
    }

    var keyEquivalent: String {
        switch self {
        case .resize: return "c"
        case .center: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .maximize: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .leftHalf: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightHalf: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .fullscreen: return "f"
        }
    }

    var nativeMenuIdentifier: String? {
        switch self {
        case .resize, .fullscreen: return nil
        case .center: return "_zoomCenter:"
        case .maximize: return "_zoomFill:"
        case .leftHalf: return "_zoomLeft:"
        case .rightHalf: return "_zoomRight:"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        self == .fullscreen ? [.control, .shift] : [.control, .command]
    }

    var carbonModifiers: UInt32 {
        self == .fullscreen ? UInt32(controlKey | shiftKey) : UInt32(controlKey | cmdKey)
    }
}

private enum ResizePreferences {
    static let widthKey = "resizeWidthPercent"
    static let heightKey = "resizeHeightPercent"
    static let defaultPercent = 75.0
    static let minimumPercent = 30.0
    static let maximumPercent = 100.0

    static var widthPercent: Double { value(forKey: widthKey) }
    static var heightPercent: Double { value(forKey: heightKey) }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            widthKey: defaultPercent,
            heightKey: defaultPercent
        ])
    }

    static func set(widthPercent: Double, heightPercent: Double) {
        UserDefaults.standard.set(clamp(widthPercent), forKey: widthKey)
        UserDefaults.standard.set(clamp(heightPercent), forKey: heightKey)
    }

    private static func value(forKey key: String) -> Double {
        clamp(UserDefaults.standard.double(forKey: key))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, minimumPercent), maximumPercent)
    }
}

private struct InputSourceDescriptor {
    let identifier: String
    let localizedName: String
}

private struct InputSourceTarget {
    let sourceIdentifier: String
    let inputModeIdentifier: String?
}

private enum InputMethodPreferences {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "inputMethodSwitchingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "inputMethodSwitchingEnabled") }
    }

    private static let defaultSourceKey = "defaultInputSourceID"
    private static let appOverridesKey = "appInputSourceOverrides"

    static var defaultSourceIdentifier: String? {
        get { UserDefaults.standard.string(forKey: defaultSourceKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultSourceKey) }
    }

    static var appOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: appOverridesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: appOverridesKey) }
    }

    static func sourceIdentifier(for bundleIdentifier: String) -> String? {
        guard isEnabled else { return nil }
        return appOverrides[bundleIdentifier] ?? defaultSourceIdentifier
    }

    static func setOverride(_ sourceIdentifier: String, for bundleIdentifier: String) {
        var overrides = appOverrides
        overrides[bundleIdentifier] = sourceIdentifier
        appOverrides = overrides
    }

    static func removeOverride(for bundleIdentifier: String) {
        var overrides = appOverrides
        overrides.removeValue(forKey: bundleIdentifier)
        appOverrides = overrides
    }
}

private enum InputSourceCatalog {
    static func availableInputSources() -> [InputSourceDescriptor] {
        let properties = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary
        guard let result = TISCreateInputSourceList(properties, false) else { return [] }
        let sources = result.takeRetainedValue() as NSArray
        var descriptors: [InputSourceDescriptor] = []
        var seenIdentifiers = Set<String>()

        for case let source as TISInputSource in sources {
            guard let identifier: String = property(source, key: kTISPropertyInputSourceID),
                  let name: String = property(source, key: kTISPropertyLocalizedName),
                  seenIdentifiers.insert(identifier).inserted else { continue }
            descriptors.append(InputSourceDescriptor(identifier: identifier, localizedName: name))
        }

        return descriptors.sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
    }

    static func currentInputSourceIdentifier() -> String? {
        guard let result = TISCopyCurrentKeyboardInputSource() else { return nil }
        let source = result.takeRetainedValue()
        return property(source, key: kTISPropertyInputSourceID)
    }

    static func selectionTarget(identifier: String) -> InputSourceTarget? {
        let properties = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let result = TISCreateInputSourceList(properties, false) else { return nil }
        let sources = result.takeRetainedValue() as NSArray
        let matches = (sources as? [TISInputSource] ?? []).filter {
            property($0, key: kTISPropertyInputSourceIsSelectCapable) as Bool? == true &&
                property($0, key: kTISPropertyInputSourceIsEnabled) as Bool? == true
        }
        let source = matches.first {
            let mode: String? = property($0, key: kTISPropertyInputModeID)
            return mode == nil || mode?.isEmpty == true
        } ?? matches.first
        guard let source else { return nil }

        let inputModeIdentifier: String? = property(source, key: kTISPropertyInputModeID)
        return InputSourceTarget(
            sourceIdentifier: identifier,
            inputModeIdentifier: inputModeIdentifier
        )
    }

    static func currentInputSourceMatches(_ target: InputSourceTarget) -> Bool? {
        // A failed read is not evidence that a toggle is needed.
        guard let result = TISCopyCurrentKeyboardInputSource() else { return nil }
        let current = result.takeRetainedValue()
        guard property(current, key: kTISPropertyInputSourceID) as String? == target.sourceIdentifier else {
            return false
        }

        guard let targetModeIdentifier = target.inputModeIdentifier, !targetModeIdentifier.isEmpty else {
            return true
        }
        return property(current, key: kTISPropertyInputModeID) as String? == targetModeIdentifier
    }

    private static func property<T>(_ source: TISInputSource, key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

private final class InputMethodManager {
    private var activationObserver: NSObjectProtocol?
    private var switchWorkItem: DispatchWorkItem?

    init() {
        guard InputMethodPreferences.isEnabled else { return }
        if InputMethodPreferences.defaultSourceIdentifier == nil {
            InputMethodPreferences.defaultSourceIdentifier = InputSourceCatalog.currentInputSourceIdentifier()
                ?? InputSourceCatalog.availableInputSources().first?.identifier
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.scheduleInputSource(for: app)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        switchWorkItem?.cancel()
    }

    func applyToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        scheduleInputSource(for: app)
    }

    private func scheduleInputSource(for app: NSRunningApplication) {
        switchWorkItem?.cancel()
        guard InputMethodPreferences.isEnabled,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            self.switchInputSourceIfNeeded(for: app)
        }
        switchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func switchInputSourceIfNeeded(for app: NSRunningApplication) {
        guard InputMethodPreferences.isEnabled,
              let bundleIdentifier = app.bundleIdentifier,
              let targetIdentifier = InputMethodPreferences.sourceIdentifier(for: bundleIdentifier) else { return }
        diagnosticLog("WindowKeys: checking input source for %@; target=%@", bundleIdentifier, targetIdentifier)
        guard let target = InputSourceCatalog.selectionTarget(identifier: targetIdentifier) else {
            diagnosticLog("WindowKeys: target input source unavailable")
            return
        }
        guard let matches = InputSourceCatalog.currentInputSourceMatches(target) else {
            diagnosticLog("WindowKeys: cannot read current input source; skipping switch")
            return
        }
        guard !matches else {
            diagnosticLog("WindowKeys: input source already matches; skipping switch")
            return
        }
        guard AXIsProcessTrusted(),
              let eventSource = CGEventSource(stateID: .hidSystemState),
              let controlDown = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_Control), keyDown: true),
              let spaceDown = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_Space), keyDown: true),
              let spaceUp = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_Space), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_Control), keyDown: false) else {
            diagnosticLog("WindowKeys: cannot send input source shortcut for %@", bundleIdentifier)
            return
        }

        controlDown.flags = .maskControl
        spaceDown.flags = .maskControl
        spaceUp.flags = .maskControl
        controlUp.flags = []

        let events = [controlDown, spaceDown, spaceUp, controlUp]
        var started = false
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.02) { [weak self] in
                if index == 0 {
                    guard self != nil, InputMethodPreferences.isEnabled else { return }
                    started = true
                }
                // Once started, finish the key-up events even if disabled in between.
                guard started else { return }
                event.post(tap: .cghidEventTap)
                if index == events.count - 1 {
                    diagnosticLog("WindowKeys: sent Control-Space for %@ to switch to %@", bundleIdentifier, targetIdentifier)
                }
            }
        }
    }
}

private struct WindowFrame {
    var origin: CGPoint
    var size: CGSize

    var rect: CGRect { CGRect(origin: origin, size: size) }

}

private final class WindowGeometryAnimation: NSAnimation {
    private let applyFrame: (CGFloat) -> Bool
    private let completion: () -> Void
    private var cleanup: (() -> Void)?
    private var finished = false

    init(applyFrame: @escaping (CGFloat) -> Bool, completion: @escaping () -> Void,
         cleanup: @escaping () -> Void) {
        self.applyFrame = applyFrame
        self.completion = completion
        self.cleanup = cleanup
        super.init(duration: 0.3, animationCurve: .easeOut)
        animationBlockingMode = .nonblocking
        frameRate = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { cleanup?() }

    private func restoreState() {
        let action = cleanup
        cleanup = nil
        action?()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        super.stop()
        restoreState()
    }

    override var currentProgress: NSAnimation.Progress {
        didSet {
            guard !finished else { return }
            let eased = 1 - pow(1 - CGFloat(currentValue), 3)
            guard applyFrame(eased) else { cancel(); return }
            if currentProgress >= 1 {
                finished = true
                super.stop()
                defer { restoreState() }
                completion()
            }
        }
    }
}

private final class AccessibilityWindowController {
    static let shared = AccessibilityWindowController()

    private var activeAnimation: WindowGeometryAnimation?
    private var lastExternalPID: pid_t?

    var animationEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "animationEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "animationEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "animationEnabled") }
    }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalPID = app.processIdentifier
        }

        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
        }
    }

    // Settings become frontmost themselves; retain the last external app as the target.
    func currentExternalApplication() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
        }
        guard let lastExternalPID,
              let app = NSRunningApplication(processIdentifier: lastExternalPID),
              !app.isTerminated else { return nil }
        return app
    }

    func requestAccessibilityIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func cancelWindowAnimation() {
        activeAnimation?.cancel()
        activeAnimation = nil
    }

    func perform(_ command: WindowCommand) {
        diagnosticLog("WindowKeys: requested window command %u", command.rawValue)
        cancelWindowAnimation()
        guard AXIsProcessTrusted() else {
            diagnosticLog("WindowKeys: accessibility permission missing")
            showAccessibilityAlert()
            return
        }

        guard let application = focusedExternalApplication() else {
            diagnosticLog("WindowKeys: no focused external application")
            NSSound.beep()
            return
        }
        var targetPID: pid_t = 0
        AXUIElementGetPid(application, &targetPID)
        diagnosticLog("WindowKeys: target app %@; pid=%d",
                      NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier ?? "unknown", targetPID)

        if command == .fullscreen {
            toggleFullscreen(in: application)
            return
        }

        // Prefer native tiling to preserve system animation/tiling state. If the
        // menu action is unavailable or fails, the fallback below uses AX geometry.
        if let identifier = command.nativeMenuIdentifier {
            if !performNativeWindowCommand(identifier: identifier, on: application) {
                // Some apps do not expose the system's tiling menu through Accessibility.
                // Fall back to public AX position/size setters when the window supports them.
                if !performCustomGeometryCommand(command, in: application) {
                    NSSound.beep()
                }
            }
            return
        }

        guard let window = focusedWindow(in: application), let current = readFrame(of: window) else {
            diagnosticLog("WindowKeys: cannot read focused window geometry")
            NSSound.beep()
            return
        }

        guard let workArea = workAreaContaining(current.rect) else {
            diagnosticLog("WindowKeys: cannot find window screen")
            NSSound.beep()
            return
        }

        let size = CGSize(
            width: (workArea.width * CGFloat(ResizePreferences.widthPercent / 100)).rounded(),
            height: (workArea.height * CGFloat(ResizePreferences.heightPercent / 100)).rounded()
        )
        guard isSettable(kAXSizeAttribute as CFString, on: window) else {
            diagnosticLog("WindowKeys: window size is not settable")
            NSSound.beep()
            return
        }
        resize(window, in: application, from: current.size, to: size)
    }

    private func focusedExternalApplication() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        var app: AXUIElement?

        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue {
            app = (focusedValue as! AXUIElement)
        }

        if let focusedApp = app {
            var pid: pid_t = 0
            AXUIElementGetPid(focusedApp, &pid)
            if pid == ProcessInfo.processInfo.processIdentifier, let lastExternalPID {
                app = AXUIElementCreateApplication(lastExternalPID)
            } else if pid != ProcessInfo.processInfo.processIdentifier {
                lastExternalPID = pid
            }
        } else if let lastExternalPID {
            app = AXUIElementCreateApplication(lastExternalPID)
        }

        return app
    }

    private func focusedWindow(in app: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }
        return (windowValue as! AXUIElement)
    }

    private func performCustomGeometryCommand(_ command: WindowCommand, in application: AXUIElement) -> Bool {
        guard let window = focusedWindow(in: application), let current = readFrame(of: window),
              let workArea = workAreaContaining(current.rect) else {
            diagnosticLog("WindowKeys: custom geometry fallback cannot read focused window or screen")
            return false
        }

        // Centering only changes the origin. Some apps (including iOA) expose
        // AXPosition as settable while intentionally making AXSize read-only.
        if command == .center {
            guard isSettable(kAXPositionAttribute as CFString, on: window) else {
                diagnosticLog("WindowKeys: center fallback unsupported (position is not settable)")
                return false
            }
            let origin = CGPoint(x: workArea.midX - current.size.width / 2,
                                 y: workArea.midY - current.size.height / 2)
            return center(window, from: current.origin, to: origin)
        }

        let target: CGRect
        switch command {
        case .center, .resize, .fullscreen:
            return false
        case .maximize:
            target = workArea.insetBy(dx: tiledWindowPadding, dy: tiledWindowPadding)
        case .leftHalf, .rightHalf:
            let padding = tiledWindowPadding
            let paneWidth = max(1, (workArea.width - padding * 3) / 2)
            let x = command == .leftHalf ? workArea.minX + padding : workArea.midX + padding / 2
            target = CGRect(x: x, y: workArea.minY + padding,
                            width: paneWidth, height: max(1, workArea.height - padding * 2))
        }

        guard isSettable(kAXSizeAttribute as CFString, on: window),
              isSettable(kAXPositionAttribute as CFString, on: window) else {
            diagnosticLog("WindowKeys: custom geometry fallback unsupported for command %u (position/size not settable)", command.rawValue)
            return false
        }
        guard setFrame(target, on: window) else { return false }
        diagnosticLog("WindowKeys: custom geometry fallback applied for command %u", command.rawValue)
        return true
    }

    private var tiledWindowPadding: CGFloat {
        let settings = UserDefaults(suiteName: "com.apple.WindowManager")
        let enabled = settings?.object(forKey: "EnableTiledWindowMargins") as? Bool ?? true
        return enabled ? CGFloat((settings?.object(forKey: "TiledWindowSpacing") as? NSNumber)?.doubleValue ?? 8) : 0
    }

    private func center(_ window: AXUIElement, from start: CGPoint, to target: CGPoint) -> Bool {
        guard abs(start.x - target.x) > 1 || abs(start.y - target.y) > 1 else { return true }
        guard animationEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return setPosition(target, on: window)
        }

        var lastRequested = start
        let animation = WindowGeometryAnimation(applyFrame: { [weak self] eased in
            guard let self else { return false }
            guard self.isFocused(window) else {
                self.activeAnimation = nil
                return false
            }
            let position = CGPoint(
                x: (start.x + (target.x - start.x) * eased).rounded(),
                y: (start.y + (target.y - start.y) * eased).rounded()
            )
            if position != lastRequested {
                guard self.writePosition(position, on: window) else { return false }
                lastRequested = position
            }
            return true
        }, completion: { [weak self] in
            self?.activeAnimation = nil
            _ = self?.verifyPosition(target, on: window)
        }, cleanup: {})
        activeAnimation = animation
        animation.start()
        return true
    }

    @discardableResult
    private func setPosition(_ position: CGPoint, on window: AXUIElement) -> Bool {
        guard writePosition(position, on: window) else { return false }
        return verifyPosition(position, on: window)
    }

    private func writePosition(_ position: CGPoint, on window: AXUIElement) -> Bool {
        var requested = position
        guard let value = AXValueCreate(.cgPoint, &requested) else { return false }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if result != .success {
            diagnosticLog("WindowKeys: setting window position failed with AX error %d", result.rawValue)
        }
        return result == .success
    }

    private func verifyPosition(_ position: CGPoint, on window: AXUIElement) -> Bool {
        guard let actual = readFrame(of: window) else {
            diagnosticLog("WindowKeys: center fallback could not verify resulting window position")
            return false
        }
        let matches = abs(actual.origin.x - position.x) <= 2 && abs(actual.origin.y - position.y) <= 2
        if matches {
            diagnosticLog("WindowKeys: center fallback applied using position only")
        } else {
            diagnosticLog("WindowKeys: center fallback position constrained (requested %.0f,%.0f; got %.0f,%.0f)",
                          position.x, position.y, actual.origin.x, actual.origin.y)
        }
        return matches
    }

    @discardableResult
    private func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        var size = frame.size
        var position = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else { return false }

        // Resize first, then place: some apps reposition windows when their size changes.
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard sizeResult == .success else {
            diagnosticLog("WindowKeys: fallback setting window size failed with AX error %d", sizeResult.rawValue)
            return false
        }
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard positionResult == .success else {
            diagnosticLog("WindowKeys: fallback setting window position failed with AX error %d", positionResult.rawValue)
            return false
        }
        guard let actual = readFrame(of: window) else {
            diagnosticLog("WindowKeys: fallback could not verify resulting window frame")
            return false
        }
        let matches = abs(actual.origin.x - frame.origin.x) <= 2 && abs(actual.origin.y - frame.origin.y) <= 2 &&
            abs(actual.size.width - frame.size.width) <= 2 && abs(actual.size.height - frame.size.height) <= 2
        if !matches {
            diagnosticLog("WindowKeys: fallback frame constrained by target app (requested %.0f,%.0f %.0fx%.0f; got %.0f,%.0f %.0fx%.0f)",
                          frame.origin.x, frame.origin.y, frame.width, frame.height,
                          actual.origin.x, actual.origin.y, actual.size.width, actual.size.height)
        }
        return matches
    }

    private func toggleFullscreen(in application: AXUIElement) {
        let attribute = "AXFullScreen" as CFString
        var value: CFTypeRef?
        guard let window = focusedWindow(in: application),
              isSettable(attribute, on: window),
              AXUIElementCopyAttributeValue(window, attribute, &value) == .success,
              let isFullscreen = value as? Bool else {
            diagnosticLog("WindowKeys: focused window does not support native fullscreen")
            NSSound.beep()
            return
        }
        // macOS owns the Space transition and animation; do not write window geometry.
        let result = AXUIElementSetAttributeValue(window, attribute, isFullscreen ? kCFBooleanFalse : kCFBooleanTrue)
        if result != .success {
            diagnosticLog("WindowKeys: fullscreen request failed with AX error %d", result.rawValue)
            NSSound.beep()
        }
    }

    private func performNativeWindowCommand(identifier: String, on application: AXUIElement) -> Bool {
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue else {
            diagnosticLog("WindowKeys: native command %@ has no accessible menu bar", identifier)
            return false
        }

        let menuBar = menuBarValue as! AXUIElement
        guard let item = findElement(identifier: identifier, under: menuBar, depth: 0) else {
            diagnosticLog("WindowKeys: native command %@ was not found", identifier)
            return false
        }

        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true else {
            diagnosticLog("WindowKeys: native command %@ is unavailable", identifier)
            return false
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result == .success {
            diagnosticLog("WindowKeys: performed native command %@", identifier)
            return true
        }

        diagnosticLog("WindowKeys: native command %@ failed with AX error %d", identifier, result.rawValue)
        return false
    }

    private func findElement(identifier: String, under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 8 else { return nil }

        var identifierValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXIdentifierAttribute as CFString,
            &identifierValue
        ) == .success,
        let currentIdentifier = identifierValue as? String,
        currentIdentifier == identifier {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children {
            if let match = findElement(identifier: identifier, under: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private func readFrame(of window: AXUIElement) -> WindowFrame? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return WindowFrame(origin: origin, size: size)
    }

    private func workAreaContaining(_ windowRect: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let screenRects = screens.map { screen -> CGRect in
            let visible = screen.visibleFrame
            let desktopTop = screens[0].frame.maxY
            return CGRect(
                x: visible.minX,
                y: desktopTop - visible.maxY,
                width: visible.width,
                height: visible.height
            )
        }

        return screenRects.max { lhs, rhs in
            intersectionArea(windowRect, lhs) < intersectionArea(windowRect, rhs)
        }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func isSettable(_ attribute: CFString, on window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, attribute, &settable) == .success && settable.boolValue
    }

    private func resize(
        _ window: AXUIElement,
        in application: AXUIElement,
        from start: CGSize,
        to target: CGSize
    ) {
        guard abs(start.width - target.width) > 1 || abs(start.height - target.height) > 1 else { return }

        var enhancedValue: CFTypeRef?
        let enhancedAttribute = "AXEnhancedUserInterface" as CFString
        AXUIElementCopyAttributeValue(application, enhancedAttribute, &enhancedValue)
        let enhancedUI = enhancedValue as? Bool == true
        // This compatibility flag must not override the user's animation preference.
        if enhancedUI {
            AXUIElementSetAttributeValue(application, enhancedAttribute, kCFBooleanFalse)
        }
        let restoreEnhancedUI: () -> Void = {
            if enhancedUI {
                AXUIElementSetAttributeValue(application, enhancedAttribute, kCFBooleanTrue)
                var restored: CFTypeRef?
                AXUIElementCopyAttributeValue(application, enhancedAttribute, &restored)
                if restored as? Bool != true {
                    diagnosticLog("WindowKeys: could not restore enhanced accessibility state")
                }
            }
        }
        guard animationEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            defer { restoreEnhancedUI() }
            setSize(target, on: window)
            return
        }

        var lastRequested = start
        let animation = WindowGeometryAnimation(applyFrame: { [weak self] eased in
            guard let self else { return false }
            guard self.isFocused(window) else {
                self.activeAnimation = nil
                return false
            }
            let size = CGSize(
                width: (start.width + (target.width - start.width) * eased).rounded(),
                height: (start.height + (target.height - start.height) * eased).rounded()
            )
            if size != lastRequested {
                self.setSize(size, on: window)
                lastRequested = size
            }
            return true
        }, completion: { [weak self] in
            self?.activeAnimation = nil
        }, cleanup: restoreEnhancedUI)
        activeAnimation = animation
        animation.start()
    }

    private func isFocused(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = focusedWindow(in: AXUIElementCreateApplication(pid)) else { return false }
        return CFEqual(focused, window)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
            if result != .success {
                diagnosticLog("WindowKeys: setting window size failed with AX error %d", result.rawValue)
            }
        }
    }

    private func showAccessibilityAlert() {
        _ = requestAccessibilityIfNeeded()
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 WindowKeys，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class ResizeSettingsWindowController: NSWindowController {
    private let widthSlider = NSSlider()
    private let heightSlider = NSSlider()
    private let widthValueLabel = NSTextField(labelWithString: "")
    private let heightValueLabel = NSTextField(labelWithString: "")
    var onValueChange: ((Int, Int) -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "C 键窗口大小"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        super.init(window: panel)
        configureContent()
        reloadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        reloadValues()
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let descriptionLabel = NSTextField(wrappingLabelWithString: "按 Control + Command + C 时，只按以下比例调整窗口大小；需要居中时，再按 Control + Command + ↓。")
        descriptionLabel.textColor = .secondaryLabelColor

        configure(widthSlider, action: #selector(sliderChanged(_:)))
        configure(heightSlider, action: #selector(sliderChanged(_:)))

        let widthRow = makeSliderRow(
            title: "宽度",
            slider: widthSlider,
            valueLabel: widthValueLabel
        )
        let heightRow = makeSliderRow(
            title: "高度",
            slider: heightSlider,
            valueLabel: heightValueLabel
        )

        let rangeLabel = NSTextField(labelWithString: "可调范围：30%–100%，设置会自动保存")
        rangeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rangeLabel.textColor = .tertiaryLabelColor

        let resetButton = NSButton(
            title: "恢复 75% × 75%",
            target: self,
            action: #selector(resetToDefault)
        )
        resetButton.bezelStyle = .rounded

        let footer = NSStackView(views: [rangeLabel, resetButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 12

        let stack = NSStackView(views: [descriptionLabel, widthRow, heightRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heightRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func configure(_ slider: NSSlider, action: Selector) {
        slider.minValue = ResizePreferences.minimumPercent
        slider.maxValue = ResizePreferences.maximumPercent
        slider.isContinuous = true
        slider.numberOfTickMarks = 15
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = action
    }

    private func makeSliderRow(
        title: String,
        slider: NSSlider,
        valueLabel: NSTextField
    ) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.alignment = .right
        titleLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func reloadValues() {
        widthSlider.doubleValue = ResizePreferences.widthPercent
        heightSlider.doubleValue = ResizePreferences.heightPercent
        updateLabelsAndSave()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        sender.doubleValue = sender.doubleValue.rounded()
        updateLabelsAndSave()
    }

    @objc private func resetToDefault() {
        widthSlider.doubleValue = ResizePreferences.defaultPercent
        heightSlider.doubleValue = ResizePreferences.defaultPercent
        updateLabelsAndSave()
    }

    private func updateLabelsAndSave() {
        let width = Int(widthSlider.doubleValue.rounded())
        let height = Int(heightSlider.doubleValue.rounded())
        widthValueLabel.stringValue = "\(width)%"
        heightValueLabel.stringValue = "\(height)%"
        ResizePreferences.set(widthPercent: Double(width), heightPercent: Double(height))
        onValueChange?(width, height)
    }
}

private struct AppInputRule {
    let bundleIdentifier: String
    let sourceIdentifier: String
}

private final class RuleInputSourcePopUpButton: NSPopUpButton {
    var appBundleIdentifier = ""
}

private final class InputMethodSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let defaultInputSourcePopUp = NSPopUpButton()
    private let tableView = NSTableView()
    private var inputSources: [InputSourceDescriptor] = []
    private var rules: [AppInputRule] = []
    var onConfigurationChange: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "应用输入法设置"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 420)
        panel.collectionBehavior = [.moveToActiveSpace]
        super.init(window: panel)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        _ = AccessibilityWindowController.shared.currentExternalApplication()
        reloadConfiguration()
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "在菜单栏勾选“自动切换输入法”后生效：优先使用应用专属配置，否则使用默认输入法。关闭开关会保留配置，但不自动切换。"
        )
        descriptionLabel.textColor = .secondaryLabelColor

        let defaultLabel = NSTextField(labelWithString: "默认输入法：")
        defaultLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        defaultInputSourcePopUp.target = self
        defaultInputSourcePopUp.action = #selector(defaultInputSourceChanged(_:))
        defaultInputSourcePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let defaultRow = NSStackView(views: [defaultLabel, defaultInputSourcePopUp, NSView()])
        defaultRow.orientation = .horizontal
        defaultRow.alignment = .centerY
        defaultRow.spacing = 8

        let rulesLabel = NSTextField(labelWithString: "应用专属配置")
        rulesLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        appColumn.title = "应用"
        appColumn.minWidth = 260
        appColumn.width = 330
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("inputSource"))
        sourceColumn.title = "输入法"
        sourceColumn.minWidth = 190
        sourceColumn.width = 260
        let removeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        removeColumn.title = ""
        removeColumn.minWidth = 54
        removeColumn.maxWidth = 54
        removeColumn.width = 54
        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(sourceColumn)
        tableView.addTableColumn(removeColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 52
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(
            title: "添加应用…",
            target: self,
            action: #selector(addApplication)
        )
        addButton.bezelStyle = .rounded

        let detectButton = NSButton(
            title: "添加当前应用",
            target: self,
            action: #selector(addCurrentApplication)
        )
        detectButton.bezelStyle = .rounded
        detectButton.toolTip = "添加最近使用的应用（不包括 WindowKeys），然后在列表中选择输入法。"

        let hintLabel = NSTextField(labelWithString: "删除专属配置后，该应用会自动使用默认输入法。")
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [detectButton, addButton, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [descriptionLabel, defaultRow, rulesLabel, scrollView, footer, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            defaultRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rulesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func reloadConfiguration() {
        inputSources = InputSourceCatalog.availableInputSources()
        rules = InputMethodPreferences.appOverrides
            .map { AppInputRule(bundleIdentifier: $0.key, sourceIdentifier: $0.value) }
            .sorted { applicationName(for: $0.bundleIdentifier).localizedCaseInsensitiveCompare(
                applicationName(for: $1.bundleIdentifier)
            ) == .orderedAscending }

        configure(defaultInputSourcePopUp, selectedIdentifier: InputMethodPreferences.defaultSourceIdentifier)
        defaultInputSourcePopUp.isEnabled = !inputSources.isEmpty
        tableView.reloadData()
    }

    private func configure(_ popUp: NSPopUpButton, selectedIdentifier: String?) {
        popUp.removeAllItems()
        for source in inputSources {
            popUp.addItem(withTitle: source.localizedName)
            popUp.lastItem?.representedObject = source.identifier
        }

        if let selectedIdentifier,
           !inputSources.contains(where: { $0.identifier == selectedIdentifier }) {
            popUp.addItem(withTitle: "不可用：\(selectedIdentifier)")
            popUp.lastItem?.representedObject = selectedIdentifier
        }

        if let selectedIdentifier,
           let selectedItem = popUp.itemArray.first(where: { $0.representedObject as? String == selectedIdentifier }) {
            popUp.select(selectedItem)
        } else if !popUp.itemArray.isEmpty {
            popUp.selectItem(at: 0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]

        switch tableColumn?.identifier.rawValue {
        case "application":
            return makeApplicationCell(bundleIdentifier: rule.bundleIdentifier)
        case "inputSource":
            let popUp = RuleInputSourcePopUpButton()
            popUp.appBundleIdentifier = rule.bundleIdentifier
            popUp.target = self
            popUp.action = #selector(ruleInputSourceChanged(_:))
            configure(popUp, selectedIdentifier: rule.sourceIdentifier)
            return popUp
        case "remove":
            let button = NSButton(
                title: "删除",
                target: self,
                action: #selector(removeRule(_:))
            )
            button.bezelStyle = .inline
            button.identifier = NSUserInterfaceItemIdentifier(rule.bundleIdentifier)
            return button
        default:
            return nil
        }
    }

    private func makeApplicationCell(bundleIdentifier: String) -> NSView {
        let cell = NSTableCellView()
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: applicationName(for: bundleIdentifier))
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        let identifierLabel = NSTextField(labelWithString: bundleIdentifier)
        identifierLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        identifierLabel.textColor = .secondaryLabelColor
        identifierLabel.lineBreakMode = .byTruncatingMiddle

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }

        let labels = NSStackView(views: [nameLabel, identifierLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)
        cell.addSubview(labels)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func applicationName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
    }

    @objc private func defaultInputSourceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        InputMethodPreferences.defaultSourceIdentifier = identifier
        onConfigurationChange?()
    }

    @objc private func ruleInputSourceChanged(_ sender: RuleInputSourcePopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        InputMethodPreferences.setOverride(identifier, for: sender.appBundleIdentifier)
        reloadConfiguration()
        onConfigurationChange?()
    }

    @objc private func addCurrentApplication() {
        guard let app = AccessibilityWindowController.shared.currentExternalApplication(),
              let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
            showError(message: "未能识别当前应用。请先切换到目标应用，再返回此窗口重试，或使用“添加应用…”手动选择。")
            return
        }
        addRule(for: bundleIdentifier)
    }

    @objc private func addApplication() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择需要配置输入法的应用"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
                self.showError(message: "无法读取所选应用的 Bundle ID。")
                return
            }
            self.addRule(for: bundleIdentifier)
        }
    }

    fileprivate func addRule(for bundleIdentifier: String) {
        guard bundleIdentifier != Bundle.main.bundleIdentifier else {
            showError(message: "WindowKeys 自身不会触发输入法切换，无需添加配置。")
            return
        }
        reloadConfiguration()
        // Re-adding an application must not replace its existing input source.
        if InputMethodPreferences.appOverrides[bundleIdentifier] == nil {
            let validDefaultIdentifier = InputMethodPreferences.defaultSourceIdentifier.flatMap { identifier in
                self.inputSources.contains(where: { $0.identifier == identifier }) ? identifier : nil
            }
            guard let sourceIdentifier = validDefaultIdentifier
                ?? InputSourceCatalog.currentInputSourceIdentifier()
                ?? self.inputSources.first?.identifier else {
                self.showError(message: "没有找到可用的输入法，请先在系统设置中启用输入法。")
                return
            }

            InputMethodPreferences.setOverride(sourceIdentifier, for: bundleIdentifier)
            self.reloadConfiguration()
            self.onConfigurationChange?()
        }
        if let row = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let bundleIdentifier = sender.identifier?.rawValue else { return }
        InputMethodPreferences.removeOverride(for: bundleIdentifier)
        reloadConfiguration()
        onConfigurationChange?()
    }

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "无法更新输入法配置"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private final class GlobalHotKeyManager {
    private static let signature: OSType = 0x574B4559 // WKEY
    private static let translationID: UInt32 = 100
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var pressed: Set<UInt32> = []
    private(set) var registrationFailures: [String] = []
    var onCommand: ((WindowCommand) -> Void)?
    var onTranslate: (() -> Void)?

    init() {
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = events.withUnsafeBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<GlobalHotKeyManager>.fromOpaque(context).takeUnretainedValue().handle(event)
            }, buffer.count, buffer.baseAddress,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        guard status == noErr else {
            registrationFailures.append("无法安装全局快捷键处理器（错误码 \(status)）")
            return
        }
        for command in WindowCommand.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: command.rawValue)
            let result = RegisterEventHotKey(command.keyCode, command.carbonModifiers, identifier,
                                             GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference {
                registrations[command.rawValue] = reference
            } else {
                registrationFailures.append("\(command.title)（错误码 \(result)）")
                diagnosticLog("WindowKeys: failed to register hotkey %@: %d", command.title, result)
            }
        }
        var translationRef: EventHotKeyRef?
        let translationIdentifier = EventHotKeyID(signature: Self.signature, id: Self.translationID)
        let translationStatus = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(optionKey),
            translationIdentifier, GetApplicationEventTarget(), 0, &translationRef)
        if translationStatus == noErr, let translationRef {
            registrations[Self.translationID] = translationRef
        } else {
            registrationFailures.append("选词翻译 Option-D（错误码 \(translationStatus)）")
        }
    }

    deinit {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == Self.signature,
              registrations[identifier.id] != nil else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            pressed.remove(identifier.id)
            return noErr
        }
        guard GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        guard pressed.insert(identifier.id).inserted else { return noErr }

        if identifier.id == Self.translationID {
            DispatchQueue.main.async { [weak self] in self?.onTranslate?() }
            return noErr
        }
        guard let command = WindowCommand(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }

        UserDefaults.standard.set(Int(command.rawValue), forKey: "LastHotKeyCommand")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastHotKeyTimestamp")
        diagnosticLog("WindowKeys: received hotkey for command %u", command.rawValue)

        DispatchQueue.main.async { [weak self] in
            self?.onCommand?(command)
        }
        return noErr
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var hotKeys: GlobalHotKeyManager?
    private var inputMethodManager: InputMethodManager?
    private var statusItem: NSStatusItem!
    private var sizeSettingsItem: NSMenuItem!
    private var animationItem: NSMenuItem!
    private var inputMethodEnabledItem: NSMenuItem!
    private var diagnosticLoggingItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var resizeSettingsWindowController: ResizeSettingsWindowController?
    private var inputMethodSettingsWindowController: InputMethodSettingsWindowController?
    private var translationWindowController: TranslationWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnosticLog("WindowKeys: launching; macOS %@; input switching enabled=%d",
                      ProcessInfo.processInfo.operatingSystemVersionString, InputMethodPreferences.isEnabled ? 1 : 0)
        ResizePreferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        createStatusMenu()

        // Register only after NSApplication has a live application event target.
        let hotKeyManager = GlobalHotKeyManager()
        hotKeyManager.onCommand = { command in
            AccessibilityWindowController.shared.perform(command)
        }
        hotKeyManager.onTranslate = { [weak self] in self?.showTranslation() }
        hotKeys = hotKeyManager

        updateInputMethodManager()

        UserDefaults.standard.set(AXIsProcessTrusted(), forKey: "AccessibilityTrustedAtLaunch")

        _ = AccessibilityWindowController.shared.requestAccessibilityIfNeeded()
        if !hotKeyManager.registrationFailures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "部分窗口快捷键注册失败"
            alert.informativeText = hotKeyManager.registrationFailures.joined(separator: "\n") +
                "\n请检查系统或其他工具是否已占用这些组合键，解除占用后重新启动 WindowKeys。失败的组合键未被 WindowKeys 接管，不会退回按键监听模式。"
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func createStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.inset.filled.and.person.filled",
            accessibilityDescription: "WindowKeys"
        )
        statusItem.button?.toolTip = "WindowKeys"

        let menu = NSMenu()
        menu.delegate = self
        for command in WindowCommand.allCases {
            let item = NSMenuItem(
                title: command.title,
                action: #selector(runMenuCommand(_:)),
                keyEquivalent: command.keyEquivalent
            )
            item.target = self
            item.tag = Int(command.rawValue)
            item.keyEquivalentModifierMask = command.modifiers
            menu.addItem(item)
        }

        menu.addItem(.separator())
        sizeSettingsItem = NSMenuItem(
            title: sizeSettingsTitle(),
            action: #selector(showResizeSettings),
            keyEquivalent: ""
        )
        sizeSettingsItem.target = self
        menu.addItem(sizeSettingsItem)

        animationItem = NSMenuItem(
            title: "窗口调整动画",
            action: #selector(toggleAnimation(_:)),
            keyEquivalent: ""
        )
        animationItem.target = self
        animationItem.state = AccessibilityWindowController.shared.animationEnabled ? .on : .off
        menu.addItem(animationItem)

        inputMethodEnabledItem = NSMenuItem(
            title: "自动切换输入法",
            action: #selector(toggleInputMethodSwitching),
            keyEquivalent: ""
        )
        inputMethodEnabledItem.target = self
        inputMethodEnabledItem.state = InputMethodPreferences.isEnabled ? .on : .off
        menu.addItem(inputMethodEnabledItem)

        let inputMethodSettingsItem = NSMenuItem(
            title: "应用输入法设置…",
            action: #selector(showInputMethodSettings),
            keyEquivalent: ""
        )
        inputMethodSettingsItem.target = self
        menu.addItem(inputMethodSettingsItem)

        let translationItem = NSMenuItem(title: "选词翻译…", action: #selector(showTranslation), keyEquivalent: "d")
        translationItem.keyEquivalentModifierMask = [.option]
        translationItem.target = self
        menu.addItem(translationItem)

        menu.addItem(.separator())
        diagnosticLoggingItem = NSMenuItem(title: "保存诊断日志", action: #selector(toggleDiagnosticLogging), keyEquivalent: "")
        diagnosticLoggingItem.target = self
        diagnosticLoggingItem.state = DiagnosticLog.isEnabled ? .on : .off
        menu.addItem(diagnosticLoggingItem)
        let exportItem = NSMenuItem(title: "导出诊断日志…", action: #selector(exportDiagnosticLog), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        menu.addItem(.separator())
        launchAtLoginItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        updateLaunchAtLoginItem()

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 WindowKeys", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginItem()
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let command = WindowCommand(rawValue: UInt32(sender.tag)) else { return }
        AccessibilityWindowController.shared.perform(command)
    }

    @objc private func showTranslation() {
        let app = AccessibilityWindowController.shared.currentExternalApplication()
        if translationWindowController == nil {
            translationWindowController = TranslationWindowController()
        }
        translationWindowController?.showSelection(from: app)
    }

    @objc private func showResizeSettings() {
        let controller: ResizeSettingsWindowController
        if let resizeSettingsWindowController {
            controller = resizeSettingsWindowController
        } else {
            controller = ResizeSettingsWindowController()
            controller.onValueChange = { [weak self] _, _ in
                self?.sizeSettingsItem.title = self?.sizeSettingsTitle() ?? "C 窗口大小…"
            }
            resizeSettingsWindowController = controller
        }
        controller.showWindow(nil)
    }

    private func sizeSettingsTitle() -> String {
        let width = Int(ResizePreferences.widthPercent.rounded())
        let height = Int(ResizePreferences.heightPercent.rounded())
        return "C 窗口大小：\(width)% × \(height)%…"
    }

    @objc private func toggleAnimation(_ sender: NSMenuItem) {
        let controller = AccessibilityWindowController.shared
        controller.animationEnabled.toggle()
        sender.state = controller.animationEnabled ? .on : .off
    }

    @objc private func showInputMethodSettings() {
        let controller: InputMethodSettingsWindowController
        if let inputMethodSettingsWindowController {
            controller = inputMethodSettingsWindowController
        } else {
            controller = InputMethodSettingsWindowController()
            controller.onConfigurationChange = { [weak self] in
                self?.inputMethodManager?.applyToFrontmostApplication()
            }
            inputMethodSettingsWindowController = controller
        }
        controller.showWindow(nil)
    }

    @objc private func toggleInputMethodSwitching() {
        InputMethodPreferences.isEnabled.toggle()
        inputMethodEnabledItem.state = InputMethodPreferences.isEnabled ? .on : .off
        updateInputMethodManager()
    }

    private func updateInputMethodManager() {
        diagnosticLog("WindowKeys: input switching enabled=%d", InputMethodPreferences.isEnabled ? 1 : 0)
        // Do not query input sources or observe app activation while disabled.
        inputMethodManager = nil
        guard InputMethodPreferences.isEnabled else { return }
        let manager = InputMethodManager()
        inputMethodManager = manager
        manager.applyToFrontmostApplication()
    }

    @objc private func toggleDiagnosticLogging() {
        if DiagnosticLog.isEnabled {
            diagnosticLog("WindowKeys: diagnostic logging disabled")
            DiagnosticLog.isEnabled = false
        } else {
            DiagnosticLog.isEnabled = true
            diagnosticLog("WindowKeys: diagnostic logging enabled; input switching=%d; accessibility=%d",
                          InputMethodPreferences.isEnabled ? 1 : 0, AXIsProcessTrusted() ? 1 : 0)
        }
        diagnosticLoggingItem.state = DiagnosticLog.isEnabled ? .on : .off
    }

    @objc private func exportDiagnosticLog() {
        let panel = NSSavePanel()
        panel.title = "导出诊断日志"
        panel.message = "仅保存本地文件，不会上传。可能包含应用和输入法标识，不包含输入内容或窗口标题。未开启日志时，文件只包含基本状态和已有记录。"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "WindowKeys-diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticLog.shared.export(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法导出诊断日志"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp

        if service.status == .requiresApproval {
            showLaunchAtLoginApprovalAlert()
            return
        }

        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            updateLaunchAtLoginItem()

            if service.status == .requiresApproval {
                showLaunchAtLoginApprovalAlert()
            }
        } catch {
            updateLaunchAtLoginItem()
            showLaunchAtLoginError(error)
        }
    }

    private func updateLaunchAtLoginItem() {
        guard launchAtLoginItem != nil else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.title = "开机自动启动"
            launchAtLoginItem.state = .on
        case .requiresApproval:
            launchAtLoginItem.title = "开机自动启动（需要系统批准）"
            launchAtLoginItem.state = .mixed
        case .notRegistered, .notFound:
            launchAtLoginItem.title = "开机自动启动"
            launchAtLoginItem.state = .off
        @unknown default:
            launchAtLoginItem.title = "开机自动启动"
            launchAtLoginItem.state = .off
        }
    }

    private func showLaunchAtLoginApprovalAlert() {
        let alert = NSAlert()
        alert.messageText = "需要批准开机自动启动"
        alert.informativeText = "请在“系统设置 → 通用 → 登录项与扩展”中允许 WindowKeys 在登录时打开。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法修改开机自动启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticLog("WindowKeys: normal termination")
        AccessibilityWindowController.shared.cancelWindowAnimation()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
