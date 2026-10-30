// Island Note list editing additions to MarkdownEngine 0.13.0.
import AppKit
import OSLog

/// One source-based model for editing and painting. UTF-16 offsets match TextKit.
enum StructuredLists {
    private static let log = Logger(subsystem: "MarkdownEngine", category: "lists")
    private static let prefix = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)]|[-+*•])[ \t]+(?:\[[ xX]\][ \t]+)?"#)
    /// BlockParser's legacy fence scanner only accepts column zero. Protect
    /// indented and tilde fences here before performing any source mutation.
    static func fencedRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var opening: (start: Int, character: Character, length: Int)?
        var position = 0
        while position < ns.length {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            let body = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = body.first, first == "`" || first == "~" {
                let run = body.prefix { $0 == first }.count
                if let active = opening {
                    if first == active.character, run >= active.length,
                       body.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                        ranges.append(NSRange(location: active.start, length: NSMaxRange(line) - active.start))
                        opening = nil
                    }
                } else if run >= 3, first != "`" || !body.dropFirst(run).contains("`") {
                    opening = (position, first, run)
                }
            }
            position = NSMaxRange(line)
        }
        if let opening { ranges.append(NSRange(location: opening.start, length: ns.length - opening.start)) }
        return ranges
    }
    static func isInFence(_ position: Int, text: String) -> Bool {
        fencedRanges(text).contains { NSLocationInRange(position, $0) || position == text.utf16.count && position == NSMaxRange($0) }
    }
    struct Item {
        let range: NSRange
        let marker: NSRange
        let content: Int
        let whitespace: String
        let ordered: Bool
        let group: Int
        var step: Int = 2
        var columns: Int { whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } }
        var depth: Int { columns / step }
    }
    struct Patch { let range: NSRange; let text: String }

    static func items(_ text: String) -> [Item] {
        let ns = text as NSString
        var result: [Item] = []
        let fences = fencedRanges(text)
        var group = 0
        for block in BlockParser.parse(text) {
            if block.kind == .blank { continue }
            guard block.kind == .list else {
                // Indented continuation text belongs to its preceding list item.
                let body = ns.substring(with: block.range)
                let ws = String(body.prefix { $0 == " " || $0 == "\t" })
                if block.kind == .paragraph, let last = result.last,
                   last.group == group, MarkdownLists.indentLevel(from: ws) > last.depth { continue }
                group += 1
                continue
            }
            var pos = block.range.location
            while pos < NSMaxRange(block.range) {
                let range = ns.lineRange(for: NSRange(location: pos, length: 0))
                let line = ns.substring(with: range) as NSString
                if !fences.contains(where: { NSLocationInRange(pos, $0) }),
                   let m = prefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) {
                    let marker = m.range(at: 2)
                    result.append(Item(range: range,
                        marker: NSRange(location: pos + marker.location, length: marker.length),
                        content: pos + NSMaxRange(m.range), whitespace: line.substring(with: m.range(at: 1)),
                        ordered: Int(line.substring(with: marker).dropLast()) != nil, group: group))
                }
                pos = NSMaxRange(range)
            }
        }
        // Respect established four-space lists, while tabs use the same two
        // columns as transport. The first child establishes the group's unit.
        var units: [Int: Int] = [:]
        var previous: [Int: Int] = [:]
        for item in result {
            if let prior = previous[item.group], item.columns > prior, units[item.group] == nil {
                units[item.group] = item.columns - prior == 4 ? 4 : 2
            }
            previous[item.group] = item.columns
        }
        for i in result.indices { result[i].step = units[result[i].group] ?? 2 }
        return result
    }

    static func numbers(_ items: [Item]) -> [Int: Int] {
        var counters: [Int: Int] = [:]
        var group: Int?
        var result: [Int: Int] = [:]
        for item in items {
            if group != item.group { counters = [:]; group = item.group }
            counters = counters.filter { $0.key <= item.depth }
            if item.ordered {
                let n = counters[item.depth] ?? 1
                result[item.marker.location] = n
                counters[item.depth] = n + 1
            } else { counters[item.depth] = nil }
        }
        return result
    }

    static func mapped(_ offset: Int, through patches: [Patch]) -> Int {
        var delta = 0
        for p in patches.sorted(by: { $0.range.location < $1.range.location }) {
            if offset < p.range.location { break }
            if offset < NSMaxRange(p.range) {
                return p.range.location + delta + min(offset - p.range.location, p.text.utf16.count)
            }
            delta += p.text.utf16.count - p.range.length
        }
        return offset + delta
    }
    static func replacing(_ text: String, patches: [Patch]) -> String {
        let result = NSMutableString(string: text)
        for p in patches.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: p.range, with: p.text)
        }
        return result as String
    }

    /// Only the edited list groups are renumbered; opening a file never rewrites it.
    static func numberPatches(_ text: String, touching range: NSRange) -> [Patch] {
        let list = items(text)
        let groups = Set(list.filter {
            $0.range.location <= NSMaxRange(range) && NSMaxRange($0.range) >= range.location
        }.map(\.group))
        let values = numbers(list)
        let ns = text as NSString
        return list.compactMap { item in
            guard groups.contains(item.group), let n = values[item.marker.location] else { return nil }
            let digits = NSRange(location: item.marker.location, length: item.marker.length - 1)
            guard ns.substring(with: digits) != String(n) else { return nil }
            return Patch(range: digits, text: String(n))
        }
    }

    /// Replace the smallest changed span in one native undo transaction, with no
    /// asynchronous repair pass and no rewriting during marked-text composition.
    static func apply(_ tv: NSTextView, range: NSRange, replacement: String,
                      selection: NSRange? = nil, onlyIfRenumbered: Bool = false) -> Bool {
        guard !tv.hasMarkedText() else { return false }
        let old = tv.string
        let candidate = (old as NSString).replacingCharacters(in: range, with: replacement)
        let patches = numberPatches(candidate, touching: NSRange(location: range.location, length: replacement.utf16.count))
        if onlyIfRenumbered && patches.isEmpty { return false }
        let final = replacing(candidate, patches: patches)
        let target = selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0)
        let start = mapped(target.location, through: patches)
        let end = mapped(NSMaxRange(target), through: patches)
        let a = Array(old.utf16), b = Array(final.utf16)
        var lo = 0
        while lo < min(a.count, b.count), a[lo] == b[lo] { lo += 1 }
        if lo > 0, lo < a.count, (0xDC00...0xDFFF).contains(a[lo]) { lo -= 1 }
        var tail = 0
        while tail < min(a.count, b.count) - lo, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        if tail > 0, tail < a.count, (0xDC00...0xDFFF).contains(a[a.count - tail]) { tail -= 1 }
        if a != b {
            let editRange = NSRange(location: lo, length: a.count - lo - tail)
            let insert = (final as NSString).substring(with: NSRange(location: lo, length: b.count - lo - tail))
            MarkdownLists.performEdit(tv, replace: editRange, with: insert, normalize: false)
        }
        tv.setSelectedRange(NSRange(location: start, length: end - start))
        if !patches.isEmpty { log.debug("Renumbered \(patches.count) list markers") }
        return true
    }

    static func shift(_ tv: NSTextView, outdent: Bool) -> Bool {
        guard !tv.hasMarkedText() else { return false }
        let text = tv.string, ns = text as NSString
        let list = items(text), selection = tv.selectedRange()
        let lastPosition = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let selected = list.indices.filter {
            list[$0].range.location <= lastPosition && NSMaxRange(list[$0].range) > selection.location
                || (selection.location == ns.length && NSMaxRange(list[$0].range) == ns.length)
        }
        guard !selected.isEmpty else { return false }
        let config = (tv as? NativeTextView)?.configuration.lists ?? .default
        var moving = Set<Int>()
        for i in selected {
            moving.insert(i)
            var j = i + 1
            while j < list.count, list[j].group == list[i].group, list[j].depth > list[i].depth {
                moving.insert(j); j += 1
            }
        }
        let rootDepth = selected.map { list[$0].depth }.min() ?? 0
        if outdent && rootDepth == 0 { return true }
        if !outdent {
            // A child needs a preceding sibling to become its parent.
            guard moving.allSatisfy({ list[$0].depth < config.maximumNestingLevel }) else { return true }
            for i in selected where i == 0 || list[i - 1].group != list[i].group || !moving.contains(i - 1) {
                guard i > 0, list[i - 1].group == list[i].group,
                      list[i - 1].depth >= list[i].depth else { return true }
            }
        }
        var patches: [Patch] = []
        for i in moving.sorted() {
            let item = list[i]
            let wsRange = NSRange(location: item.range.location, length: item.whitespace.utf16.count)
            let ws = String(repeating: " ", count: max(0, item.columns + (outdent ? -item.step : item.step)))
            patches.append(Patch(range: wsRange, text: ws))
            // Preserve physical continuation lines (including fenced child content)
            // until the next item/boundary, shifting them by the same two columns.
            var pos = NSMaxRange(item.range)
            let limit = i + 1 < list.count ? list[i + 1].range.location : ns.length
            while pos < limit {
                let line = ns.lineRange(for: NSRange(location: pos, length: 0))
                let raw = ns.substring(with: line)
                let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pos = NSMaxRange(line); continue }
                guard leading.reduce(0, { $0 + ($1 == "\t" ? 2 : 1) }) > item.columns else { break }
                let columns = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
                let newLeading = String(repeating: " ", count: max(0, columns + (outdent ? -item.step : item.step)))
                patches.append(Patch(range: NSRange(location: pos, length: leading.utf16.count), text: newLeading))
                pos = NSMaxRange(line)
            }
        }
        let changed = replacing(text, patches: patches)
        let start = mapped(selection.location, through: patches), end = mapped(NSMaxRange(selection), through: patches)
        // Bound normalization to the moved range, not unrelated lists.
        let firstPatch = patches.min { $0.range.location < $1.range.location }!
        let lastPatch = patches.max { NSMaxRange($0.range) < NSMaxRange($1.range) }!
        let oldRange = NSRange(location: firstPatch.range.location, length: NSMaxRange(lastPatch.range) - firstPatch.range.location)
        let newEnd = mapped(NSMaxRange(oldRange), through: patches)
        return apply(tv, range: oldRange,
                     replacement: (changed as NSString).substring(with: NSRange(location: oldRange.location, length: newEnd - oldRange.location)),
                     selection: NSRange(location: start, length: end - start))
    }

    static func enter(_ tv: NSTextView, range: NSRange) -> Bool {
        let ns = tv.string as NSString
        guard let item = items(tv.string).first(where: {
            range.location >= $0.content && range.location <= NSMaxRange($0.range)
                && ns.lineRange(for: NSRange(location: range.location, length: 0)).location == $0.range.location
        }) else { return false }
        let body = ns.substring(with: NSRange(location: item.content, length: NSMaxRange(item.range) - item.content))
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && range.length == 0 {
            if item.depth > 0 { return shift(tv, outdent: true) }
            return apply(tv, range: NSRange(location: item.range.location, length: item.content - item.range.location), replacement: "")
        }
        var marker = ns.substring(with: NSRange(location: item.marker.location, length: item.content - item.marker.location))
        marker = marker.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        return apply(tv, range: range, replacement: "\n" + item.whitespace + marker)
    }
}
