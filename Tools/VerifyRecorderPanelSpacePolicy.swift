// Run from the repository root:
// swiftc Sources/DogSCApp/RecorderPanelSpacePolicy.swift \
//   Tools/VerifyRecorderPanelSpacePolicy.swift -o .build/verify-recorder-panel-space-policy
// .build/verify-recorder-panel-space-policy
//
// This is a headless AppKit check. Its private deferred panel is never ordered,
// activated, or made key. Show Desktop compositing needs a separate UI test.
import AppKit
import Foundation

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VerifyRecorderPanelSpacePolicy {
    @MainActor
    static func main() {
        do { try verify() }
        catch {
            emit(["status": "failed", "error": String(describing: error)])
            exit(1)
        }
    }

    @MainActor
    private static func verify() throws {
        var checks: [[String: Any]] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            let passed = condition()
            checks.append(["check": label, "passed": passed])
            if !passed { throw VerificationFailure(description: label) }
        }

        let legacyFloating: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        let floating = RecorderPanelSpacePolicy.collectionBehavior(isDocked: false)
        let docked = RecorderPanelSpacePolicy.collectionBehavior(isDocked: true)
        let desktopOverlay: NSWindow.CollectionBehavior = [.stationary, .canJoinAllApplications]
        let missionControlGroup: NSWindow.CollectionBehavior = [.managed, .transient, .stationary]
        let applicationGroup: NSWindow.CollectionBehavior = [.primary, .auxiliary, .canJoinAllApplications]
        let fullScreenGroup: NSWindow.CollectionBehavior = [.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenNone]

        try check(floating == legacyFloating, "Floating mode preserves the exact previous collection behavior")
        try check(docked.isSuperset(of: floating), "Docked mode retains every floating Space and window-cycle flag")
        try check(docked.subtracting(floating) == desktopOverlay, "Docked mode adds only the two desktop-overlay flags")
        try check(docked.intersection(missionControlGroup) == .stationary,
                  "Docked mode selects stationary without conflicting managed or transient flags")
        try check(docked.intersection(applicationGroup) == .canJoinAllApplications,
                  "Docked mode selects all-applications without conflicting primary or auxiliary flags")
        try check(floating.intersection(fullScreenGroup) == .fullScreenAuxiliary
                    && docked.intersection(fullScreenGroup) == .fullScreenAuxiliary,
                  "Both modes retain only the auxiliary full-screen behavior")

        let application = NSApplication.shared
        try check(application.activationPolicy() == .prohibited,
                  "The standalone test process prohibits activation")
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 90),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        defer { panel.close() }
        let initialFrame = panel.frame

        let transitions: [(String, NSWindow.CollectionBehavior, NSWindow.Level)] = [
            ("initial floating", floating, .floating),
            ("dock at notch", docked, NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)),
            ("return to floating", floating, .floating),
        ]
        for (label, behavior, level) in transitions {
            panel.collectionBehavior = behavior
            panel.level = level
            try check(panel.collectionBehavior == behavior, "AppKit accepts \(label) flags")
            try check(panel.frame == initialFrame, "Changing \(label) policy preserves the logical frame")
            try check(!panel.isVisible && !panel.isKeyWindow && !panel.isMainWindow,
                      "The private panel remains invisible and inactive after \(label)")
        }
        try check(application.activationPolicy() == .prohibited,
                  "The test never changes its prohibited activation policy")
        emit([
            "status": "passed", "checksPassed": checks.count, "checks": checks,
            "floatingRawValue": floating.rawValue, "dockedRawValue": docked.rawValue,
            "scope": "Actual production policy plus never-ordered private AppKit panel",
            "limitation": "Does not simulate WindowServer Show Desktop transforms; verify that interaction separately",
        ])
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
