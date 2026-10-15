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
        var tree: ListTree? = nil
    }

    static func combine(local: String, remote: String) -> SyncMerge {
        let left = SyncDocument.normalized(local)
        let right = SyncDocument.normalized(remote)
        if right.isEmpty || left == right { return SyncMerge(text: left) }
        if left.isEmpty { return SyncMerge(text: right) }

        let (localLines, remoteLines) = matchingListTrees(local: lines(in: left), remote: lines(in: right))
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
            return bodyLine(raw, section: section)
        }
    }

    private static func bodyLine(_ raw: String, section: [String]) -> Line {
        if let tree = ListTree.parse(raw) {
            return Line(raw: raw, section: section,
                        pieces: [Piece(raw: raw, key: Key(section: section, text: tree.canonical))], tree: tree)
        }
        let segments = isStructural(raw) || hasInlineMarkdown(raw) ? [raw] : sentences(in: raw)
        let pieces = segments.map { segment in
            Piece(raw: segment, key: Key(section: section,
                                         text: SyncDocument.comparisonKey(segment.trimmingCharacters(in: .whitespaces))))
        }
        return Line(raw: raw, section: section, pieces: pieces)
    }

    /// Match list roots within the same heading, then merge their children by
    /// parent identity. A one-space and two-space child are the same depth;
    /// the same words under different parents remain separate entries.
    private static func matchingListTrees(local: [Line], remote: [Line]) -> ([Line], [Line]) {
        var left = local, right = remote
        var exact: [Key: [Int]] = [:], exactCursor: [Key: Int] = [:]
        for (index, line) in local.enumerated() {
            if let tree = line.tree { exact[Key(section: line.section, text: tree.canonical), default: []].append(index) }
        }
        // Reserve exact trees first, including moved trees. Pairing repeated
        // parent labels only by occurrence would mix up their distinct children.
        var pairs: [Int: Int] = [:], claimed = Set<Int>()
        for (index, line) in remote.enumerated() {
            guard let tree = line.tree else { continue }
            let key = Key(section: line.section, text: tree.canonical)
            let occurrence = exactCursor[key, default: 0]
            exactCursor[key] = occurrence + 1
            if let candidates = exact[key], occurrence < candidates.count {
                pairs[index] = candidates[occurrence]; claimed.insert(candidates[occurrence])
            }
        }
        var localRoots: [Key: [Int]] = [:], remoteRoots: [Key: [Int]] = [:]
        for (index, line) in local.enumerated() where !claimed.contains(index) {
            if let tree = line.tree { localRoots[Key(section: line.section, text: tree.identity), default: []].append(index) }
        }
        for (index, line) in remote.enumerated() where pairs[index] == nil {
            if let tree = line.tree { remoteRoots[Key(section: line.section, text: tree.identity), default: []].append(index) }
        }
        for (key, candidates) in remoteRoots {
            if candidates.count == 1, let matches = localRoots[key], matches.count == 1 {
                pairs[candidates[0]] = matches[0]
            }
        }
        for (index, localIndex) in pairs.sorted(by: { $0.key < $1.key }) {
            let localTree = left[localIndex].tree!
            var remoteTree = right[index].tree!
            // A short indented readback paragraph can touch the preceding list
            // without a blank separator. Prefer the local paragraph position
            // when the exact text already follows this same matched list root.
            var followingLocal = followingParagraphs(local, after: localIndex)
            let followingRemote = followingParagraphs(remote, after: index)
            for (key, count) in followingRemote {
                followingLocal[key] = max(0, followingLocal[key, default: 0] - count)
            }
            var remoteContinuations: [String: Int] = [:]
            for entry in remoteTree.entries {
                if case .continuation(let raw) = entry, indentation(raw) <= 3 {
                    remoteContinuations[SyncDocument.comparisonKey(raw.trimmingCharacters(in: .whitespaces)), default: 0] += 1
                }
            }
            remoteTree.entries.removeAll {
                if case .continuation(let raw) = $0, indentation(raw) <= 3 {
                    let key = SyncDocument.comparisonKey(raw.trimmingCharacters(in: .whitespaces))
                    if followingLocal[key, default: 0] > 0 {
                        followingLocal[key, default: 0] -= 1
                        return true
                    }
                }
                return false
            }
            var continuations: [String: Int] = [:]
            for key in localTree.entries.compactMap({ entry -> String? in
                if case .continuation(let raw) = entry, indentation(raw) <= 3 {
                    return SyncDocument.comparisonKey(raw.trimmingCharacters(in: .whitespaces))
                }
                return nil
            }) { continuations[key, default: 0] += 1 }
            for (key, count) in remoteContinuations { continuations[key] = max(0, continuations[key, default: 0] - count) }
            for following in followingParagraphIndices(remote, after: index) {
                let key = SyncDocument.comparisonKey(remote[following].raw.trimmingCharacters(in: .whitespaces))
                if continuations[key, default: 0] > 0 {
                    right[following] = Line(raw: "", section: remote[following].section, pieces: [])
                    continuations[key, default: 0] -= 1
                }
            }
            let merged = ListTree.combine(local: localTree, remote: remoteTree)
            let combined = bodyLine(merged.text, section: local[localIndex].section)
            left[localIndex] = combined
            right[index] = combined
        }
        return (left, right)
    }

    private static func followingParagraphIndices(_ lines: [Line], after index: Int) -> [Int] {
        var result: [Int] = [], next = index + 1
        while next < lines.count, lines[next].section == lines[index].section,
              lines[next].tree == nil, headingLevel(lines[next].raw) == nil {
            if !lines[next].raw.isEmpty, indentation(lines[next].raw) <= 3 { result.append(next) }
            next += 1
        }
        return result
    }

    private static func followingParagraphs(_ lines: [Line], after index: Int) -> [String: Int] {
        var result: [String: Int] = [:]
        for next in followingParagraphIndices(lines, after: index) {
            result[SyncDocument.comparisonKey(lines[next].raw.trimmingCharacters(in: .whitespaces)), default: 0] += 1
        }
        return result
    }

    private struct ListTree {
        var raw: String
        var entries: [Entry] = []
        indirect enum Entry {
            case child(ListTree), continuation(String)
            var identity: String {
                switch self {
                case .child(let tree): return "list:" + tree.identity
                case .continuation(let raw): return "text:" + SyncDocument.comparisonKey(raw.trimmingCharacters(in: .whitespaces))
                }
            }
            var canonical: String {
                switch self { case .child(let tree): return "list:" + tree.canonical; case .continuation: return identity }
            }
            var text: String {
                switch self { case .child(let tree): return tree.text; case .continuation(let raw): return raw }
            }
        }
        var indent: Int { indentation(raw) }
        var identity: String { SyncDocument.comparisonKey(raw.trimmingCharacters(in: .whitespaces)) }
        var text: String { ([raw] + entries.map(\.text)).joined(separator: "\n") }
        var canonical: String {
            // Encode each line once. Re-encoding a whole child fingerprint at
            // every ancestor would grow exponentially with nesting depth.
            var lines: [String] = []
            func append(_ tree: ListTree, depth: Int) {
                lines.append("\(depth):list:" + Data(tree.identity.utf8).base64EncodedString())
                for entry in tree.entries {
                    switch entry {
                    case .child(let child): append(child, depth: depth + 1)
                    case .continuation: lines.append("\(depth):" + Data(entry.identity.utf8).base64EncodedString())
                    }
                }
            }
            append(self, depth: 0)
            return lines.joined(separator: "\n")
        }
        static func parse(_ raw: String) -> ListTree? {
            let lines = raw.components(separatedBy: "\n")
            guard let first = lines.first, listIndent(first) != nil else { return nil }
            var cursor = 0
            func node() -> ListTree {
                var result = ListTree(raw: lines[cursor]); cursor += 1
                while cursor < lines.count, indentation(lines[cursor]) > result.indent {
                    if listIndent(lines[cursor]) != nil { result.entries.append(.child(node())) }
                    else { result.entries.append(.continuation(lines[cursor])); cursor += 1 }
                }
                return result
            }
            let result = node()
            return cursor == lines.count ? result : nil
        }
        func shifted(to newIndent: Int) -> ListTree {
            let delta = newIndent - indent
            func shift(_ raw: String) -> String {
                String(repeating: " ", count: max(0, indentation(raw) + delta)) + raw.drop(while: { $0 == " " || $0 == "\t" })
            }
            return ListTree(raw: shift(raw), entries: entries.map {
                switch $0 {
                case .child(let child): return .child(child.shifted(to: child.indent + delta))
                case .continuation(let raw): return .continuation(shift(raw))
                }
            })
        }
        static func combine(local: ListTree, remote: ListTree) -> ListTree {
            var result = local
            var exact: [String: [Int]] = [:], exactCursor: [String: Int] = [:]
            for (index, entry) in local.entries.enumerated() { exact[entry.canonical, default: []].append(index) }
            var pairs: [Int: Int] = [:], claimed = Set<Int>()
            for (index, entry) in remote.entries.enumerated() {
                let occurrence = exactCursor[entry.canonical, default: 0]
                exactCursor[entry.canonical] = occurrence + 1
                if let candidates = exact[entry.canonical], occurrence < candidates.count {
                    pairs[index] = candidates[occurrence]; claimed.insert(candidates[occurrence])
                }
            }
            var localNames: [String: [Int]] = [:], remoteNames: [String: [Int]] = [:]
            for (index, entry) in local.entries.enumerated() where !claimed.contains(index) { localNames[entry.identity, default: []].append(index) }
            for (index, entry) in remote.entries.enumerated() where pairs[index] == nil { remoteNames[entry.identity, default: []].append(index) }
            for (key, indices) in remoteNames {
                if indices.count == 1, let matches = localNames[key], matches.count == 1 { pairs[indices[0]] = matches[0] }
            }
            let step = local.entries.compactMap { entry -> Int? in
                if case .child(let child) = entry { return child.indent - local.indent }
                return nil
            }.first ?? 2
            for (remoteIndex, entry) in remote.entries.enumerated() {
                if let index = pairs[remoteIndex] {
                    if case .child(let left) = result.entries[index], case .child(let right) = entry {
                        result.entries[index] = .child(combine(local: left, remote: right))
                    }
                } else {
                    switch entry {
                    case .child(let child): result.entries.append(.child(child.shifted(to: local.indent + step)))
                    case .continuation(let raw):
                        let shifted = String(repeating: " ", count: local.indent + max(1, indentation(raw) - remote.indent))
                            + raw.drop(while: { $0 == " " || $0 == "\t" })
                        result.entries.append(.continuation(shifted))
                    }
                }
            }
            return result
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
                // A blank paragraph boundary stops a list tree. Flomo often
                // indents a following ordinary paragraph by two spaces.
                if physical[end].isEmpty { break }
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
        let bullet = body == "-" || body == "+" || body == "*" || body.hasPrefix("- ") || body.hasPrefix("+ ") || body.hasPrefix("* ")
        let ordered = String(body).range(of: #"^\d+[.)](?:\s|$)"#, options: .regularExpression) != nil
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
