import AppKit

private let displayControlQueue = DispatchQueue(label: "com.bland.windowkeys.display-control")

private struct ExternalDisplay: Decodable {
    let id: String
    let name: String
}

private struct DisplayValue: Decodable {
    let current: Int
    let maximum: Int
}

private struct DisplayValues: Decodable {
    let brightness: DisplayValue?
    let volume: DisplayValue?
}

private enum DisplayControlError: LocalizedError {
    case unavailable, timeout, failed(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "显示器控制组件缺失，请重新构建应用。"
        case .timeout: return "显示器响应超时，请检查连接后刷新。"
        case .failed(let code):
            return "无法读取或确认显示器设置（\(code)）。请开启显示器菜单中的 DDC/CI，并检查线缆/扩展坞是否支持。"
        }
    }
}

// Run DDC in a bounded child process: a stalled driver must not block the app UI.
private func runDisplayControl(_ arguments: [String]) throws -> Data {
    guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("DisplayControl"),
        FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw DisplayControlError.unavailable
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + 8) == .timedOut {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw DisplayControlError.timeout
    }
    guard process.terminationStatus == 0 else { throw DisplayControlError.failed(process.terminationStatus) }
    return output.fileHandleForReading.readDataToEndOfFile()
}

final class DisplayBrightnessKeys {
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingSteps = 0.0
    private var working = false
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ExternalBrightnessKeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ExternalBrightnessKeys") }
    }

    // NX_SYSDEFINED brightness keys, not ordinary F1/F2 keyDown events.
    static func step(for event: NSEvent) -> Double? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8,
              (event.data1 >> 8) & 0xff == 0x0a else { return nil }
        let key = (event.data1 >> 16) & 0xffff
        guard key == 2 || key == 3 else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty || modifiers == [.option, .shift] else { return nil }
        return (key == 2 ? 1.0 : -1.0) * (modifiers.isEmpty ? 1 : 0.25)
    }

    static func target(current: Int, maximum: Int, steps: Double) -> Int {
        min(maximum, max(0, current + Int((Double(maximum) * steps / 16).rounded(.awayFromZero))))
    }

    func start() {
        guard isEnabled else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<DisplayBrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let keyEvent = NSEvent(cgEvent: event), let step = DisplayBrightnessKeys.step(for: keyEvent) {
                    owner.pendingSteps = min(16, max(-16, owner.pendingSteps + step))
                    if !owner.working {
                        owner.working = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak owner] in owner?.drain() }
                    }
                }
                // Listen only: macOS still receives every event for the built-in display.
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        pendingSteps = 0
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func drain() {
        guard isEnabled, pendingSteps != 0 else { working = false; return }
        let steps = pendingSteps
        pendingSteps = 0
        displayControlQueue.async {
            let result = Result { try JSONDecoder().decode([ExternalDisplay].self, from: runDisplayControl(["list"])) }
            var errors: [String] = []
            switch result {
            case .success(let displays):
                for display in displays {
                    let adjustment = Result {
                        let values = try JSONDecoder().decode(DisplayValues.self, from: runDisplayControl(["read", display.id]))
                        guard let brightness = values.brightness else { return }
                        let target = Self.target(current: brightness.current, maximum: brightness.maximum, steps: steps)
                        if target != brightness.current {
                            _ = try runDisplayControl(["set", display.id, "brightness", String(target)])
                        }
                    }
                    if case .failure(let error) = adjustment { errors.append("\(display.name): \(error.localizedDescription)") }
                }
            case .failure(let error): errors.append(error.localizedDescription)
            }
            DispatchQueue.main.async {
                if !errors.isEmpty { self.onError?(errors.joined(separator: "\n")) }
                self.onChange?()
                self.drain()
            }
        }
    }

    deinit { stop() }
}

final class DisplayControlWindowController: NSWindowController {
    private let displays = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let brightness = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volume = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let brightnessLabel = NSTextField(labelWithString: "亮度：未读取")
    private let volumeLabel = NSTextField(labelWithString: "音量：未读取")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let queue = displayControlQueue
    private var availableDisplays: [ExternalDisplay] = []
    private var values: DisplayValues?
    private var busy = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "外接显示器"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let selector = NSStackView(views: [displays, refreshButton])
        selector.spacing = 12
        root.addArrangedSubview(selector)
        selector.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        for view in [brightnessLabel, brightness, volumeLabel, volume, status] {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        displays.target = self
        displays.action = #selector(selectionChanged)
        displays.setAccessibilityLabel("外接显示器")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        brightness.target = self
        brightness.action = #selector(sliderChanged(_:))
        brightness.isContinuous = false
        brightness.setAccessibilityLabel("显示器亮度")
        volume.target = self
        volume.action = #selector(sliderChanged(_:))
        volume.isContinuous = false
        volume.setAccessibilityLabel("显示器音量")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        updateControls()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    func brightnessDidChange() {
        if window?.isVisible == true { refresh() }
    }

    private var selectedID: String? {
        let index = displays.indexOfSelectedItem
        return availableDisplays.indices.contains(index) ? availableDisplays[index].id : nil
    }

    private func updateControls() {
        displays.isEnabled = !busy && !availableDisplays.isEmpty
        refreshButton.isEnabled = !busy
        for (slider, label, value, title) in [
            (brightness, brightnessLabel, values?.brightness, "亮度"),
            (volume, volumeLabel, values?.volume, "音量")
        ] {
            slider.isEnabled = !busy && value != nil
            if let value, value.maximum > 0 {
                slider.maxValue = Double(value.maximum)
                slider.integerValue = value.current
                label.stringValue = "\(title)：\(Int((Double(value.current) / Double(value.maximum) * 100).rounded()))%"
            } else {
                slider.doubleValue = 0
                label.stringValue = "\(title)：\(busy ? "读取中…" : "不可用 / 不支持 DDC/CI")"
            }
        }
    }

    @objc private func refresh() {
        guard !busy else { return }
        let previous = selectedID
        busy = true
        values = nil
        status.stringValue = "正在检测外接显示器…"
        updateControls()
        queue.async {
            let result = Result { try JSONDecoder().decode([ExternalDisplay].self, from: runDisplayControl(["list"])) }
            DispatchQueue.main.async {
                self.busy = false
                self.displays.removeAllItems()
                self.availableDisplays = []
                switch result {
                case .success(let list):
                    self.availableDisplays = list
                    for (index, display) in list.enumerated() {
                        self.displays.addItem(withTitle: "\(index + 1). \(display.name)")
                    }
                    self.displays.selectItem(at: list.firstIndex { $0.id == previous } ?? 0)
                    if list.isEmpty {
                        self.status.stringValue = "未检测到外接显示器。连接后请刷新。"
                    } else {
                        self.selectionChanged()
                    }
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                self.updateControls()
            }
        }
    }

    @objc private func selectionChanged() {
        guard !busy, let id = selectedID else { return }
        values = nil
        perform(["read", id])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !busy, let id = selectedID else { return }
        let feature = sender === brightness ? "brightness" : "volume"
        perform(["set", id, feature, String(Int(sender.doubleValue.rounded()))])
    }

    private func perform(_ arguments: [String]) {
        busy = true
        status.stringValue = arguments[0] == "set" ? "正在写入并读取确认…" : "正在读取亮度和音量…"
        updateControls()
        queue.async {
            let result = Result { try JSONDecoder().decode(DisplayValues.self, from: runDisplayControl(arguments)) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let values):
                    self.values = values
                    self.status.stringValue = "调节显示器硬件设置。不可用项需显示器及连接链路支持 DDC/CI；音量控制不改变 Mac 系统音量。"
                case .failure(let error):
                    self.values = nil
                    self.status.stringValue = error.localizedDescription + " 请刷新重试。"
                }
                self.updateControls()
            }
        }
    }
}
