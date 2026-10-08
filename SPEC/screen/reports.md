# Screen — reports, titles and notifications

Replies and notifications of `Terminal` (`Sources/ATermCore/Screen/`),
reached through `Terminal.feed(_:)`. Replies are the bytes passed to
`TerminalDelegate.terminal(_:send:)`, which the app's terminal session writes
to the PTY. `⎋` stands for ESC, BEL is U+0007; every case starts from a fresh
80×24 terminal with the default palette.

## SCREEN-REPORT-001 — Device attribute requests are answered

Implement: DA1 (`CSI c`), DA2 (`CSI > c`) and DECID (`ESC Z`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-001 device attribute requests are answered"
- Given: inputs `⎋[c`, `⎋[0c`, `⎋Z`
- When: each is fed in its own case
- Then: the terminal sends exactly `⎋[?62;22c`

- Given: input `⎋[>c`
- When: it is fed
- Then: the terminal sends exactly `⎋[>1;10;0c`

- Given: input `⎋[=c`
- When: it is fed
- Then: the terminal sends nothing

## SCREEN-REPORT-002 — Status reports give the terminal state and cursor position

Implement: DSR (`CSI Ps n`, `CSI ? Ps n`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-002 status reports give the terminal state and cursor position"
- Given: input `⎋[5n`
- When: it is fed
- Then: the terminal sends exactly `⎋[0n`

- Given: input `⎋[3;7H⎋[6n`
- When: it is fed
- Then: the terminal sends exactly `⎋[3;7R`

- Given: input `⎋[3;7H⎋[?6n`
- When: it is fed
- Then: the terminal sends exactly `⎋[?3;7R`

## SCREEN-REPORT-003 — OSC 0 and 2 set the title, which can be pushed and popped

Implement: OSC 0/1/2 and XTWINOPS 22/23 (`CSI 22 ; Ps t`, `CSI 23 ; Ps t`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-003 OSC 0 and 2 set the title which can be pushed and popped"
- Given: input `⎋]0;Hello` BEL
- When: it is fed
- Then: the title is `Hello` and the delegate was notified once

- Given: input `⎋]2;Wörld⎋\`
- When: it is fed
- Then: the title is `Wörld`

- Given: input `⎋]1;icon` BEL
- When: it is fed
- Then: the title is empty and the delegate was not notified

- Given: input `⎋]2;A` BEL `⎋[22;0t⎋]2;B` BEL `⎋[23;0t`
- When: it is fed
- Then: the title is `A`

## SCREEN-REPORT-004 — Colors can be queried and changed with OSC 4, 10, 11 and 12

Implement: OSC 4/10/11/12 queries and changes and OSC 104/110/111/112 resets in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-004 colors can be queried and changed with OSC 4 10 11 and 12"
- Given: input `⎋]11;?` BEL
- When: it is fed
- Then: the terminal sends exactly `⎋]11;rgb:1e1e/1f1f/2626` BEL

- Given: input `⎋]10;?⎋\`
- When: it is fed
- Then: the terminal sends exactly `⎋]10;rgb:d9d9/dbdb/e3e3⎋\`

- Given: input `⎋]12;?` BEL
- When: it is fed
- Then: the terminal sends exactly `⎋]12;rgb:f2f2/c5c5/7272` BEL

- Given: input `⎋]4;1;?` BEL
- When: it is fed
- Then: the terminal sends exactly `⎋]4;1;rgb:e5e5/6464/6a6a` BEL

- Given: input `⎋]4;1;rgb:ff/00/80` BEL
- When: it is fed
- Then: palette color 1 is (255, 0, 128) and the delegate was notified of a palette change
- When: `⎋]104;1` BEL is fed
- Then: palette color 1 is (229, 100, 106)

- Given: input `⎋]11;#102030` BEL
- When: it is fed
- Then: the palette background is (16, 32, 48)
- When: `⎋]111` BEL is fed
- Then: the palette background is (30, 31, 38)

- Given: input `⎋]4;2;#010203;3;#040506` BEL then `⎋]104` BEL
- When: the first part is fed
- Then: palette colors 2 and 3 are (1, 2, 3) and (4, 5, 6)
- When: the second part is fed
- Then: palette colors 2 and 3 are (140, 203, 126) and (232, 194, 122)

## SCREEN-REPORT-005 — OSC 7 reports the working directory

Implement: OSC 7 in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-005 OSC 7 reports the working directory"
- Given: input `⎋]7;file://host/Users/me/My%20Dir` BEL
- When: it is fed
- Then: the working directory is `/Users/me/My Dir` and the delegate was notified once

- Given: input `⎋]7;file:///tmp⎋\`
- When: it is fed
- Then: the working directory is `/tmp`

- Given: input `⎋]7;not a url` BEL
- When: it is fed
- Then: the working directory is nil and the delegate was not notified

## SCREEN-REPORT-006 — BEL rings the bell

Implement: BEL execution in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-006 BEL rings the bell"
- Given: input `a` BEL `b` BEL
- When: it is fed
- Then: the delegate received two bell notifications and row 0 is `ab`

## SCREEN-REPORT-007 — DECRQM reports whether a mode is set

Implement: DECRQM (`CSI ? Ps $ p`, `CSI Ps $ p`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-007 DECRQM reports whether a mode is set"
- Given: input `⎋[?2004h⎋[?2004$p`
- When: it is fed
- Then: the terminal sends exactly `⎋[?2004;1$y`

- Given: input `⎋[?2004$p`
- When: it is fed
- Then: the terminal sends exactly `⎋[?2004;2$y`

- Given: input `⎋[?9999$p`
- When: it is fed
- Then: the terminal sends exactly `⎋[?9999;0$y`

- Given: input `⎋[4$p`
- When: it is fed
- Then: the terminal sends exactly `⎋[4;2$y`

## SCREEN-REPORT-008 — XTWINOPS 18 reports the text area size in characters

Implement: XTWINOPS 18 (`CSI 18 t`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-008 XTWINOPS 18 reports the text area size in characters"
- Given: input `⎋[18t`
- When: it is fed
- Then: the terminal sends exactly `⎋[8;24;80t`

## SCREEN-REPORT-009 — OSC 6973 passes a completion request to the delegate

Implement: OSC 6973 in `Terminal`, reported through `TerminalDelegate.terminal(_:didRequestCompletionOf:nonce:)`, called by `Terminal.feed(_:)`; zsh sends it through ATerm's [zsh integration](../pty/shell-integration.md).
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenReportTests.swift` · "SCREEN-REPORT-009 OSC 6973 passes a completion request to the delegate"
- Given: input `⎋]6973;n1;git pu⎋\`
- When: it is fed
- Then: the delegate received one completion request, with the nonce `n1` and the line `git pu`; the cursor is at (0, 0) and row 0 is empty

- Given: input `⎋]6973;n1;écho a; b` BEL
- When: it is fed
- Then: the delegate received one completion request, with the nonce `n1` and the line `écho a; b`

- Given: input `⎋]6973;n1;` BEL
- When: it is fed
- Then: the delegate received one completion request, with the nonce `n1` and an empty line

- Given: input `⎋]6973;n1` BEL
- When: it is fed
- Then: the delegate received no completion request
