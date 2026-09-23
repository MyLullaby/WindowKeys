// Run on macOS: zsh Tests/run-input-method-settings.sh
// Does not switch input sources or move external windows.
private func checkInputMethodSettings() {
    _ = NSApplication.shared
    let savedOverrides = InputMethodPreferences.appOverrides
    let savedDefault = InputMethodPreferences.defaultSourceIdentifier
    defer {
        InputMethodPreferences.appOverrides = savedOverrides
        InputMethodPreferences.defaultSourceIdentifier = savedDefault
    }

    guard let source = InputSourceCatalog.availableInputSources().first else {
        fatalError("Enable an input source before running this check")
    }
    let bundleID = "org.windowkeys.tests.current-application"
    InputMethodPreferences.removeOverride(for: bundleID)
    InputMethodPreferences.defaultSourceIdentifier = source.identifier
    let controller = InputMethodSettingsWindowController()
    var changes = 0
    controller.onConfigurationChange = { changes += 1 }
    controller.addRule(for: bundleID)
    assert(InputMethodPreferences.appOverrides[bundleID] == source.identifier)
    assert(changes == 1)

    // Even an unavailable, explicitly configured source must survive re-adding.
    InputMethodPreferences.setOverride("test.unavailable.source", for: bundleID)
    controller.addRule(for: bundleID)
    assert(InputMethodPreferences.appOverrides[bundleID] == "test.unavailable.source")
    assert(changes == 1)

    if let app = AccessibilityWindowController.shared.currentExternalApplication() {
        assert(app.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        assert(!app.isTerminated)
    }
    print("Input method settings checks passed")
}

checkInputMethodSettings()
