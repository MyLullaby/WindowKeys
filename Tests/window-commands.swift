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
    assert(WindowCommand.resizeAndCenter.nativeMenuIdentifier == nil)
    assert(WindowCommand.center.nativeMenuIdentifier == "_zoomCenter:")
    assert(WindowCommand.maximize.nativeMenuIdentifier == "_zoomFill:")
    assert(WindowCommand.leftHalf.nativeMenuIdentifier == "_zoomLeft:")
    assert(WindowCommand.rightHalf.nativeMenuIdentifier == "_zoomRight:")
    let bounds = CGRect(x: -1440, y: 40, width: 1440, height: 900)
    let requested = WindowFrame(origin: CGPoint(x: -1020, y: 240), size: CGSize(width: 600, height: 400))
    let constrained = requested.usingActualSize(CGSize(width: 800, height: 500), within: bounds)
    assert(constrained.origin == CGPoint(x: -1120, y: 190))
    let oversized = requested.usingActualSize(CGSize(width: 1800, height: 1100), within: bounds)
    assert(oversized.origin == bounds.origin)
    print("PASS native command mapping and actual-size anchoring")
    if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--geometry-only" { return 0 }

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
    let originalAnimationEnabled = controller.animationEnabled
    controller.animationEnabled = true
    defer { controller.animationEnabled = originalAnimationEnabled }
    let windowManager = UserDefaults(suiteName: "com.apple.WindowManager")
    let paddingEnabled = windowManager?.object(forKey: "EnableTiledWindowMargins") as? Bool ?? true
    let padding = paddingEnabled ? CGFloat((windowManager?.object(forKey: "TiledWindowSpacing") as? NSNumber)?.doubleValue ?? 8) : 0
    let filled = area.insetBy(dx: padding, dy: padding)
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
    let size = CGSize(width: area.width * ResizePreferences.widthPercent / 100, height: area.height * ResizePreferences.heightPercent / 100)
    let centered = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    let beforeResize = frame(window)
    guard perform(.resizeAndCenter) else { return 3 }
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        // No timer tick yet: catches accidental removal of the resize animation.
        check("animated resize starts at the original frame", beforeResize)
        wait(0.08)
        let intermediate = frame(window)
        let moved = abs(intermediate.minX - beforeResize.minX) > 2 || abs(intermediate.minY - beforeResize.minY) > 2 ||
            abs(intermediate.width - beforeResize.width) > 2 || abs(intermediate.height - beforeResize.height) > 2
        let finished = abs(intermediate.minX - centered.minX) <= 2 && abs(intermediate.minY - centered.minY) <= 2 &&
            abs(intermediate.width - centered.width) <= 2 && abs(intermediate.height - centered.height) <= 2
        if moved && !finished {
            print("PASS resize has an intermediate animation frame")
        } else {
            print("FAIL resize did not expose an intermediate animation frame: \(intermediate)")
            failures += 1
        }
    }
    wait(1)
    check("animated resize finishes centered", centered)
    guard perform(.maximize) else { return 3 }
    wait(1)
    check("native maximize", filled, tolerance: 16)
    guard perform(.resizeAndCenter) else { return 3 }
    wait(1)
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
    guard perform(.resizeAndCenter) else { return 3 }
    wait(0.04)
    guard perform(.maximize) else { return 3 }
    wait(1)
    check("native maximize cancels custom resize animation", filled, tolerance: 16)
    let enhancedAfter = attribute(appElement, "AXEnhancedUserInterface") as? Bool
    if enhancedBefore != enhancedAfter { print("FAIL enhanced accessibility state changed"); failures += 1 }
    return failures == 0 ? 0 : 1
}

exit(runChecks())
