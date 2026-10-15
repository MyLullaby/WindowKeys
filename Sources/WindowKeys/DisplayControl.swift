import AppKit

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

final class DisplayControlWindowController: NSWindowController {
    private let displays = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let brightness = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volume = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let brightnessLabel = NSTextField(labelWithString: "亮度：未读取")
    private let volumeLabel = NSTextField(labelWithString: "音量：未读取")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let queue = DispatchQueue(label: "com.bland.windowkeys.display-control")
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
