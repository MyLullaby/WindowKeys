// Live integration check: uses the production window controller and restores the tested window.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func frame(_ window: AXUIElement) -> CGRect {
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(attribute(window, "AXPosition") as! AXValue, .cgPoint, &position)
    AXValueGetValue(attribute(window, "AXSize") as! AXValue, .cgSize, &size)
    return CGRect(origin: position, size: size)
}

func wait(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func runChecks() -> Int32 {
    guard CommandLine.arguments.count == 3, AXIsProcessTrusted() else {
        print("Usage: run-window-commands.sh <bundle-id> <window-title>; Accessibility permission required")
        return 2
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    ResizePreferences.registerDefaults()
    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
    var selected: (NSRunningApplication, AXUIElement)?
    for candidate in candidates {
        let windows = attribute(AXUIElementCreateApplication(candidate.processIdentifier), "AXWindows") as? [AXUIElement] ?? []
        if let window = windows.first(where: { attribute($0, "AXTitle") as? String == CommandLine.arguments[2] }) {
            selected = (candidate, window)
            break
        }
    }
    guard let (targetApp, window) = selected else { print("Window not found"); return 2 }
    let previousApp = NSWorkspace.shared.frontmostApplication
    let originalSize = attribute(window, "AXSize")!
    let originalPosition = attribute(window, "AXPosition")!
    let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
    let enhancedBefore = attribute(appElement, "AXEnhancedUserInterface") as? Bool
    defer {
        AXUIElementSetAttributeValue(window, "AXSize" as CFString, originalSize)
        wait(0.3)
        AXUIElementSetAttributeValue(window, "AXPosition" as CFString, originalPosition)
        wait(0.3)
        _ = previousApp?.activate()
    }
    _ = targetApp.activate()
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    wait(0.5)
    let screens = NSScreen.screens
    let current = frame(window)
    let areas = screens.map { screen -> CGRect in
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: screens[0].frame.maxY - visible.maxY, width: visible.width, height: visible.height)
    }
    guard let area = areas.max(by: {
        let left = $0.intersection(current), right = $1.intersection(current)
        return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
    }) else { return 2 }
    let controller = AccessibilityWindowController.shared
    func perform(_ command: WindowCommand) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier,
              let focused = attribute(appElement, "AXFocusedWindow"), CFEqual(focused, window) else {
            print("INTERRUPTED: foreground window changed; no command sent")
            return false
        }
        controller.perform(command)
        return true
    }
    var failures: Int32 = 0
    func check(_ name: String, _ expected: CGRect, tolerance: CGFloat = 2) {
        let actual = frame(window)
        let ok = abs(actual.minX - expected.minX) <= tolerance && abs(actual.minY - expected.minY) <= tolerance &&
            abs(actual.width - expected.width) <= tolerance && abs(actual.height - expected.height) <= tolerance
        print("\(ok ? "PASS" : "FAIL") \(name): actual=\(actual) expected=\(expected)")
        if !ok { failures += 1 }
    }
    // Start below full size; separate setup writes so system tiling restoration has time to finish.
    var setupSize = CGSize(width: area.width * 0.7, height: area.height * 0.7)
    var setupPosition = CGPoint(x: area.minX + 40, y: area.minY + 60)
    AXUIElementSetAttributeValue(window, "AXSize" as CFString, AXValueCreate(.cgSize, &setupSize)!)
    wait(0.3)
    AXUIElementSetAttributeValue(window, "AXPosition" as CFString, AXValueCreate(.cgPoint, &setupPosition)!)
    wait(0.3)
    guard perform(.maximize) else { return 3 }
    wait(1)
    check("maximize", area.insetBy(dx: 8, dy: 8), tolerance: 16)
    guard perform(.resizeAndCenter) else { return 3 }
    wait(1)
    let size = CGSize(width: area.width * ResizePreferences.widthPercent / 100, height: area.height * ResizePreferences.heightPercent / 100)
    let centered = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    check("resize after native tiling", centered)
    AXUIElementSetAttributeValue(window, "AXPosition" as CFString, AXValueCreate(.cgPoint, &setupPosition)!)
    wait(0.3)
    let beforeCenter = frame(window)
    let expectedCenter = CGRect(x: area.midX - beforeCenter.width / 2, y: area.midY - beforeCenter.height / 2,
                                width: beforeCenter.width, height: beforeCenter.height)
    guard perform(.center) else { return 3 }
    wait(1)
    check("center with one command", expectedCenter)
    AXUIElementSetAttributeValue(window, "AXPosition" as CFString, AXValueCreate(.cgPoint, &setupPosition)!)
    wait(0.3)
    guard perform(.center) else { return 3 }
    wait(0.04)
    guard perform(.maximize) else { return 3 }
    wait(1)
    check("maximize interrupts old animation", area.insetBy(dx: 8, dy: 8), tolerance: 16)
    let enhancedAfter = attribute(appElement, "AXEnhancedUserInterface") as? Bool
    if enhancedBefore != enhancedAfter { print("FAIL enhanced accessibility state changed"); failures += 1 }
    return failures == 0 ? 0 : 1
}

exit(runChecks())
