import AppKit

enum SyncDocument {
    static let limit = DocumentLimits.limit

    static func count(_ text: String) -> Int { DocumentLimits.count(text) }

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
        SyncFormatProjection.stableLists(normalized(withoutTrailingHTMLBreaks(text))).components(separatedBy: "\n").map { line in
            // Empty draft list items have been dropped by Flomo. Send them as
            // literal text so a later edit can still recover the placeholder.
            let literal: String
            if isEmptyDraftBullet(line) {
                let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
                literal = indentation + "\\" + line.dropFirst(indentation.count)
            } else {
                let heading = line.range(of: #"^ {0,3}#{1,6}[\t ]+"#, options: .regularExpression) != nil
                literal = heading ? "\\" + line.trimmingCharacters(in: .whitespaces) : line
            }
            // A tilde between word characters can be parsed as formatting and
            // deleted by Flomo. An existing Markdown escape already protects it.
            let protected = literal.replacingOccurrences(of: #"(?<=[\p{L}\p{N}_])~(?=[\p{L}\p{N}_])"#,
                                                         with: #"\\~"#, options: .regularExpression)
            return preserveStyledSeparators(protected) ?? preserveInlineSpaces(protected)
        }.joined(separator: "\n")
    }

    static func fromFlomo(_ text: String) -> String {
        normalized(text.components(separatedBy: "\n").map { line in
            let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
            let body = line.dropFirst(indentation.count)
            let escapedLiteral = body.hasPrefix("\\") && isEmptyDraftBullet(String(indentation) + String(body.dropFirst()))
            let escapedHeading = line.range(of: ##"^\\#{1,6}\s+"##, options: .regularExpression) != nil
            let decoded = escapedLiteral ? String(indentation) + String(body.dropFirst()) :
                (escapedHeading ? String(line.dropFirst()) : line)
            return unwrapBareURLs(in: decoded.replacingOccurrences(
                of: #"(?<=[\p{L}\p{N}_])\\~(?=[\p{L}\p{N}_])"#, with: "~", options: .regularExpression))
        }.joined(separator: "\n"))
    }

    /// Compare a local document with a decoded Flomo document without rewriting
    /// either one. Blank lines and empty draft bullets are cosmetic in the
    /// supported profile. Nonempty list content, indentation, and formatting
    /// still have to match. `remote` has already passed through `fromFlomo`.
    static func equivalent(local: String, remote: String) -> Bool {
        comparisonLines(local) == comparisonLines(remote)
    }

    /// Serializer compatibility is deliberately separate from source change
    /// detection: local hard breaks and spelling edits still count as edits.
    static func matchesReadback(local: String, remote: String) -> Bool {
        equivalent(local: local, remote: remote) || SyncFormatProjection.matches(local: local, remote: remote)
    }

    private static func preserveInlineSpaces(_ line: String) -> String {
        let prefix = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let body = String(line.dropFirst(prefix.count))
        let betweenTags = SyncFormatProjection.replacing(body, pattern: #"(?<=>) +(?=<)"#) { match in
            String(repeating: "&nbsp;", count: match.range.length)
        }
        return prefix + SyncFormatProjection.replacing(betweenTags, pattern: #"(?<=\S) {2,}(?=\S)"#) { match in
            " " + String(repeating: "&nbsp;", count: match.range.length - 1)
        }
    }

    private static func preserveStyledSeparators(_ line: String) -> String? {
        // Flomo drops whitespace-only HTML text nodes even when encoded as
        // &nbsp;. Borrow the separator into the preceding styled span instead.
        guard line.range(of: #"(?i)(?:</(?:mark|u|b|strong)>|\*\*|__)[\t ]+(?=<(?:mark|u|b|strong)>|\*\*|__)"#,
                         options: .regularExpression) != nil else { return nil }
        if let item = SyncFormatProjection.listItem(line), let html = SyncInlineFormat.html(item.body) {
            return String(repeating: " ", count: item.indent) + item.marker + " " + html
        }
        if let range = line.range(of: ##"^\\#{1,6}[\t ]+"##, options: .regularExpression),
           let html = SyncInlineFormat.html(String(line[range.upperBound...])) {
            return String(line[range]) + html
        }
        return SyncInlineFormat.html(line)
    }

    /// Reuse readback normalization when matching a merge unit. Its heading
    /// and list-parent scope are tracked separately by the merge algorithm.
    static func comparisonKey(_ text: String) -> String {
        comparisonLines(text).joined(separator: "\n")
    }

    /// Recognize the old transport's specific loss of word-internal tildes.
    /// This must only be used to repair an already pending upload after a
    /// version-checked readback, never to absorb arbitrary remote edits.
    static func isLegacyTransportLoss(local: String, remote: String) -> Bool {
        let left = comparisonLines(local)
        let right = comparisonLines(remote)
        guard left.count == right.count, left != right else { return false }
        var lostTilde = false
        for (expected, actual) in zip(left, right) {
            guard matchesWithLegacyTildeLoss(expected: expected, actual: actual, lostTilde: &lostTilde) else {
                return false
            }
        }
        return lostTilde
    }

    private static func comparisonLines(_ text: String) -> [String] {
        return normalized(withoutTrailingHTMLBreaks(text)).components(separatedBy: "\n")
            .filter { !$0.isEmpty && !isEmptyDraftBullet($0) }
            .map { line in
            var compared = line
            let indentation = compared.prefix(while: { $0 == " " || $0 == "\t" })
            let body = compared.dropFirst(indentation.count)
            if listKind(String(body)) != nil {
                compared = indentation.replacingOccurrences(of: "\t", with: "  ") + body
            } else if indentation.count <= 3, indentation.allSatisfy({ $0 == " " }),
                      body.range(of: #"^#{1,6}\s+"#, options: .regularExpression) == nil {
                // Flomo adds up to three spaces to ordinary paragraphs,
                // including paragraphs following a list. Their words and
                // order remain exact; nonempty list item nesting stays strict.
                // List nesting and four-space code indentation remain distinct.
                compared = String(body)
            }
            // Flomo removes escapes before a lone tilde in an iCloud path and
            // adds escapes to hyphens immediately following bold spans.
            compared = compared.replacingOccurrences(of: #"(?<=[\p{L}\p{N}_])\\~(?=[\p{L}\p{N}_])"#, with: "~", options: .regularExpression)
            compared = compared.replacingOccurrences(of: #"(?<=[^\\\s])\\-"#, with: "-", options: .regularExpression)
            // Flomo escapes an inline plus surrounded by spaces. It is literal
            // punctuation here; a leading escaped plus must remain distinct
            // from a list marker, and words on either side still match exactly.
            compared = compared.replacingOccurrences(of: #"(\S[ \t]+)\\\+(?=[ \t])"#, with: "$1+", options: .regularExpression)
            return unwrapBareURLs(in: compared)
        }
    }

    /// Flomo serializes paragraph-end blank space as growing runs of <br>.
    /// Ignore only unescaped tags at line ends; inline breaks, words, Markdown
    /// hard breaks and list nesting remain significant. Apply at the transport
    /// and comparison boundaries without rewriting the local document.
    private static func withoutTrailingHTMLBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?im)(?<!\\)(?:<br\s*/?>[\t ]*)+(?=\r?$)"#,
                                  with: "", options: .regularExpression)
    }

    private static func isEmptyDraftBullet(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:[-+*]|-\s+-|\d+[.)])\s*$"#, options: .regularExpression) != nil
    }

    private static func matchesWithLegacyTildeLoss(expected: String, actual: String, lostTilde: inout Bool) -> Bool {
        let left = Array(expected)
        let right = Array(actual)
        var i = 0
        var j = 0
        while i < left.count {
            if j < right.count, left[i] == right[j] { i += 1; j += 1; continue }
            if left[i] == "~", i > 0, i + 1 < left.count,
               isWordCharacter(left[i - 1]), isWordCharacter(left[i + 1]) {
                lostTilde = true
                i += 1
                continue
            }
            return false
        }
        return j == right.count
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private static func unwrapBareURLs(in line: String) -> String {
        // Only [the exact URL](the exact URL) is Flomo's automatic conversion
        // of a bare URL. Other Markdown links remain unsupported.
        let html = SyncFormatProjection.replacing(line, pattern: #"(?i)(?<!\\)<a href="(https?://[^"\n]+)"(?: rel="nofollow")?>([^<\n]*)</a>"#) { match in
            let source = line as NSString
            let target = SyncInlineFormat.decodeEntities(source.substring(with: match.range(at: 1)))
            let label = SyncInlineFormat.decodeEntities(source.substring(with: match.range(at: 2)))
            return label == target ? target : source.substring(with: match.range)
        }
        let pattern = #"(?<!\\)\[(https?://[^\]\n]+)\]\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return html }
        let source = html as NSString
        var result = html
        for match in expression.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let label = source.substring(with: match.range(at: 1))
            let targetStart = NSMaxRange(match.range)
            let target = label + ")"
            guard source.substring(from: targetStart).hasPrefix(target),
                  let range = Range(NSRange(location: match.range.location, length: match.range.length + (target as NSString).length), in: result) else { continue }
            result.replaceSubrange(range, with: label)
        }
        return result
    }

    static func transferFits(_ text: String) -> Bool {
        let encoded = toFlomo(text)
        // Include the blank separators its editor may insert between list items.
        let listHeadroom = encoded.components(separatedBy: "\n").filter(isListLine).count * 2
        return count(encoded) + listHeadroom <= limit
    }

    static func issue(in text: String) -> String? {
        if count(text) > limit { return L10n.tr("The document exceeds 30,000 characters. Shorten it before syncing.") }
        if toFlomo(text).isEmpty { return L10n.tr("The document is empty. Empty notes are not sent to Flomo.") }
        let patterns: [(String, String)] = [
            (#"(?m)^\s*(?:[-+*]|\d+[.)])\s+\[[ xX]\]"#, L10n.tr("Checkboxes")),
            (#"(?m)^\s*(?:`{3,}|~{3,})"#, L10n.tr("Code blocks")),
            (#"(?m)^(?: {4,}|\t)(?![-+*]\s|\d+[.)]\s)\S"#, L10n.tr("Code blocks or deeply indented text")),
            (#"(?m)^ {0,3}>"#, L10n.tr("Blockquotes")),
            (#"!?\[[^\]\n]+\]\([^\n]*\)|\[\[|(?m)^ {0,3}\[[^\]\n]+\]:"#, L10n.tr("Markdown links and images")),
            (#"(?m)^\s*\|?\s*:?-{3,}:?\s*\|(?:\s*:?-{3,}:?\s*\|?)+\s*$"#, L10n.tr("Tables")),
            (#"(?<!\\)~~[^\n]+?~~|(?<!\\)`[^`\n]+`"#, L10n.tr("Inline code and strikethrough")),
            (#"(?<![\\*])\*(?![\s*])[^*\n]+(?<!\s)\*(?!\*)|(?<![\\\w_])_(?![\s_])[^_\n]+(?<!\s)_(?![\w_])"#, L10n.tr("Italic formatting")),
            (#"(?<![\\*])\*{3}(?=\S)[^\n]+?(?<=\S)\*{3}|(?<![\\\w_])_{3}(?=\S)[^\n]+?(?<=\S)_{3}(?![\w_])"#, L10n.tr("Italic formatting")),
            (#"(?im)(?<!\\)<(?!/?(?:mark|u|b|strong)[\t ]*>|br[\t ]*/?>)/?[a-z][^>]*>"#, L10n.tr("Unsupported HTML")),
            (#"(?m)^ {0,3}(?:={3,}|(?:-[\t ]*){3,}|(?:\*[\t ]*){3,}|(?:_[\t ]*){3,})[\t ]*$"#, L10n.tr("Setext headings and horizontal rules")),
        ]
        for (pattern, name) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return L10n.format("%@ are not supported by Flomo sync. Remove that syntax to resume. Your local text is still saved.", L10n.tr(name))
        }
        if SyncFormatProjection.hasUnstableOrderedNumbers(text) {
            return L10n.tr("Flomo renumbers ordered lists. Use consecutive numbers starting at 1 before syncing. Your local text is still saved.")
        }
        if !SyncFormatProjection.hasStableListIndentation(text) {
            return L10n.tr("Use consistent 2- or 4-space list indentation before syncing. Your local text is still saved.")
        }
        return nil
    }

    static func allowsEdit(current: String, range: NSRange, replacement: String) -> Bool {
        guard let swiftRange = Range(range, in: current) else { return false }
        let nextCount = count(current.replacingCharacters(in: swiftRange, with: replacement))
        return nextCount <= limit || nextCount < count(current)
    }
}
