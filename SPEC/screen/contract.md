# Screen model contract

Shared by the screen, selection, input and app specs. Code lives in
`Sources/ATermCore/Screen/`. `Terminal` is the `VTParserHandler` that turns
parser actions into this model; `Terminal.feed(_:)` is called by the app's
terminal session with every chunk read from the PTY.

## Coordinates

- Rows and columns are 0-based in the API and `(row, col)` in the specs;
  escape-sequence parameters are 1-based.
- `Terminal(cols:rows:scrollbackLimit:palette:)` — the default scrollback
  limit is 10 000 lines and the default palette is the one below.
- The screen has `rows` lines of exactly `cols` cells each. The active buffer is
  the main screen or the alternate screen.
- Scrollback holds the lines scrolled off the top of the main screen, oldest
  first. `linesDropped` counts the lines discarded from the front of the
  scrollback (limit overflow or `ED 3`).
- Absolute line index `a`: scrollback line `a - linesDropped` when it is below
  `linesDropped + scrollbackCount`, otherwise screen row
  `a - linesDropped - scrollbackCount`. It stays attached to the same line of
  text while output scrolls.
- The scroll region is the inclusive row range `top...bottom` set by DECSTBM,
  the full screen by default.

## Cells and lines

- A `Cell` holds one Unicode scalar (a blank cell holds a space), a `width`
  (1; 2 for the leading half of a wide character; 0 for its trailing half) and
  `Attributes`. A multi-scalar grapheme (base + combining marks, emoji ZWJ
  sequences) is stored whole for its leading cell and read with
  `Line.character(at:)`.
- A `Line` has its `cells` and `isWrapped`, true when the text continues on
  the next line because of autowrap (a soft wrap). When a wide character does
  not fit in the last column and wraps, that column holds a padding cell
  (scalar U+0000): blank on screen, not part of the text, dropped by reflow.
- The text of a line (`Terminal.text(row:)`, `Line.text`) is its characters
  in order, trailing-half cells skipped, trailing spaces trimmed.
  `Terminal.screenLines` is the text of every screen row;
  `Terminal.scrollbackLines` the text of every scrollback line.
- Blank cells written by erase, insert, delete and scroll operations take the
  current background color and no other attribute (background color erase).

## Attributes

`Attributes` = foreground, background and underline colors, flags (`bold`,
`dim`, `italic`, `blink`, `inverse`, `hidden`, `strikethrough`, `overline`)
and an underline style (`none`, `single`, `double`, `curly`, `dotted`,
`dashed`). A color is `.default`, `.indexed(0…255)` or `.rgb(r, g, b)`.

## Palette

`Palette` = default foreground, background and cursor colors plus 256 indexed
colors: 0–15 below, 16–231 the 6×6×6 cube with levels 0, 95, 135, 175, 215,
255, and 232–255 grays `8 + 10 × (i − 232)`. OSC 4/10/11/12 change it and
OSC 104/110/111/112 restore these defaults.

| Entry | RGB | Entry | RGB |
|---|---|---|---|
| foreground | 217, 219, 227 | background | 30, 31, 38 |
| cursor | 242, 197, 114 | | |
| 0 black | 42, 43, 51 | 8 bright black | 95, 98, 112 |
| 1 red | 229, 100, 106 | 9 bright red | 255, 138, 143 |
| 2 green | 140, 203, 126 | 10 bright green | 174, 229, 158 |
| 3 yellow | 232, 194, 122 | 11 bright yellow | 247, 220, 155 |
| 4 blue | 108, 164, 236 | 12 bright blue | 149, 193, 250 |
| 5 magenta | 201, 138, 224 | 13 bright magenta | 227, 177, 242 |
| 6 cyan | 94, 196, 207 | 14 bright cyan | 146, 227, 234 |
| 7 white | 205, 208, 216 | 15 bright white | 244, 245, 248 |

## Terminal → host messages

`TerminalDelegate` receives what the terminal produces besides the screen:
`send` (reply bytes for the PTY: device attributes, status reports, color
queries), `titleDidChange`, `bell`, `workingDirectoryDidChange`,
`paletteDidChange` and `didRequestCompletionOf` (a completion request of
ATerm's zsh integration, OSC 6973). Every method has a default empty
implementation.

## Character width

Width 0: combining marks (general categories Mn, Me), format characters (Cf,
including ZWJ U+200D) except U+00AD, and Hangul medial/final jamo
U+1160–U+11FF. Width 2: East Asian Wide and Fullwidth characters (CJK, Hangul
syllables, fullwidth forms…) and characters with the Emoji_Presentation
property. Everything else: width 1. A width-0 character joins the grapheme of
the previous cell; a character following a ZWJ also joins it.
