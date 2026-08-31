import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

private enum WindowCommand: UInt32, CaseIterable {
    case resizeAndCenter = 1
    case center
    case maximize
    case leftHalf
    case rightHalf

    var title: String {
        switch self {
        case .center: return "居中"
        case .resizeAndCenter: return "调整大小并居中"
        case .maximize: return "最大化"
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .resizeAndCenter: return UInt32(kVK_ANSI_C)
        case .center: return UInt32(kVK_DownArrow)
        case .maximize: return UInt32(kVK_UpArrow)
        case .leftHalf: return UInt32(kVK_LeftArrow)
        case .rightHalf: return UInt32(kVK_RightArrow)
        }
    }

    var keyEquivalent: String {
        switch self {
        case .resizeAndCenter: return "c"
        case .center: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .maximize: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .leftHalf: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightHalf: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        }
    }

    var nativeMenuIdentifier: String? {
        switch self {
        case .resizeAndCenter, .center: return nil
        case .maximize: return "_zoomFill:"
        case .leftHalf: return "_zoomLeft:"
        case .rightHalf: return "_zoomRight:"
        }
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

private enum InputMethodPreferences {
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
        appOverrides[bundleIdentifier] ?? defaultSourceIdentifier
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
        let sources = TISCreateInputSourceList(properties, false).takeRetainedValue() as NSArray
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
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return property(source, key: kTISPropertyInputSourceID)
    }

    @discardableResult
    static func selectInputSource(identifier: String) -> Bool {
        let properties = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false).takeRetainedValue() as NSArray
        guard let source = sources.firstObject as! TISInputSource? else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func property<T>(_ source: TISInputSource, key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

private final class InputMethodManager {
    private var activationObserver: NSObjectProtocol?

    init() {
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
            self?.applyInputSource(for: app)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func applyToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        applyInputSource(for: app)
    }

    private func applyInputSource(for app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = app.bundleIdentifier,
              let targetIdentifier = InputMethodPreferences.sourceIdentifier(for: bundleIdentifier),
              InputSourceCatalog.currentInputSourceIdentifier() != targetIdentifier else { return }

        if InputSourceCatalog.selectInputSource(identifier: targetIdentifier) {
            NSLog("WindowKeys: selected input source %@ for %@", targetIdentifier, bundleIdentifier)
        } else {
            NSLog("WindowKeys: input source %@ for %@ is unavailable", targetIdentifier, bundleIdentifier)
        }
    }
}

private struct WindowFrame {
    var origin: CGPoint
    var size: CGSize

    var rect: CGRect { CGRect(origin: origin, size: size) }
}

private final class AccessibilityWindowController {
    static let shared = AccessibilityWindowController()

    private var animationTimer: Timer?
    private var lastExternalPID: pid_t?
    private let animationDuration: TimeInterval = 0.16

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

    func requestAccessibilityIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func perform(_ command: WindowCommand) {
        guard AXIsProcessTrusted() else {
            showAccessibilityAlert()
            return
        }

        guard let application = focusedExternalApplication() else {
            NSSound.beep()
            return
        }

        if let identifier = command.nativeMenuIdentifier,
           performNativeWindowCommand(identifier: identifier, on: application) {
            return
        }

        guard let window = focusedWindow(in: application), let current = readFrame(of: window) else {
            NSSound.beep()
            return
        }

        guard let workArea = workAreaContaining(current.rect) else {
            NSSound.beep()
            return
        }

        let target: WindowFrame
        let changesSize: Bool

        switch command {
        case .center:
            // Intentionally preserve the exact current size and only write AXPosition.
            // This avoids the redundant AXSize write that triggered the Loop diagnosis.
            target = WindowFrame(
                origin: CGPoint(
                    x: workArea.midX - current.size.width / 2,
                    y: workArea.midY - current.size.height / 2
                ),
                size: current.size
            )
            changesSize = false

        case .resizeAndCenter:
            let widthRatio = CGFloat(ResizePreferences.widthPercent / 100)
            let heightRatio = CGFloat(ResizePreferences.heightPercent / 100)
            let size = CGSize(
                width: workArea.width * widthRatio,
                height: workArea.height * heightRatio
            )
            target = WindowFrame(
                origin: CGPoint(x: workArea.midX - size.width / 2, y: workArea.midY - size.height / 2),
                size: size
            )
            changesSize = true

        case .maximize:
            let area = fallbackTiledArea(workArea)
            target = WindowFrame(origin: area.origin, size: area.size)
            changesSize = true

        case .leftHalf:
            let gap: CGFloat = 8
            target = WindowFrame(
                origin: CGPoint(x: workArea.minX + gap, y: workArea.minY + gap),
                size: CGSize(
                    width: floor(workArea.width / 2) - gap * 1.5,
                    height: workArea.height - gap * 2
                )
            )
            changesSize = true

        case .rightHalf:
            let gap: CGFloat = 8
            let halfWidth = floor(workArea.width / 2)
            target = WindowFrame(
                origin: CGPoint(x: workArea.minX + halfWidth + gap / 2, y: workArea.minY + gap),
                size: CGSize(
                    width: workArea.width - halfWidth - gap * 1.5,
                    height: workArea.height - gap * 2
                )
            )
            changesSize = true
        }

        guard !changesSize || isSettable(kAXSizeAttribute as CFString, on: window) else {
            NSSound.beep()
            return
        }
        guard isSettable(kAXPositionAttribute as CFString, on: window) else {
            NSSound.beep()
            return
        }

        move(window, from: current, to: target, changesSize: changesSize)
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

    private func performNativeWindowCommand(identifier: String, on application: AXUIElement) -> Bool {
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue else {
            NSLog("WindowKeys: native command %@ has no accessible menu bar; using fallback", identifier)
            return false
        }

        let menuBar = menuBarValue as! AXUIElement
        var item = findElement(identifier: identifier, under: menuBar, depth: 0)
        if item == nil {
            revealNativeWindowMenus(under: menuBar)
            item = findElement(identifier: identifier, under: menuBar, depth: 0)
        }

        guard let item else {
            NSLog("WindowKeys: native command %@ was not found; using fallback", identifier)
            return false
        }

        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result == .success {
            NSLog("WindowKeys: performed native command %@", identifier)
            return true
        }

        NSLog("WindowKeys: native command %@ failed with AX error %d; using fallback", identifier, result.rawValue)
        return false
    }

    private func revealNativeWindowMenus(under menuBar: AXUIElement) {
        guard let windowMenu = findElement(
            titles: ["窗口", "Window"],
            under: menuBar,
            depth: 0
        ) else { return }

        AXUIElementPerformAction(windowMenu, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.04)

        if let moveAndResize = findElement(
            titles: ["移动与调整大小", "Move & Resize"],
            under: windowMenu,
            depth: 0
        ) {
            AXUIElementPerformAction(moveAndResize, kAXShowMenuAction as CFString)
            Thread.sleep(forTimeInterval: 0.04)
        }
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

    private func findElement(titles: Set<String>, under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 8 else { return nil }

        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success,
        let title = titleValue as? String,
        titles.contains(title) {
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
            if let match = findElement(titles: titles, under: child, depth: depth + 1) {
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

    private func fallbackTiledArea(_ workArea: CGRect) -> CGRect {
        workArea.insetBy(dx: 8, dy: 8)
    }

    private func isSettable(_ attribute: CFString, on window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, attribute, &settable) == .success && settable.boolValue
    }

    private func move(
        _ window: AXUIElement,
        from start: WindowFrame,
        to target: WindowFrame,
        changesSize: Bool
    ) {
        animationTimer?.invalidate()

        guard animationEnabled else {
            apply(target, to: window, changesSize: changesSize)
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(1, elapsed / self.animationDuration)
            let eased = 1 - pow(1 - progress, 3)
            let frame = WindowFrame(
                origin: CGPoint(
                    x: start.origin.x + (target.origin.x - start.origin.x) * eased,
                    y: start.origin.y + (target.origin.y - start.origin.y) * eased
                ),
                size: CGSize(
                    width: start.size.width + (target.size.width - start.size.width) * eased,
                    height: start.size.height + (target.size.height - start.size.height) * eased
                )
            )
            self.apply(frame, to: window, changesSize: changesSize)

            if progress >= 1 {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
    }

    private func apply(_ frame: WindowFrame, to window: AXUIElement, changesSize: Bool) {
        if changesSize {
            var size = frame.size
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            }
        }

        var origin = frame.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
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

        let descriptionLabel = NSTextField(wrappingLabelWithString: "按 Control + Command + C 时，窗口会按当前屏幕可用区域的以下比例调整，并自动居中。")
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
        reloadConfiguration()
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "切换应用时，WindowKeys 会优先使用应用的专属配置；没有专属配置时使用默认输入法。"
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

        let hintLabel = NSTextField(labelWithString: "删除专属配置后，该应用会自动使用默认输入法。")
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [addButton, hintLabel, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [descriptionLabel, defaultRow, rulesLabel, scrollView, footer])
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
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
            guard bundleIdentifier != Bundle.main.bundleIdentifier else {
                self.showError(message: "WindowKeys 自身不会触发输入法切换，无需添加配置。")
                return
            }
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
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var onCommand: ((WindowCommand) -> Void)?

    init() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }

        UserDefaults.standard.set(globalMonitor != nil, forKey: "GlobalKeyMonitorInstalled")
        NSLog("WindowKeys: global key monitor installed=%@", globalMonitor == nil ? "false" : "true")
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) {
        guard !event.isARepeat else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control),
              flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.shift) else { return }

        guard let command = WindowCommand.allCases.first(where: {
            UInt16($0.keyCode) == event.keyCode
        }) else { return }

        UserDefaults.standard.set(Int(command.rawValue), forKey: "LastHotKeyCommand")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastHotKeyTimestamp")
        NSLog("WindowKeys: received hotkey for command %u", command.rawValue)

        DispatchQueue.main.async { [weak self] in
            self?.onCommand?(command)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var hotKeys: GlobalHotKeyManager?
    private var inputMethodManager: InputMethodManager?
    private var statusItem: NSStatusItem!
    private var sizeSettingsItem: NSMenuItem!
    private var animationItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var resizeSettingsWindowController: ResizeSettingsWindowController?
    private var inputMethodSettingsWindowController: InputMethodSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ResizePreferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        createStatusMenu()

        // Register only after NSApplication has a live application event target.
        let hotKeyManager = GlobalHotKeyManager()
        hotKeyManager.onCommand = { command in
            AccessibilityWindowController.shared.perform(command)
        }
        hotKeys = hotKeyManager

        let inputManager = InputMethodManager()
        inputMethodManager = inputManager
        inputManager.applyToFrontmostApplication()

        UserDefaults.standard.set(AXIsProcessTrusted(), forKey: "AccessibilityTrustedAtLaunch")

        _ = AccessibilityWindowController.shared.requestAccessibilityIfNeeded()
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
            item.keyEquivalentModifierMask = [.control, .command]
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
            title: "自定义窗口动画",
            action: #selector(toggleAnimation(_:)),
            keyEquivalent: ""
        )
        animationItem.target = self
        animationItem.state = AccessibilityWindowController.shared.animationEnabled ? .on : .off
        menu.addItem(animationItem)

        let inputMethodSettingsItem = NSMenuItem(
            title: "应用输入法设置…",
            action: #selector(showInputMethodSettings),
            keyEquivalent: ""
        )
        inputMethodSettingsItem.target = self
        menu.addItem(inputMethodSettingsItem)

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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
