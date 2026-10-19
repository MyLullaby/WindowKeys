import AppKit

struct PowerAwakeStatus: Equatable {
    let enabled: Bool
    let sleepDisabled: Bool?
    let batteryPercent: Int?
    let onAC: Bool?
    let updatePending: Bool
    let appBound: Bool

    init?(output: String) {
        let lines = output.components(separatedBy: .newlines)
        guard let service = lines.first(where: { $0.hasPrefix("Service: ") }),
              service == "Service: enabled" || service == "Service: disabled" else { return nil }
        enabled = service == "Service: enabled"
        sleepDisabled = lines.contains { $0.hasPrefix("System sleep disabled: 1 ") } ? true :
            (lines.contains { $0.hasPrefix("System sleep disabled: 0 ") } ? false : nil)
        let charge = lines.first { $0.hasPrefix("Battery charge: ") }?
            .replacingOccurrences(of: "Battery charge: ", with: "").replacingOccurrences(of: "%", with: "")
        batteryPercent = charge.flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil }
        onAC = lines.contains("Power source: ac") ? true :
            (lines.contains("Power source: battery") ? false : nil)
        updatePending = lines.contains { $0.hasPrefix("Update pending:") }
        appBound = lines.contains("Lifecycle: app-bound")
    }
}

final class PowerAwakeController {
    private(set) var status: PowerAwakeStatus?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    private var refreshing = false
    var canQuit: Bool { !isBusy }
    var canChange: Bool { !isBusy && !refreshing && status != nil }
    private let queue = DispatchQueue(label: "com.bland.windowkeys.power-awake", qos: .utility)
    private let scriptURL: URL?

    init(bundle: Bundle = .main) {
        scriptURL = bundle.url(forResource: "power-awake", withExtension: nil)
    }

    // Arguments go through osascript's argv, never interpolation into AppleScript.
    static let authorizationScript = """
    on run argv
        set helperPath to item 1 of argv
        set operation to item 2 of argv
        if operation is not "app-on" and operation is not "off" then error "Invalid operation"
        set shellCommand to "/bin/bash " & quoted form of helperPath & " " & quoted form of operation
        if operation is "app-on" then
            set shellCommand to shellCommand & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv)
        end if
        return do shell script shellCommand with administrator privileges
    end run
    """

    func refresh() {
        guard !refreshing, !isBusy else { return }
        refreshing = true
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run(authorized: false, operation: "status")
            DispatchQueue.main.async {
                self.refreshing = false
                if result.code == 0, let status = PowerAwakeStatus(output: result.output) {
                    self.status = status
                    self.errorMessage = nil
                } else {
                    self.status = nil
                    self.errorMessage = "无法读取防休眠状态：\(result.output.prefix(500))"
                }
                self.onChange?()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard canChange else { return }
        let alert = NSAlert()
        alert.messageText = enabled ? "开启或更新合盖防休眠？" : "关闭合盖防休眠？"
        alert.informativeText = enabled
            ? "接电或电量达到 50% 时，系统休眠将被禁用；未接电且电量低于 50% 时，约 2 秒内允许休眠。\n\n需要管理员授权。服务绑定本次 WindowKeys 进程，退出应用后约 2 秒内停止并还原设置，重启不自动开启。现有独立服务会转换为应用绑定服务。请保持散热，装包前关闭；它不负责启动代理或保证网络连接。"
            : "需要管理员授权。将停止并移除 local.power-awake 服务，恢复首次开启前的休眠设置；原设置若已禁用休眠，关闭后也可能仍不休眠。"
        alert.addButton(withTitle: enabled ? "继续开启／更新" : "继续关闭")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run(authorized: true, operation: enabled ? "app-on" : "off")
            DispatchQueue.main.async {
                self.isBusy = false
                if result.code != 0 && !result.output.contains("(-128)") {
                    let failure = NSAlert()
                    failure.messageText = "防休眠操作未完成"
                    failure.informativeText = String(result.output.prefix(1500))
                    failure.addButton(withTitle: "知道了")
                    NSApp.activate(ignoringOtherApps: true)
                    failure.runModal()
                }
                self.refresh()
                self.onChange?()
            }
        }
    }

    private func run(authorized: Bool, operation: String) -> (code: Int32, output: String) {
        guard let scriptURL else { return (-1, "应用缺少 power-awake 资源，请重新构建或安装。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: authorized ? "/usr/bin/osascript" : "/bin/bash")
        var arguments = authorized
            ? ["-e", Self.authorizationScript, scriptURL.path, operation]
            : [scriptURL.path, operation]
        if authorized && operation == "app-on" {
            let owner = Process()
            owner.executableURL = URL(fileURLWithPath: "/bin/ps")
            owner.arguments = ["-p", String(ProcessInfo.processInfo.processIdentifier), "-o", "lstart="]
            let output = Pipe()
            owner.standardOutput = output
            do {
                try owner.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                owner.waitUntilExit()
                let start = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard owner.terminationStatus == 0, !start.isEmpty else { return (-1, "无法确定应用进程身份。") }
                arguments += [String(ProcessInfo.processInfo.processIdentifier), start]
            } catch { return (-1, error.localizedDescription) }
        }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (-1, error.localizedDescription) }
    }
}
