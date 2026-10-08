import Foundation

/// Decides from event times whether ⌘ was held alone long enough to open the assistant: a hint once the
/// delay has passed while ⌘ is down, the trigger when it is released. See SPEC/input/hold.md.
public final class CommandHoldDetector {
    public enum Output: Equatable, Sendable {
        case showHint, hideHint, trigger
    }

    public static let defaultDelay: TimeInterval = 0.4

    private enum State {
        case idle
        case holding(start: TimeInterval, generation: Int, hintShown: Bool)
    }

    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let systemInputAge: () -> TimeInterval?
    private let output: (Output) -> Void
    private var state = State.idle
    private var generation = 0

    /// `systemInputAge` gives the time since the last key or click anywhere, when known: a key or click the
    /// app did not see (⌘Tab, ⌘Space…) during the hold rejects it.
    public init(delay: TimeInterval = CommandHoldDetector.defaultDelay,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                systemInputAge: @escaping () -> TimeInterval?, output: @escaping (Output) -> Void) {
        self.delay = delay
        self.schedule = schedule
        self.systemInputAge = systemInputAge
        self.output = output
    }

    public var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    /// ⌘ went down with no other modifier.
    public func commandDown(at time: TimeInterval) {
        guard !isHolding else { return }
        generation += 1
        let current = generation
        state = .holding(start: time, generation: current, hintShown: false)
        schedule(delay) { [weak self] in
            guard let self, case .holding(let start, current, false) = self.state else { return }
            self.state = .holding(start: start, generation: current, hintShown: true)
            self.output(.showHint)
        }
    }

    /// ⌘ went up with no other modifier down.
    public func commandUp(at time: TimeInterval) {
        guard case .holding(let start, _, let hintShown) = state else { return }
        state = .idle
        let held = time - start
        let undisturbed = systemInputAge().map { $0 >= held } ?? true
        if held >= delay && undisturbed {
            output(.trigger)
        } else if hintShown {
            output(.hideHint)
        }
    }

    /// Any other input: a key, a key equivalent, a click, scrolling, another modifier, a loss of focus.
    public func otherInput() {
        guard case .holding(_, _, let hintShown) = state else { return }
        state = .idle
        if hintShown { output(.hideHint) }
    }
}
