import AppKit
import ApplicationServices

struct RememberedWindowLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var screenID: UInt32
    var screenX: Double
    var screenY: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func fitted(to area: CGRect, sameScreen: Bool) -> CGRect {
        let w = min(max(width, 100), area.width)
        let h = min(max(height, 100), area.height)
        let px = sameScreen ? x : area.minX + x - screenX
        let py = sameScreen ? y : area.minY + y - screenY
        return CGRect(x: min(max(px, area.minX), area.maxX - w),
                      y: min(max(py, area.minY), area.maxY - h), width: w, height: h)
    }
}

final class WindowLayoutMemory {
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowLayoutMemoryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowLayoutMemoryEnabled") }
    }
    private final class TrackedWindow {
        let element: AXUIElement
        var restoreTask: DispatchWorkItem?
        var restoring = false
        var animation: WindowGeometryAnimation?
        var appliedRestore = false
        init(_ element: AXUIElement) { self.element = element }
    }
    private final class TrackedApp {
        let bundleID: String
        let observer: AXObserver
        let element: AXUIElement
        var windows: [TrackedWindow] = []
        init(_ bundleID: String, _ observer: AXObserver, _ element: AXUIElement) {
            self.bundleID = bundleID; self.observer = observer; self.element = element
        }
    }
    private var apps: [pid_t: TrackedApp] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var layouts: [String: RememberedWindowLayout]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layouts = defaults.data(forKey: "rememberedWindowLayouts")
            .flatMap { try? JSONDecoder().decode([String: RememberedWindowLayout].self, from: $0) } ?? [:]
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.attach(app, restoreExisting: true)
            })
        }
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(app.processIdentifier)
        })
        seedRunningApps()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.seedRunningApps()
        }
    }

    private func seedRunningApps() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where apps[app.processIdentifier] == nil {
            attach(app, restoreExisting: false)
        }
    }

    func stop() {
        permissionTimer?.invalidate(); permissionTimer = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
        for pid in Array(apps.keys) { detach(pid) }
    }

    private func detach(_ pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        for window in app.windows {
            window.restoreTask?.cancel(); window.animation?.cancel(); window.animation = nil
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(app.observer), .commonModes)
    }

    private func attach(_ running: NSRunningApplication, restoreExisting: Bool) {
        guard AXIsProcessTrusted(), running.activationPolicy == .regular,
              running.processIdentifier != getpid(), let bundleID = running.bundleIdentifier else { return }
        let pid = running.processIdentifier
        if let app = apps[pid] {
            discover(app, restore: true)
            return
        }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            Unmanaged<WindowLayoutMemory>.fromOpaque(context).takeUnretainedValue()
                .received(element, notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let app = TrackedApp(bundleID, observer, element)
        apps[pid] = app
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        discover(app, restore: restoreExisting)
    }

    private func discover(_ app: TrackedApp, restore: Bool) {
        let windows = attribute(app.element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows { track(window, app: app, restore: restore) }
        // JetBrains Client can expose a focused window but an empty AXWindows list.
        if let value = attribute(app.element, kAXFocusedWindowAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            track(value as! AXUIElement, app: app, restore: restore)
        }
    }

    private func track(_ element: AXUIElement, app: TrackedApp, restore: Bool) {
        guard attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              !app.windows.contains(where: { CFEqual($0.element, element) }) else { return }
        let window = TrackedWindow(element)
        app.windows.append(window)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(app.observer, element, name as CFString, context)
        }
        if restore, let layout = layouts[app.bundleID] {
            window.restoring = true
            restoreWindow(window, app: app, layout: layout, attempt: 0)
        }
    }

    private func received(_ element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let app = apps[pid] else { return }
        if notification == kAXWindowCreatedNotification {
            track(element, app: app, restore: true)
            discover(app, restore: true)
        } else if notification == kAXFocusedWindowChangedNotification {
            discover(app, restore: true)
        } else if let window = app.windows.first(where: { CFEqual($0.element, element) }) {
            if notification == kAXUIElementDestroyedNotification {
                window.restoreTask?.cancel(); window.animation?.cancel(); window.animation = nil
                app.windows.removeAll { $0 === window }
            } else if window.restoring && !window.appliedRestore && NSEvent.pressedMouseButtons != 0 {
                window.restoreTask?.cancel(); window.animation?.cancel(); window.animation = nil
                window.restoring = false
            }
        }
    }

    func prepareForCommand(on element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let window = apps[pid]?.windows.first(where: { CFEqual($0.element, element) }) {
            window.restoreTask?.cancel(); window.animation?.cancel(); window.animation = nil
            window.restoring = false
        }
    }

    func recordCommandResult(on element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return }
        persist(element, bundleID: bundleID)
    }

    private func persist(_ element: AXUIElement, bundleID: String) {
        guard let frame = normalFrame(element), let screen = screenFor(frame) else { return }
        let area = workArea(screen)
        let layout = RememberedWindowLayout(x: frame.minX, y: frame.minY,
            width: frame.width, height: frame.height, screenID: screenID(screen),
            screenX: area.minX, screenY: area.minY)
        guard layouts[bundleID] != layout else { return }
        layouts[bundleID] = layout
        if let data = try? JSONEncoder().encode(layouts) { defaults.set(data, forKey: "rememberedWindowLayouts") }
    }

    private func restoreWindow(_ window: TrackedWindow, app: TrackedApp,
                               layout: RememberedWindowLayout, attempt: Int) {
        let task = DispatchWorkItem { [weak self, weak window, weak app] in
            guard let self, let window, let app else { return }
            if NSEvent.pressedMouseButtons != 0 {
                window.restoring = false
                return
            }
            guard let current = self.normalFrame(window.element),
                  let screen = NSScreen.screens.first(where: { self.screenID($0) == layout.screenID })
                    ?? self.screenFor(current) else {
                if attempt < 4 { self.restoreWindow(window, app: app, layout: layout, attempt: attempt + 1) }
                else { window.restoring = false }
                return
            }
            let target = layout.fitted(to: self.workArea(screen), sameScreen: self.screenID(screen) == layout.screenID)
            window.appliedRestore = true
            let move = self.settable(window.element, kAXPositionAttribute)
            let resize = self.settable(window.element, kAXSizeAttribute)
            let apply: (CGRect) -> Bool = { [weak self, weak window] frame in
                guard let self, let window else { return false }
                var position = frame.origin, size = frame.size
                if move, AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString,
                    AXValueCreate(.cgPoint, &position)!) != .success { return false }
                if resize, AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString,
                    AXValueCreate(.cgSize, &size)!) != .success { return false }
                if move, AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString,
                    AXValueCreate(.cgPoint, &position)!) != .success { return false }
                return self.normalFrame(window.element) != nil
            }
            let animated = UserDefaults.standard.object(forKey: "animationEnabled") as? Bool ?? true
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = WindowGeometryAnimation(applyFrame: { [weak window] progress in
                    guard window != nil, NSEvent.pressedMouseButtons == 0 else { return false }
                    let frame = CGRect(
                        x: (current.minX + (target.minX - current.minX) * progress).rounded(),
                        y: (current.minY + (target.minY - current.minY) * progress).rounded(),
                        width: (current.width + (target.width - current.width) * progress).rounded(),
                        height: (current.height + (target.height - current.height) * progress).rounded())
                    return apply(frame)
                }, completion: {}, cleanup: { [weak window] in window?.animation = nil })
                window.animation = animation
                animation.start()
            } else {
                _ = apply(target)
            }
            // Ignore our own move/resize notifications while the app settles.
            let finish = DispatchWorkItem { [weak self, weak window, weak app] in
                guard let self, let window, let app else { return }
                window.restoring = false
                if let actual = self.normalFrame(window.element) {
                    let matches = abs(actual.minX - target.minX) <= 2 && abs(actual.minY - target.minY) <= 2 &&
                        abs(actual.width - target.width) <= 2 && abs(actual.height - target.height) <= 2
                    if !matches { NSLog("WindowKeys: remembered layout constrained or overridden for %@", app.bundleID) }
                }
            }
            window.restoreTask = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
        }
        window.restoreTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    private func normalFrame(_ element: AXUIElement) -> CGRect? {
        guard attribute(element, kAXMinimizedAttribute) as? Bool != true,
              attribute(element, "AXFullScreen") as? Bool != true,
              let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private func workArea(_ screen: NSScreen) -> CGRect {
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                      width: frame.width, height: frame.height)
    }
    private func screenFor(_ frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let x = frame.intersection(workArea(a)), y = frame.intersection(workArea(b))
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }
    }
}
