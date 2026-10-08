# Screen — character attributes (SGR)

SGR handling of `Terminal` (`Sources/ATermCore/Screen/`), reached through
`Terminal.feed(_:)`. Every case feeds `⎋[<params>mX` to a fresh 10×2 terminal
(`⎋` is ESC) and inspects the attributes of the cell holding `X` (0, 0).

## SCREEN-SGR-001 — SGR sets and resets text attributes

Implement: SGR (`CSI Pm m`) flags and underline styles in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenSGRTests.swift` · "SCREEN-SGR-001 SGR sets and resets text attributes"
- Given: params `1`, `2`, `3`, `5`, `7`, `8`, `9`, `53`
- When: each is fed in its own case
- Then: the flags are respectively exactly `bold`, `dim`, `italic`, `blink`, `inverse`, `hidden`, `strikethrough`, `overline`

- Given: params `4`, `21`, `4:3`, `4:4`, `4:5`, `4;4:0`
- When: each is fed in its own case
- Then: the underline style is respectively `single`, `double`, `curly`, `dotted`, `dashed`, `none`

- Given: params `1;2;22`, `3;23`, `4;24`, `5;25`, `7;27`, `8;28`, `9;29`, `53;55`
- When: each is fed in its own case
- Then: the attributes are the defaults

- Given: params `1;3;4;7;31;42;0` and, separately, params `1;4` followed by `⎋[m` before `X`
- When: each is fed in its own case
- Then: the attributes are the defaults

## SCREEN-SGR-002 — SGR selects indexed and direct colors

Implement: SGR color parameters (30–49, 90–107, 38/48/58 with `;` or `:` forms, 39/49/59) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenSGRTests.swift` · "SCREEN-SGR-002 SGR selects indexed and direct colors"
- Given: params `31`, `91`, `38;5;208`, `38:5:208`, `38;2;10;20;30`, `38:2::10:20:30`, `38:2:10:20:30`
- When: each is fed in its own case
- Then: the foreground is respectively `.indexed(1)`, `.indexed(9)`, `.indexed(208)`, `.indexed(208)`, `.rgb(10, 20, 30)`, `.rgb(10, 20, 30)`, `.rgb(10, 20, 30)`

- Given: params `47`, `107`, `48;5;17`, `48;2;1;2;3`
- When: each is fed in its own case
- Then: the background is respectively `.indexed(7)`, `.indexed(15)`, `.indexed(17)`, `.rgb(1, 2, 3)`

- Given: params `58:5:196`, `58;2;1;2;3`, `58;5;196;59`
- When: each is fed in its own case
- Then: the underline color is respectively `.indexed(196)`, `.rgb(1, 2, 3)`, `.default`

- Given: params `31;39` and `41;49`
- When: each is fed in its own case
- Then: the attributes are the defaults

- Given: params `38;5;1;4`
- When: it is fed
- Then: the foreground is `.indexed(1)` and the underline style is `single`

- Given: params `38;5` and `38;2;300;0;0`
- When: each is fed in its own case
- Then: the attributes are the defaults
