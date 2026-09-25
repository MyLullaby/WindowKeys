// Included by run-input-method-settings.sh; no external windows are modified.
private func checkDiagnosticLog() throws {
    let savedEnabled = UserDefaults.standard.object(forKey: "diagnosticLoggingEnabled")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("windowkeys-log-test-\(UUID().uuidString)", isDirectory: true)
    defer {
        UserDefaults.standard.set(savedEnabled, forKey: "diagnosticLoggingEnabled")
        try? FileManager.default.removeItem(at: directory)
    }
    let logger = DiagnosticLog(directory: directory)
    DiagnosticLog.isEnabled = false
    logger.write("must not be saved")
    assert(!FileManager.default.fileExists(atPath: directory.path))
    DiagnosticLog.isEnabled = true
    logger.write("test entry")
    let export = directory.appendingPathComponent("export.txt")
    try logger.export(to: export)
    let initialExport = try String(contentsOf: export, encoding: .utf8)
    assert(initialExport.contains("test entry"))
    for _ in 0..<600 { logger.write(String(repeating: "x", count: 4096)) }
    for name in ["current.log", "previous.log"] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        assert(data.count <= 1_048_576)
        assert(!data.isEmpty)
    }
    DiagnosticLog.isEnabled = false
    logger.write("disabled marker")
    try logger.export(to: export)
    let text = try String(contentsOf: export, encoding: .utf8)
    assert(!text.contains("disabled marker"))
    assert(!text.contains("test entry")) // Old entries have been rotated out.
    print("Diagnostic log checks passed")
}

try checkDiagnosticLog()
