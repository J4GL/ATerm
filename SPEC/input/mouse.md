# Input — mouse reporting

`MouseEncoder.encode(_:tracking:encoding:)` in
`Sources/ATermCore/Input/MouseEncoder.swift` turns a mouse event into the
bytes written to the PTY when the program enabled mouse tracking (see
`TerminalModes.mouseTracking` / `mouseEncoding`). Its caller is
`TerminalView`'s mouse and scroll-wheel handlers in the app.

An event has a button (`left`, `middle`, `right`, `wheelUp`, `wheelDown`,
`none`), an action (`press`, `release`, `motion`), a 0-based cell position and
modifiers (`shift`, `option`, `control`). Button codes: left 0, middle 1,
right 2, wheel up 64, wheel down 65, no button 3; +32 for motion; modifiers
add shift 4, option 8, control 16. Positions are reported 1-based. `⎋` is ESC.

## INPUT-MOUSE-001 — SGR encoding reports buttons, wheel, modifiers and motion

Implement: SGR (1006) encoding in `MouseEncoder.encode`, called by `TerminalView` mouse handlers.

Test: unit · `Tests/ATermCoreTests/MouseEncoderTests.swift` · "INPUT-MOUSE-001 SGR encoding reports buttons wheel modifiers and motion"
- Given: tracking `.normal`, encoding `.sgr`, position row 2 col 4
- When: left press, left release, middle press, right press, wheel up, wheel down, control + left press, shift + option + left press are encoded
- Then: the bytes are respectively `⎋[<0;5;3M`, `⎋[<0;5;3m`, `⎋[<1;5;3M`, `⎋[<2;5;3M`, `⎋[<64;5;3M`, `⎋[<65;5;3M`, `⎋[<16;5;3M`, `⎋[<12;5;3M`

- Given: tracking `.buttonEvent`, encoding `.sgr`, position row 2 col 4
- When: a motion with the left button held is encoded
- Then: the bytes are `⎋[<32;5;3M`

- Given: tracking `.anyEvent`, encoding `.sgr`, position row 2 col 4
- When: a motion with no button is encoded
- Then: the bytes are `⎋[<35;5;3M`

## INPUT-MOUSE-002 — Legacy encoding offsets values by 32 and cannot reach far cells

Implement: legacy (X10-style) encoding in `MouseEncoder.encode`, called by `TerminalView` mouse handlers.

Test: unit · `Tests/ATermCoreTests/MouseEncoderTests.swift` · "INPUT-MOUSE-002 legacy encoding offsets values by 32 and cannot reach far cells"
- Given: tracking `.normal`, encoding `.legacy`, position row 2 col 4
- When: left press, left release and wheel up are encoded
- Then: the bytes are respectively `⎋[M` + `20 25 23`, `⎋[M` + `23 25 23`, `⎋[M` + `60 25 23`

- Given: tracking `.normal`, encoding `.legacy`, position row 0 col 223
- When: a left press is encoded
- Then: nothing is produced

## INPUT-MOUSE-003 — The tracking mode decides which events are reported

Implement: event filtering in `MouseEncoder.encode`, called by `TerminalView` mouse handlers.

Test: unit · `Tests/ATermCoreTests/MouseEncoderTests.swift` · "INPUT-MOUSE-003 the tracking mode decides which events are reported"
- Given: tracking `.none`
- When: a left press is encoded
- Then: nothing is produced

- Given: tracking `.x10`, encoding `.legacy`, position row 0 col 0
- When: a control + left press, a left release and a wheel up are encoded
- Then: the press gives `⎋[M` + `20 21 21` (modifiers are not reported) and the release and the wheel produce nothing

- Given: tracking `.normal`
- When: a motion with the left button held is encoded
- Then: nothing is produced

- Given: tracking `.buttonEvent`
- When: a motion with no button is encoded
- Then: nothing is produced
