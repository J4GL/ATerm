import Foundation

/// Finds URLs in terminal text for ⌘-click. See SPEC/app/edit.md (APP-EDIT-003).
enum LinkDetector {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?|ftp|file)://[^\s<>"'`]+|mailto:[^\s<>"'`]+"#)
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", "]", "}", ">"]

    /// The link covering the UTF-16 offset `offset` of `text`, if any.
    static func link(in text: String, atUTF16Offset offset: Int) -> URL? {
        let string = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var candidate = string.substring(with: match.range)
            // Sentence punctuation is not part of the link; ")" only when it closes nothing.
            while let last = candidate.last {
                if trailingPunctuation.contains(last) {
                    candidate.removeLast()
                } else if last == ")" && candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count {
                    candidate.removeLast()
                } else {
                    break
                }
            }
            let range = NSRange(location: match.range.location, length: (candidate as NSString).length)
            if NSLocationInRange(offset, range) { return URL(string: candidate) }
        }
        return nil
    }
}
