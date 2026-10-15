import Foundation

/// A conservative, editable merge of two decoded note bodies. Local lines keep
/// their order and spelling; exact remote additions appear beside their nearest
/// shared lines. This does not guess whether two differently worded ideas agree.
struct SyncMerge: Sendable {
    let text: String

    private struct Key: Hashable {
        let section: [String]
        let text: String
    }

    private struct Piece {
        let raw: String
        let key: Key
    }

    private struct Line {
        let raw: String
        let section: [String]
        let pieces: [Piece]
    }

    static func combine(local: String, remote: String) -> SyncMerge {
        let left = SyncDocument.normalized(local)
        let right = SyncDocument.normalized(remote)
        if right.isEmpty || left == right { return SyncMerge(text: left) }
        if left.isEmpty { return SyncMerge(text: right) }

        let localLines = lines(in: left)
        let remoteLines = lines(in: right)
        var sectionIDs: [[String]: Int] = [:]
        func comparisonText(_ lines: [Line]) -> String {
            lines.map { line in
                let id: Int
                if let existing = sectionIDs[line.section] {
                    id = existing
                } else {
                    id = sectionIDs.count
                    sectionIDs[line.section] = id
                }
                // Encoding keeps U+2029 and other literal characters from
                // becoming extra lines in SyncDiff's transport representation.
                return "\(id):" + Data(line.raw.utf8).base64EncodedString()
            }.joined(separator: "\n")
        }
        let comparedLeft = comparisonText(localLines)
        let comparedRight = comparisonText(remoteLines)
        let diff = SyncDiff.compare(left: comparedLeft, right: comparedRight)

        // A multiset, rather than a set, protects repetition present in one
        // source. Equal diff regions claim their copies before moved text does.
        var available: [Key: Int] = [:]
        for line in localLines {
            for piece in line.pieces { available[piece.key, default: 0] += 1 }
        }
        var localCursor = 0
        var remoteCursor = 0
        for block in diff.blocks {
            if block.kind == .equal {
                for line in remoteLines[remoteCursor..<(remoteCursor + block.rightLineCount)] {
                    for piece in line.pieces {
                        if let count = available[piece.key], count > 0 {
                            available[piece.key] = count - 1
                        }
                    }
                }
            }
            localCursor += block.leftLineCount
            remoteCursor += block.rightLineCount
        }

        var output: [String] = []
        var activeHeadings = Array(repeating: "", count: 6)
        func appendOutput(_ raw: String) {
            output.append(raw)
            if let level = headingLevel(raw) {
                activeHeadings[level - 1] = raw
                if level < 6 {
                    for index in level..<6 { activeHeadings[index] = "" }
                }
            }
        }
        func ensureSection(_ target: [String], beforeHeading level: Int?) {
            let active = activeHeadings.filter { !$0.isEmpty }
            if active == target { return }
            var shared = 0
            while shared < min(active.count, target.count), active[shared] == target[shared] {
                shared += 1
            }
            // The heading about to be emitted will close the active child.
            if level != nil, shared == target.count { return }
            guard !target.isEmpty else { return }
            let start = shared == target.count ? target.count - 1 : shared
            for heading in target[start...] { appendOutput(heading) }
        }
        func appendScoped(_ raw: String, section: [String]) {
            if raw.isEmpty {
                appendOutput("")
                return
            }
            let level = headingLevel(raw)
            if section.isEmpty, level == nil,
               activeHeadings.contains(where: { !$0.isEmpty }) {
                // Root prose belongs before the first heading, even if a
                // reordered remote section was just emitted at this cursor.
                let insertion = output.firstIndex(where: { headingLevel($0) != nil }) ?? output.count
                output.insert(raw, at: insertion)
                return
            }
            ensureSection(section, beforeHeading: level)
            appendOutput(raw)
        }
        localCursor = 0
        remoteCursor = 0
        for block in diff.blocks {
            let localEnd = localCursor + block.leftLineCount
            let remoteEnd = remoteCursor + block.rightLineCount
            for line in localLines[localCursor..<localEnd] {
                appendScoped(line.raw, section: line.section)
            }
            if block.kind == .changed {
                var extra: [(raw: String, section: [String])] = []
                for line in remoteLines[remoteCursor..<remoteEnd] {
                    if line.raw.isEmpty {
                        extra.append(("", line.section))
                        continue
                    }
                    var retained = ""
                    for piece in line.pieces {
                        if let count = available[piece.key], count > 0 {
                            available[piece.key] = count - 1
                        } else {
                            retained += piece.raw
                        }
                    }
                    if !retained.isEmpty {
                        // Keep indentation and Markdown hard breaks when an
                        // entire structural line survives. Only a partially
                        // retained prose sentence needs edge-space cleanup.
                        extra.append((retained == line.raw ? retained :
                                      retained.trimmingCharacters(in: .whitespaces), line.section))
                    }
                }
                if let first = extra.firstIndex(where: { !$0.raw.isEmpty }),
                   let last = extra.lastIndex(where: { !$0.raw.isEmpty }) {
                    // Keep a source paragraph separator if it borders the
                    // surviving addition, but discard orphaned blank lines.
                    let start = first > 0 ? first - 1 : first
                    let end = last + 1 < extra.count ? last + 1 : last
                    let retained = Array(extra[start...end])
                    if block.leftLineCount > 0 && output.last?.isEmpty == false && retained.first?.raw.isEmpty == false {
                        appendOutput("")
                    }
                    for item in retained {
                        if item.raw.isEmpty {
                            appendOutput("")
                            continue
                        }
                        appendScoped(item.raw, section: item.section)
                    }
                }
            }
            localCursor = localEnd
            remoteCursor = remoteEnd
        }
        return SyncMerge(text: SyncDocument.normalized(output.joined(separator: "\n")))
    }

    private static func lines(in text: String) -> [Line] {
        var headings = Array(repeating: "", count: 6)
        return groupedLines(in: text).map { raw in
            if let level = headingLevel(raw) {
                let parent = Array(headings.prefix(level - 1).filter { !$0.isEmpty })
                let piece = Piece(raw: raw, key: Key(section: parent, text: raw))
                headings[level - 1] = raw
                if level < 6 {
                    for index in level..<6 { headings[index] = "" }
                }
                return Line(raw: raw, section: parent, pieces: [piece])
            }
            let section = headings.filter { !$0.isEmpty }
            if raw.isEmpty { return Line(raw: raw, section: section, pieces: []) }
            let segments = isStructural(raw) || hasInlineMarkdown(raw) ? [raw] : sentences(in: raw)
            let pieces = segments.map { segment in
                Piece(raw: segment, key: Key(section: section,
                                             text: segment.trimmingCharacters(in: .whitespaces)))
            }
            return Line(raw: raw, section: section, pieces: pieces)
        }
    }

    private static func groupedLines(in text: String) -> [String] {
        let physical = text.components(separatedBy: "\n")
        var result: [String] = []
        var cursor = 0
        while cursor < physical.count {
            guard let parentIndent = listIndent(physical[cursor]) else {
                result.append(physical[cursor])
                cursor += 1
                continue
            }
            var end = cursor + 1
            while end < physical.count {
                if physical[end].isEmpty {
                    guard end + 1 < physical.count,
                          indentation(physical[end + 1]) > parentIndent else { break }
                    end += 1
                    continue
                }
                guard indentation(physical[end]) > parentIndent else { break }
                end += 1
            }
            result.append(physical[cursor..<end].joined(separator: "\n"))
            cursor = end
        }
        return result
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listIndent(_ line: String) -> Int? {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let bullet = body.hasPrefix("- ") || body.hasPrefix("+ ") || body.hasPrefix("* ")
        let ordered = String(body).range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        return bullet || ordered ? indentation(line) : nil
    }

    private static func headingLevel(_ line: String) -> Int? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return count
    }

    private static func isStructural(_ line: String) -> Bool {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return true }
        if body.hasPrefix("- ") || body.hasPrefix("+ ") || body.hasPrefix("* ") ||
            body.hasPrefix(">") || body.hasPrefix("```") || body.hasPrefix("~~~") { return true }
        return String(body).range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    private static func hasInlineMarkdown(_ line: String) -> Bool {
        // A partial sentence from a marked-up line can leave an unmatched
        // opener or closer. The whole line remains available for exact dedup.
        line.hasSuffix("  ") || line.contains { "*_'`[]\\~<>".contains($0) }
    }

    /// Only punctuation-delimited, exactly equal sentences can be coalesced.
    /// A line with no sentence boundary stays one indivisible unit.
    private static func sentences(in line: String) -> [String] {
        let characters = Array(line)
        var result: [String] = []
        var start = 0
        for index in characters.indices {
            let mark = characters[index]
            let endsSentence = "。！？".contains(mark) ||
                (".!?".contains(mark) &&
                 (index + 1 == characters.count || characters[index + 1].isWhitespace))
            guard endsSentence else { continue }
            var end = index + 1
            while end < characters.count && characters[end].isWhitespace { end += 1 }
            result.append(String(characters[start..<end]))
            start = end
        }
        if start < characters.count { result.append(String(characters[start...])) }
        return result.isEmpty ? [line] : result
    }
}
