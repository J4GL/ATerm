import AppKit
import CoreText

/// The four faces of the terminal font and the cell metrics derived from them.
struct FontSet {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    /// Advance of `M` and line height, rounded up to whole device pixels.
    let cellSize: NSSize
    /// Distance from the top of a cell to the text baseline.
    let baseline: CGFloat
    /// Distance from the baseline down to the underline.
    let underlineOffset: CGFloat
    /// Distance from the baseline up to the strikethrough.
    let strikethroughOffset: CGFloat
    let lineThickness: CGFloat

    init(name: String?, size: CGFloat, scale: CGFloat) {
        let base = name.flatMap { NSFont(name: $0, size: size) } ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let boldBase: NSFont
        if name == nil {
            boldBase = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        } else {
            boldBase = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        regular = base as CTFont
        bold = boldBase as CTFont
        italic = FontSet.italicVariant(of: regular)
        boldItalic = FontSet.italicVariant(of: bold)

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        var character: UniChar = 0x4D  // M
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(regular, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let width = ceil(advance.width * scale) / scale
        let height = ceil((ascent + descent + leading) * scale) / scale
        cellSize = NSSize(width: width, height: height)
        baseline = ((ascent + (height - ascent - descent) / 2) * scale).rounded() / scale
        lineThickness = max((CTFontGetUnderlineThickness(regular) * scale).rounded(), 1) / scale
        underlineOffset = max((-CTFontGetUnderlinePosition(regular) * scale).rounded() / scale, lineThickness)
        strikethroughOffset = ((CTFontGetXHeight(regular) / 2) * scale).rounded() / scale
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    /// The italic face, or a slanted copy when the family has none.
    private static func italicVariant(of font: CTFont) -> CTFont {
        if let italic = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) {
            return italic
        }
        var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, 0, &slant, nil)
    }
}
