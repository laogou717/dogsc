/// Presentation state only. TCC remains owned by AppModel; this value never
/// grants permissions, changes application phase, or activates another app.
struct PermissionTourFlow: Equatable {
    struct Access: Equatable, Sendable {
        var screen: Bool
        var accessibility: Bool
        var allGranted: Bool { screen && accessibility }
        var firstRequiredStep: Step { !screen ? .screen : !accessibility ? .accessibility : .ready }
        func grants(_ step: Step) -> Bool {
            switch step {
            case .screen: screen
            case .accessibility: accessibility
            case .ready: allGranted
            }
        }
    }

    enum Step: Int, Equatable, Sendable { case screen, accessibility, ready }
    enum Action: Equatable { case openSettings(Step), advance, enter }

    private(set) var access: Access
    private(set) var step: Step
    private(set) var settingsStep: Step?
    let isReview: Bool

    init(access: Access, isReview: Bool) {
        self.access = access
        self.isReview = isReview
        step = isReview ? .screen : access.firstRequiredStep
    }

    mutating func update(_ access: Access) {
        self.access = access
        // While the OS owns focus, retain the source step even if polling has
        // observed success. A fresh check on return decides the next prompt.
        if settingsStep == nil, !isReview { step = access.firstRequiredStep }
        if step == .ready, !access.allGranted { step = access.firstRequiredStep }
    }

    mutating func openedSettings(for step: Step) {
        guard step != .ready else { return }
        settingsStep = step
        self.step = step
    }

    mutating func returnedFromSettings(access: Access) {
        let previous = settingsStep
        self.access = access
        settingsStep = nil
        if let previous, !access.grants(previous) {
            step = previous
        } else {
            step = access.firstRequiredStep
        }
    }

    var primaryAction: Action {
        if step == .ready {
            return access.allGranted ? .enter : .openSettings(access.firstRequiredStep)
        }
        return access.grants(step) ? .advance : .openSettings(step)
    }

    mutating func advance() {
        guard primaryAction == .advance else { return }
        step = Step(rawValue: min(step.rawValue + 1, Step.ready.rawValue)) ?? .ready
        if step == .ready, !access.allGranted { step = access.firstRequiredStep }
    }

    mutating func previous() {
        guard isReview else { return }
        step = Step(rawValue: max(step.rawValue - 1, 0)) ?? .screen
    }
}
