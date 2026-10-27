import Foundation

/// A deliberately small inline grammar for sync comparisons. Parsing does not
/// render HTML, load URLs, or guess how unsupported Markdown will be displayed.
enum SyncInlineFormat {
    /// Equal keys require equal text and equal supported styles at every run.
    /// A nil key means that callers must keep their conservative comparison.
    static func canonical(_ text: String, normalizeNonBreakingSpaces: Bool = false) -> String? {
        guard !text.contains("\n"), !text.contains("\r") else { return nil }
        var parser = Parser(text, normalizeNonBreakingSpaces: normalizeNonBreakingSpaces)
        guard let runs = parser.parse(),
              let data = try? JSONEncoder().encode(comparisonRuns(runs)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Serialize the supported inline grammar without relying on Flomo's
    /// Markdown delimiter conversion. Text is escaped exactly once. Whitespace
    /// between adjacent styles belongs to a styled node because Flomo drops
    /// standalone whitespace-only nodes, including nonbreaking-space nodes.
    static func html(_ text: String) -> String? {
        var parser = Parser(text, normalizeNonBreakingSpaces: false)
        guard var runs = parser.parse() else { return nil }
        for index in runs.indices where runs[index].style == 0 && runs[index].text.allSatisfy(isWhitespace) {
            if index > 0, runs[index - 1].style != 0 {
                runs[index - 1].text += runs[index].text
                runs[index].text = ""
            } else if index + 1 < runs.count, runs[index + 1].style != 0 {
                runs[index + 1].text = runs[index].text + runs[index + 1].text
                runs[index].text = ""
            }
        }
        return runs.filter { !$0.text.isEmpty }.map { run in
            let tags = [(1, "strong"), (2, "mark"), (4, "u")].filter { run.style & $0.0 != 0 }.map(\.1)
            return tags.map { "<\($0)>" }.joined()
                + escapeHTMLText(run.text)
                + tags.reversed().map { "</\($0)>" }.joined()
        }.joined()
    }

    /// Preserve styles across physical soft/hard line boundaries. The caller
    /// supplies already-classified paragraph bodies, never list/heading markers.
    static func canonicalLines(_ text: String) -> [String]? {
        var parser = Parser(text, normalizeNonBreakingSpaces: true)
        guard let runs = parser.parse() else { return nil }
        var lines: [[Run]] = [[]]
        for run in comparisonRuns(runs) {
            let pieces = run.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty { lines[lines.count - 1].append(Run(text: piece, style: run.style)) }
            }
        }
        return lines.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
    }

    /// Whether the adjacent styled text owns a space has no visible effect.
    /// Keep the whitespace itself exact so missing gaps and collapsed spaces
    /// still fail verification after moving them inside a transport style tag.
    private static func comparisonRuns(_ runs: [Run]) -> [Run] {
        var compared: [Run] = []
        for run in runs {
            for character in run.text {
                let style = isWhitespace(character) ? 0 : run.style
                if compared.last?.style == style {
                    compared[compared.count - 1].text.append(character)
                } else {
                    compared.append(Run(text: String(character), style: style))
                }
            }
        }
        return compared
    }

    private static func escapeHTMLText(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            case " ", "\u{00a0}": escaped += "&nbsp;"
            case "\t": escaped += "&#9;"
            // The endpoint also accepts Markdown. Entity text must remain
            // literal even when this fragment contains no surrounding tag.
            case "*", "_", "`", "~", "[", "]", "#", "\\":
                escaped += "&#\(character.unicodeScalars.first!.value);"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Decode text entities only. Callers must not reinterpret the result as
    /// HTML: &lt;b&gt; is literal text, whereas <b> is a style delimiter.
    static func decodeEntities(_ text: String) -> String {
        let characters = Array(text)
        var index = 0
        var result = ""
        while index < characters.count {
            if let entity = entity(at: index, in: characters) {
                result += entity.text
                index = entity.end
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private struct Run: Encodable {
        var text: String
        let style: Int

        // Arrays give the key a stable, unambiguous representation without
        // depending on JSON dictionary ordering or reserving text characters.
        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(style)
            try container.encode(text)
        }
    }

    private enum Frame: Equatable {
        case markdown(Character)
        case html(String)

        var style: Int {
            switch self {
            case .markdown: return 1
            case .html(let tag):
                switch tag {
                case "b", "strong": return 1
                case "mark": return 2
                case "u": return 4
                default: return 0
                }
            }
        }
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var stack: [Frame] = []
        var runs: [Run] = []
        let normalizeNonBreakingSpaces: Bool

        init(_ text: String, normalizeNonBreakingSpaces: Bool) {
            characters = Array(text)
            self.normalizeNonBreakingSpaces = normalizeNonBreakingSpaces
        }

        mutating func parse() -> [Run]? {
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count,
                   SyncInlineFormat.isEscapable(characters[index + 1]) {
                    append(String(characters[index + 1]))
                    index += 2
                } else if character == "&", let entity = SyncInlineFormat.entity(at: index, in: characters) {
                    append(entity.text)
                    index = entity.end
                } else if character == "<", index + 1 < characters.count,
                          characters[index + 1] == "/" || characters[index + 1].isLetter {
                    guard parseTag() else { return nil }
                } else if character == "*" || character == "_" {
                    guard parseMarkdownDelimiter(character) else { return nil }
                } else if character == "`" || character == "~" {
                    // Inline code and strikethrough are outside this profile.
                    // A lone tilde inside a word is ordinary path punctuation.
                    if character == "~", index > 0, index + 1 < characters.count,
                       characters[index - 1] != "~", characters[index + 1] != "~" {
                        append("~")
                        index += 1
                    } else { return nil }
                } else {
                    append(String(character))
                    index += 1
                }
            }
            return stack.isEmpty ? runs : nil
        }

        mutating func append(_ text: String) {
            let text = normalizeNonBreakingSpaces ? text.replacingOccurrences(of: "\u{00a0}", with: " ") : text
            let style = stack.reduce(0) { $0 | $1.style }
            if runs.last?.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, style: style))
            }
        }

        mutating func parseTag() -> Bool {
            guard let end = characters[index...].firstIndex(of: ">") else { return false }
            var body = String(characters[(index + 1)..<end])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let closing = body.hasPrefix("/")
            if closing { body.removeFirst() }
            guard ["b", "strong", "mark", "u"].contains(body) else { return false }
            let frame = Frame.html(body)
            if closing {
                guard stack.last == frame else { return false }
                stack.removeLast()
            } else {
                stack.append(frame)
            }
            index = end + 1
            return true
        }

        mutating func parseMarkdownDelimiter(_ marker: Character) -> Bool {
            var end = index
            while end < characters.count, characters[end] == marker { end += 1 }
            let length = end - index
            let before = index > 0 ? characters[index - 1] : nil
            let after = end < characters.count ? characters[end] : nil
            let beforeWhitespace = before.map(SyncInlineFormat.isWhitespace) ?? true
            let afterWhitespace = after.map(SyncInlineFormat.isWhitespace) ?? true
            let beforePunctuation = before.map(SyncInlineFormat.isPunctuation) ?? false
            let afterPunctuation = after.map(SyncInlineFormat.isPunctuation) ?? false
            let leftFlanking = !afterWhitespace && (!afterPunctuation || beforeWhitespace || beforePunctuation)
            let rightFlanking = !beforeWhitespace && (!beforePunctuation || afterWhitespace || afterPunctuation)
            let canOpen = marker == "*" ? leftFlanking : leftFlanking && (!rightFlanking || beforePunctuation)
            let canClose = marker == "*" ? rightFlanking : rightFlanking && (!leftFlanking || afterPunctuation)

            // Intraword underscores are literal Markdown text, including the
            // double underscore in names such as a__b__c.
            if marker == "_", !canOpen, !canClose {
                append(String(repeating: String(marker), count: length))
                index = end
                return true
            }
            guard length == 2 else { return false }
            let frame = Frame.markdown(marker)
            if stack.last == frame, canClose {
                stack.removeLast()
            } else if !stack.contains(frame), canOpen {
                stack.append(frame)
            } else { return false }
            index = end
            return true
        }
    }

    private static let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    private static func isEscapable(_ character: Character) -> Bool { escapable.contains(character) }
    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }
    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.first.map {
            CharacterSet.punctuationCharacters.union(.symbols).contains($0)
        } ?? false
    }

    private static let namedEntities: [String: String] = {
        let bundle: Bundle
        #if SWIFT_PACKAGE
        if let resources = Bundle.main.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("IslandNote_IslandNote.bundle")) {
            bundle = bundled
        } else { bundle = .module }
        #else
        bundle = .main
        #endif
        if let url = bundle.url(forResource: "HTMLNamedEntities", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let entities = try? JSONDecoder().decode([String: String].self, from: data) {
            return entities
        }
        // The common transport entities remain usable if a damaged or older
        // app bundle is missing the complete semicolon-terminated HTML5 table.
        return ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
    }()

    private static func entity(at start: Int, in characters: [Character]) -> (text: String, end: Int)? {
        guard characters[start] == "&" else { return nil }
        let limit = min(characters.count, start + 34)
        guard start + 1 < limit,
              let end = characters[(start + 1)..<limit].firstIndex(of: ";") else { return nil }
        let body = String(characters[(start + 1)..<end])
        if let decoded = namedEntities[body] { return (decoded, end + 1) }
        guard body.hasPrefix("#") else { return nil }
        let hexadecimal = body.hasPrefix("#x") || body.hasPrefix("#X")
        let digits = body.dropFirst(hexadecimal ? 2 : 1)
        guard !digits.isEmpty,
              digits.allSatisfy({ character in
                  character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
                      (48...57).contains($0.value) || hexadecimal && ((65...70).contains($0.value) || (97...102).contains($0.value))
                  }
              }),
              let value = UInt32(digits, radix: hexadecimal ? 16 : 10),
              value != 0, let scalar = UnicodeScalar(value),
              value == 9 || !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        return (String(scalar), end + 1)
    }
}
