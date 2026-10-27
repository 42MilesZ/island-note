import Foundation

/// Cross-service readback projection. Source-side edits are compared separately:
/// a serializer's equivalent spelling must never erase evidence of a local edit.
enum SyncFormatProjection {
    static func matches(local: String, remote: String) -> Bool {
        keys(local, remote: false) == keys(remote, remote: true)
    }

    static func keys(_ text: String, remote: Bool) -> [String] {
        // HTML line breaks may be returned between lines or in one physical line.
        // Keep the line boundary, but do not count serializer-added empty lines.
        // Flomo places a hard break just inside a closing bold delimiter. Move
        // the whitespace boundary outside it before parsing Markdown flanking.
        let closed = text.replacingOccurrences(of: #"(?i)(?<!\\)<br[\t ]*/?>(\*\*|__)(?=\r?\n|$)"#,
                                               with: "$1<br>", options: .regularExpression)
        let breaks = replacing(closed, pattern: #"(?i)(?<!\\)<br[\t ]*/?>"#) { _ in "\n" }
        let decoded = remote ? SyncDocument.fromFlomo(breaks) : breaks
        let softBreaks = decoded.replacingOccurrences(of: #"(?<!\\)\\\n"#, with: "\n", options: .regularExpression)
        let stableNesting = hasStableListIndentation(softBreaks)
        var indents: [Int] = []
        var records: [(kind: String, body: String)] = []
        for raw in SyncDocument.normalized(softBreaks).components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: #"[\t ]+$"#, with: "", options: .regularExpression)
            if line.isEmpty || line.range(of: #"^\s*(?:[-+*]|-\s+-|\d+[.)])\s*$"#, options: .regularExpression) != nil { continue }
            let kind: String
            let body: String
            if let item = listItem(line) {
                while let last = indents.last, last > item.indent { indents.removeLast() }
                if indents.last != item.indent { indents.append(item.indent) }
                // A missing parent is significant, even if the only item is indented.
                let level = stableNesting ? "depth:\(indents.count - 1)" : "indent:\(item.indent)"
                kind = "list:\(indents.first ?? 0):\(level):\(item.number.map(String.init) ?? "bullet")"
                body = item.body
            } else {
                indents = []
                let trimmed = line.replacingOccurrences(of: #"^ {1,3}(?=\S)"#, with: "", options: .regularExpression)
                if let range = trimmed.range(of: #"^#{1,6}[\t ]+"#, options: .regularExpression) {
                    kind = "heading:\(trimmed[range].prefix(while: { $0 == "#" }).count)"
                    body = String(trimmed[range.upperBound...])
                } else {
                    kind = "paragraph"
                    body = trimmed
                }
            }
            records.append((kind, body))
        }
        var result: [String] = []
        var index = 0
        while index < records.count {
            var end = index + 1
            if records[index].kind == "paragraph" {
                while end < records.count, records[end].kind == "paragraph" { end += 1 }
            }
            let bodies = records[index..<end].map(\.body)
            let keys = SyncInlineFormat.canonicalLines(bodies.joined(separator: "\n"))
            for offset in bodies.indices {
                // Unknown markup never vanishes or compares as two nil keys.
                let content = keys?.count == bodies.count ? keys![offset] :
                    (SyncInlineFormat.canonical(bodies[offset], normalizeNonBreakingSpaces: true) ?? "literal:" + bodies[offset])
                result.append(records[index + offset].kind + ":" + Data(content.utf8).base64EncodedString())
            }
            index = end
        }
        return result
    }

    struct ListItem {
        let indent: Int
        let number: Int?
        let marker: String
        let body: String
    }

    static func listItem(_ line: String) -> ListItem? {
        guard let expression = try? NSRegularExpression(pattern: #"^([\t ]*)([-+*]|[0-9]+[.)])[\t ]+(\S.*)$"#),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let source = line as NSString
        let indent = source.substring(with: match.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let marker = source.substring(with: match.range(at: 2))
        guard marker.count == 1 || Int(marker.dropLast()) != nil else { return nil }
        return ListItem(indent: indent, number: Int(marker.dropLast()), marker: marker,
                        body: source.substring(with: match.range(at: 3)))
    }

    /// Use stable list spelling and indentation without changing item order.
    static func stableLists(_ text: String) -> String {
        guard hasStableListIndentation(text) else { return text }
        var indents: [Int] = []
        return text.components(separatedBy: "\n").map { line in
            guard let item = listItem(line) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { indents = [] }
                return line
            }
            while let last = indents.last, last > item.indent { indents.removeLast() }
            if indents.last != item.indent { indents.append(item.indent) }
            let indentation = String(repeating: " ", count: (indents.first ?? 0) + 2 * (indents.count - 1))
            let marker = item.number == nil ? "-" : String(item.marker.dropLast()) + "."
            return indentation + marker + " " + item.body
        }.joined(separator: "\n")
    }

    /// Only normalize established two/four-space levels. Arbitrary greater
    /// indentation does not establish a child: a 3-space item after a 2-space
    /// child may still be its sibling in Markdown.
    static func hasStableListIndentation(_ text: String) -> Bool {
        var step: Int?
        var previous: Int?
        for line in text.components(separatedBy: "\n") {
            guard let item = listItem(line) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { step = nil; previous = nil }
                continue
            }
            guard let last = previous else {
                guard item.indent == 0 else { return false }
                previous = 0
                continue
            }
            if item.indent > last {
                let increment = item.indent - last
                if step == nil {
                    guard increment == 2 || increment == 4 else { return false }
                    step = increment
                }
                guard increment == step else { return false }
            }
            if let step, item.indent % step != 0 { return false }
            previous = item.indent
        }
        return true
    }

    static func hasUnstableOrderedNumbers(_ text: String) -> Bool {
        var expected: [Int: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let item = listItem(line) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { expected = [:] }
                continue
            }
            expected = expected.filter { $0.key <= item.indent }
            guard let number = item.number else { expected[item.indent] = nil; continue }
            guard number == (expected[item.indent] ?? 1) else { return true }
            expected[item.indent] = number + 1
        }
        return false
    }

    static func replacing(_ text: String, pattern: String, replacement: (NSTextCheckingResult) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(match))
        }
        return result
    }
}
