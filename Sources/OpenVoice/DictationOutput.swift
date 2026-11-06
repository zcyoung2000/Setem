import Foundation

enum DictationOutput {
    static let removeTrailingPunctuationKey = "removeTrailingPunctuation"

    /// Apply once at the insertion boundary; recognition and preview retain their original text.
    static func textForInsertion(_ text: String, defaults: UserDefaults = .standard) -> String {
        guard defaults.bool(forKey: removeTrailingPunctuationKey) else { return text }
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        guard end > text.startIndex else { return text }
        let last = text.index(before: end)
        guard text[last].unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) else { return text }
        var output = text
        output.removeSubrange(last..<end)
        // A punctuation-only result must not paste whitespace or send an empty message.
        return output.allSatisfy(\.isWhitespace) ? "" : output
    }
}
