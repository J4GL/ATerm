import Foundation
import Testing
import ATermCore

/// Runs scheduled work only when told to.
final class ManualTimer: @unchecked Sendable {
    private var pending: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append(work) }

    func fire() {
        let work = pending
        pending.removeAll()
        work.forEach { $0() }
    }
}

enum HoldStep: Sendable {
    case down(TimeInterval), up(TimeInterval), fire, other, systemInput(ageSeconds: TimeInterval)
}

struct HoldCase: CustomTestStringConvertible, Sendable {
    let name: String
    let steps: [HoldStep]
    let outputs: [CommandHoldDetector.Output]

    var testDescription: String { name }
}

@Test("INPUT-HOLD-001 command held alone for 0.4 s then released opens the assistant", arguments: [
    HoldCase(name: "held then released", steps: [.down(10.0), .fire, .up(10.6)], outputs: [.showHint, .trigger]),
    HoldCase(name: "tapped", steps: [.down(10.0), .up(10.1), .fire], outputs: []),
    HoldCase(name: "other input after the hint", steps: [.down(10.0), .fire, .other, .up(10.8)],
             outputs: [.showHint, .hideHint]),
    HoldCase(name: "other input before the hint", steps: [.down(10.0), .other, .fire, .up(10.8)], outputs: []),
    HoldCase(name: "system input during the hold",
             steps: [.down(10.0), .fire, .systemInput(ageSeconds: 0.2), .up(10.6)], outputs: [.showHint, .hideHint]),
    HoldCase(name: "released before the timer fired", steps: [.down(10.0), .up(10.45)], outputs: [.trigger]),
])
func INPUT_HOLD_001(_ testCase: HoldCase) {
    let timer = ManualTimer()
    var outputs: [CommandHoldDetector.Output] = []
    var systemInputAge: TimeInterval = 60
    let detector = CommandHoldDetector(delay: 0.4, schedule: timer.schedule, systemInputAge: { systemInputAge },
                                       output: { outputs.append($0) })
    for step in testCase.steps {
        switch step {
        case .down(let time): detector.commandDown(at: time)
        case .up(let time): detector.commandUp(at: time)
        case .fire: timer.fire()
        case .other: detector.otherInput()
        case .systemInput(let age): systemInputAge = age
        }
    }
    #expect(outputs == testCase.outputs)
}
