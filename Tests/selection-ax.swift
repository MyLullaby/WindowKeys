import Foundation

// Manual integration check: leave this process waiting, then select known text
// in the target app. No clipboard or translation request is involved.
guard CommandLine.arguments.count == 3, AXIsProcessTrusted() else {
    fputs("Usage: run-selection-ax.sh <foreground-bundle-id> <expected-selection>; Accessibility required\n", stderr)
    exit(2)
}
let bundleID = CommandLine.arguments[1]
let expected = CommandLine.arguments[2]
let deadline = Date().addingTimeInterval(45)
var observedBundle = "nil"
var observedLength = -1
while Date() < deadline {
    if let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        observedBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let actual = TranslationSelectionReader.read(from: target)
        observedLength = actual?.count ?? -1
        if (expected == "--none" && actual == nil) || actual == expected {
            print("PASS AX selection for \(bundleID), length=\(actual?.count ?? 0)")
            exit(0)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
fputs("AX selection mismatch (expected length \(expected.count), observed length \(observedLength), frontmost \(observedBundle))\n", stderr)
exit(1)
