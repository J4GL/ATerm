# Input — holding ⌘ to open the assistant

`CommandHoldDetector` in `Sources/ATermCore/Input/CommandHoldDetector.swift`
decides from event times whether ⌘ was held alone long enough. The terminal
view feeds it: ⌘ pressed or released alone (`flagsChanged`, Caps Lock
ignored), and any other input (keys, key equivalents, clicks, scrolling, other
modifiers, loss of focus). A hint is shown once the delay has passed while ⌘
is still down; the assistant opens when ⌘ is released.

## INPUT-HOLD-001 — ⌘ held alone for 0.4 s then released opens the assistant

Implement: `CommandHoldDetector` (delay 0.4 s), driven by `TerminalView.flagsChanged(with:)` and the view's other input handlers; its hint and trigger are handled by `AssistantController`.
Uses: [Assistant contract](../assistant/contract.md)

Test: unit · `Tests/ATermCoreTests/CommandHoldTests.swift` · "INPUT-HOLD-001 command held alone for 0.4 s then released opens the assistant"
- Given: a detector with a delay of 0.4 s, a manual timer, and a system reporting the time since the last key or click anywhere (by default 60 s), for each case below
- When: the events below happen (times in seconds)
- Then: the detector's outputs are exactly:

| Events | Outputs |
|---|---|
| ⌘ down at 10.0; timer fires; ⌘ up at 10.6 | show hint, trigger |
| ⌘ down at 10.0; ⌘ up at 10.1; timer fires | none |
| ⌘ down at 10.0; timer fires; other input; ⌘ up at 10.8 | show hint, hide hint |
| ⌘ down at 10.0; other input; timer fires; ⌘ up at 10.8 | none |
| ⌘ down at 10.0; timer fires; the system saw a key 0.2 s ago; ⌘ up at 10.6 | show hint, hide hint |
| ⌘ down at 10.0; ⌘ up at 10.45 (the timer has not fired) | trigger |
