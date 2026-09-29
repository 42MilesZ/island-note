import AppKit

enum SyncDocument {
    static let limit = 30_000

    static func count(_ text: String) -> Int { text.unicodeScalars.count }

    static func normalized(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        for line in lines {
            var trimmed = line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            // Two trailing spaces are a Markdown hard break, not cosmetic whitespace.
            if !trimmed.isEmpty, line.hasSuffix("  "),
               trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) == nil { trimmed += "  " }
            if trimmed.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(trimmed)
        }
        while output.last?.isEmpty == true { output.removeLast() }
        // Flomo's editor emits loose lists. Tight/loose spacing has the same
        // meaning in the supported profile, so it must not trigger sync loops.
        return output.enumerated().compactMap { index, line in
            if line.isEmpty, index > 0, index + 1 < output.count,
               let previousKind = listKind(output[index - 1]), previousKind == listKind(output[index + 1]) { return nil }
            return line
        }.joined(separator: "\n")
    }

    private static func listKind(_ line: String) -> String? {
        if line.range(of: #"^\s*[-+*]\s+"#, options: .regularExpression) != nil { return "bullet" }
        if line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) != nil { return "ordered" }
        return nil
    }

    private static func isListLine(_ line: String) -> Bool { listKind(line) != nil }

    static func toFlomo(_ text: String) -> String {
        // Flomo removes unsupported HTML heading elements on a manual save.
        // Escape only the leading marker so headings remain ordinary text there.
        normalized(text).components(separatedBy: "\n").map { line in
            // A list item whose only content is a dash was dropped by Flomo.
            // Send it as literal text instead of a list item.
            if line == "- -" { return "\\- -" }
            return line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil ? "\\" + line : line
        }.joined(separator: "\n")
    }

    static func fromFlomo(_ text: String) -> String {
        normalized(text.components(separatedBy: "\n").map { line in
            if line == "\\- -" { return "- -" }
            let heading = line.range(of: ##"^\\#{1,6}\s+"##, options: .regularExpression) != nil
                ? String(line.dropFirst()) : line
            return unwrapBareURLs(in: heading)
        }.joined(separator: "\n"))
    }

    /// Compare a local document with a decoded Flomo document without rewriting
    /// either one. Flomo adds some paragraph separators and changes harmless
    /// Markdown escapes; missing words, list items, or local paragraph breaks
    /// still differ. `remote` should already have passed through `fromFlomo`.
    static func equivalent(local: String, remote: String) -> Bool {
        let left = comparisonLines(local)
        let right = comparisonLines(remote)
        var i = 0
        var j = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] { i += 1; j += 1; continue }
            // An extra single blank line in Flomo is a known editor artifact
            // after headings or between ordinary text lines. Never discard a
            // blank line from the local source.
            if right[j].isEmpty, j > 0, j + 1 < right.count,
               !right[j - 1].isEmpty, !right[j + 1].isEmpty,
               isHeading(right[j - 1]) ||
               (listKind(right[j - 1]) == nil && listKind(right[j + 1]) == nil) {
                j += 1
                continue
            }
            return false
        }
        return i == left.count && j == right.count
    }

    private static func comparisonLines(_ text: String) -> [String] {
        normalized(text).components(separatedBy: "\n").map { line in
            var compared = line
            let indentation = compared.prefix(while: { $0 == " " || $0 == "\t" })
            let body = compared.dropFirst(indentation.count)
            if listKind(String(body)) != nil {
                compared = indentation.replacingOccurrences(of: "\t", with: "  ") + body
            }
            // Flomo removes escapes before a lone tilde in an iCloud path and
            // adds escapes to hyphens immediately following bold spans.
            compared = compared.replacingOccurrences(of: #"(?<=[\p{L}\p{N}_])\\~(?=[\p{L}\p{N}_])"#, with: "~", options: .regularExpression)
            compared = compared.replacingOccurrences(of: #"(?<=[^\\\s])\\-"#, with: "-", options: .regularExpression)
            return unwrapBareURLs(in: compared)
        }
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil
    }

    private static func unwrapBareURLs(in line: String) -> String {
        // Only [the exact URL](the exact URL) is Flomo's automatic conversion
        // of a bare URL. Other Markdown links remain unsupported.
        let pattern = #"\[(https?://[^\]\n]+)\]\((https?://[^)\n]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return line }
        let source = line as NSString
        var result = line
        for match in expression.matches(in: line, range: NSRange(location: 0, length: source.length)).reversed() {
            let label = source.substring(with: match.range(at: 1))
            let target = source.substring(with: match.range(at: 2))
            guard label == target, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: target)
        }
        return result
    }

    static func merging(local: String, remote: String) -> String {
        let left = normalized(local)
        let right = normalized(remote)
        if left == right || right.isEmpty { return left }
        if left.isEmpty { return right }
        return left + "\n\n" + right
    }

    static func transferFits(_ text: String) -> Bool {
        let encoded = toFlomo(text)
        // Include the blank separators its editor may insert between list items.
        let listHeadroom = encoded.components(separatedBy: "\n").filter(isListLine).count * 2
        return count(encoded) + listHeadroom <= limit
    }

    static func issue(in text: String) -> String? {
        if count(text) > limit { return "The document exceeds 30,000 characters. Shorten it before syncing." }
        if normalized(text).isEmpty { return "The document is empty. Empty notes are not sent to Flomo." }
        let patterns: [(String, String)] = [
            (#"(?m)^\s*(?:[-+*]|\d+[.)])\s+\[[ xX]\]"#, "Checkboxes"),
            (#"(?m)^\s*(?:`{3,}|~{3,})"#, "Code blocks"),
            (#"(?m)^(?: {4,}|\t)(?![-+*]\s|\d+[.)]\s)\S"#, "Code blocks or deeply indented text"),
            (#"(?m)^ {0,3}>"#, "Blockquotes"),
            (#"!?\[[^\]\n]+\]\([^\n]*\)|\[\[|(?m)^ {0,3}\[[^\]\n]+\]:"#, "Markdown links and images"),
            (#"(?m)^\s*\|?\s*:?-{3,}:?\s*\|(?:\s*:?-{3,}:?\s*\|?)+\s*$"#, "Tables"),
        ]
        for (pattern, name) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return "\(name) are not supported by Flomo sync. Remove that syntax to resume. Your local text is still saved."
        }
        return nil
    }

    static func allowsEdit(current: String, range: NSRange, replacement: String) -> Bool {
        guard let swiftRange = Range(range, in: current) else { return false }
        let nextCount = count(current.replacingCharacters(in: swiftRange, with: replacement))
        return nextCount <= limit || nextCount < count(current)
    }
}
