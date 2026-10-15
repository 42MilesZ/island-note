import Foundation

/// A read-only comparison. Every range refers to the original string, in UTF-16 units.
struct SyncDiff: Sendable {
    enum Kind: Sendable, Equatable { case equal, changed }

    struct Block: Sendable {
        let kind: Kind
        let left: NSRange
        let right: NSRange
        let leftHighlights: [NSRange]
        let rightHighlights: [NSRange]
        let leftLineCount: Int
        let rightLineCount: Int
    }

    let left: String
    let right: String
    let blocks: [Block]
    let usedCoarseComparison: Bool

    private struct Line {
        let range: NSRange
        let key: String
    }

    private struct CharacterToken {
        let key: String
        let range: NSRange
    }

    private struct Match {
        let left: Int
        let right: Int
    }

    // These caps bound the quadratic portions of CollectionDifference. The anchor
    // scan itself is linear; an unmatched interval becomes one coarse block.
    private static let lineWorkLimit = 400_000
    private static let characterWorkLimit = 150_000

    static func compare(left: String, right: String) -> SyncDiff {
        let leftLines = lines(in: left)
        let rightLines = lines(in: right)
        var lineWork = lineWorkLimit
        var characterWork = characterWorkLimit
        var anchorWork = 300_000
        var coarse = false
        var matches: [Match] = []

        func collect(_ lowerLeft: Int, _ upperLeft: Int, _ lowerRight: Int, _ upperRight: Int) {
            var a = lowerLeft
            var b = lowerRight
            while a < upperLeft, b < upperRight, leftLines[a].key == rightLines[b].key {
                matches.append(Match(left: a, right: b))
                a += 1
                b += 1
            }

            var endA = upperLeft
            var endB = upperRight
            var suffix: [Match] = []
            while a < endA, b < endB, leftLines[endA - 1].key == rightLines[endB - 1].key {
                endA -= 1
                endB -= 1
                suffix.append(Match(left: endA, right: endB))
            }

            if a < endA, b < endB {
                let leftCount = endA - a
                let rightCount = endB - b
                let work = leftCount.multipliedReportingOverflow(by: rightCount)
                if !work.overflow, work.partialValue <= lineWork {
                    lineWork -= work.partialValue
                    let old = Array(leftLines[a..<endA].map(\.key))
                    let new = Array(rightLines[b..<endB].map(\.key))
                    let difference = new.difference(from: old)
                    var removed = Array(repeating: false, count: old.count)
                    var inserted = Array(repeating: false, count: new.count)
                    for change in difference {
                        switch change {
                        case .remove(let offset, _, _): removed[offset] = true
                        case .insert(let offset, _, _): inserted[offset] = true
                        }
                    }
                    var oldIndex = 0
                    var newIndex = 0
                    while oldIndex < old.count, newIndex < new.count {
                        while oldIndex < old.count, removed[oldIndex] { oldIndex += 1 }
                        while newIndex < new.count, inserted[newIndex] { newIndex += 1 }
                        if oldIndex < old.count, newIndex < new.count {
                            matches.append(Match(left: a + oldIndex, right: b + newIndex))
                            oldIndex += 1
                            newIndex += 1
                        }
                    }
                } else {
                    let scanCost = leftCount + rightCount
                    if scanCost > anchorWork {
                        coarse = true
                    } else {
                        anchorWork -= scanCost
                        let anchors = uniqueAnchors(leftLines, a..<endA, rightLines, b..<endB)
                        if anchors.isEmpty {
                            coarse = true
                        } else {
                            var precedingA = a
                            var precedingB = b
                            for anchor in anchors {
                                collect(precedingA, anchor.left, precedingB, anchor.right)
                                matches.append(anchor)
                                precedingA = anchor.left + 1
                                precedingB = anchor.right + 1
                            }
                            collect(precedingA, endA, precedingB, endB)
                        }
                    }
                }
            }
            matches.append(contentsOf: suffix.reversed())
        }

        collect(0, leftLines.count, 0, rightLines.count)

        func span(_ lines: [Line], _ lower: Int, _ upper: Int, _ totalLength: Int) -> NSRange {
            let start = lower < lines.count ? lines[lower].range.location : totalLength
            let end = upper > lower ? NSMaxRange(lines[upper - 1].range) : start
            return NSRange(location: start, length: end - start)
        }

        let leftLength = left.utf16.count
        let rightLength = right.utf16.count
        var blocks: [Block] = []

        func append(_ kind: Kind, _ a: Int, _ endA: Int, _ b: Int, _ endB: Int) {
            let leftRange = span(leftLines, a, endA, leftLength)
            let rightRange = span(rightLines, b, endB, rightLength)
            var leftHighlights: [NSRange] = []
            var rightHighlights: [NSRange] = []
            if kind == .changed {
                if leftRange.length == 0 || rightRange.length == 0 {
                    if leftRange.length > 0 { leftHighlights = [leftRange] }
                    if rightRange.length > 0 { rightHighlights = [rightRange] }
                } else {
                    let result = highlights(left: left, leftRange: leftRange,
                                            right: right, rightRange: rightRange,
                                            work: &characterWork)
                    if let result {
                        leftHighlights = result.0
                        rightHighlights = result.1
                    } else {
                        leftHighlights = [leftRange]
                        rightHighlights = [rightRange]
                        coarse = true
                    }
                }
            }
            blocks.append(Block(kind: kind, left: leftRange, right: rightRange,
                                leftHighlights: leftHighlights, rightHighlights: rightHighlights,
                                leftLineCount: endA - a, rightLineCount: endB - b))
        }

        var oldCursor = 0
        var newCursor = 0
        var matchIndex = 0
        while matchIndex < matches.count {
            let match = matches[matchIndex]
            if oldCursor < match.left || newCursor < match.right {
                append(.changed, oldCursor, match.left, newCursor, match.right)
            }
            let startA = match.left
            let startB = match.right
            var endA = startA + 1
            var endB = startB + 1
            matchIndex += 1
            while matchIndex < matches.count,
                  matches[matchIndex].left == endA,
                  matches[matchIndex].right == endB {
                endA += 1
                endB += 1
                matchIndex += 1
            }
            append(.equal, startA, endA, startB, endB)
            oldCursor = endA
            newCursor = endB
        }
        if oldCursor < leftLines.count || newCursor < rightLines.count {
            append(.changed, oldCursor, leftLines.count, newCursor, rightLines.count)
        }
        if blocks.isEmpty {
            append(.equal, 0, 0, 0, 0)
        }

        return SyncDiff(left: left, right: right, blocks: blocks, usedCoarseComparison: coarse)
    }

    private static func lines(in source: String) -> [Line] {
        let string = source as NSString
        var result: [Line] = []
        var start = 0
        var offset = 0
        while offset < string.length {
            let unit = string.character(at: offset)
            let isCRLF = unit == 13 && offset + 1 < string.length && string.character(at: offset + 1) == 10
            if unit == 10 || unit == 13 || unit == 0x2029 {
                let end = offset + (isCRLF ? 2 : 1)
                let range = NSRange(location: start, length: end - start)
                let raw = string.substring(with: range)
                let key = isCRLF
                    ? (raw as NSString).substring(to: range.length - 2) + "\n"
                    : raw
                result.append(Line(range: range, key: key))
                start = end
                offset = end
            } else {
                offset += 1
            }
        }
        if start < string.length {
            let range = NSRange(location: start, length: string.length - start)
            result.append(Line(range: range, key: string.substring(with: range)))
        }
        return result
    }

    /// Patience-style unique anchors, reduced to a monotone subsequence.
    private static func uniqueAnchors(_ left: [Line], _ leftRange: Range<Int>,
                                      _ right: [Line], _ rightRange: Range<Int>) -> [Match] {
        var oldPositions: [String: Int] = [:]
        for index in leftRange {
            let key = left[index].key
            oldPositions[key] = oldPositions[key] == nil ? index : -1
        }
        var newPositions: [String: Int] = [:]
        for index in rightRange {
            let key = right[index].key
            newPositions[key] = newPositions[key] == nil ? index : -1
        }
        let candidates = leftRange.compactMap { index -> Match? in
            let key = left[index].key
            guard oldPositions[key] == index, let destination = newPositions[key], destination >= 0 else {
                return nil
            }
            return Match(left: index, right: destination)
        }
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: candidates.count)
        for (index, candidate) in candidates.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[tails[middle]].right < candidate.right { low = middle + 1 }
                else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) }
            else { tails[low] = index }
        }
        guard var cursor = tails.last else { return [] }
        var result: [Match] = []
        while cursor >= 0 {
            result.append(candidates[cursor])
            cursor = previous[cursor]
        }
        return result.reversed()
    }

    private static func tokens(in source: String, range: NSRange) -> [CharacterToken] {
        let substring = (source as NSString).substring(with: range)
        var result: [CharacterToken] = []
        var offset = range.location
        for character in substring {
            let text = String(character)
            let length = text.utf16.count
            result.append(CharacterToken(key: text == "\r\n" ? "\n" : text,
                                         range: NSRange(location: offset, length: length)))
            offset += length
        }
        return result
    }

    private static func highlights(left: String, leftRange: NSRange,
                                   right: String, rightRange: NSRange,
                                   work: inout Int) -> ([NSRange], [NSRange])? {
        guard leftRange.length + rightRange.length <= 120_000 else { return nil }
        let old = tokens(in: left, range: leftRange)
        let new = tokens(in: right, range: rightRange)
        var start = 0
        while start < old.count, start < new.count, old[start].key == new[start].key { start += 1 }
        var endOld = old.count
        var endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1].key == new[endNew - 1].key {
            endOld -= 1
            endNew -= 1
        }
        let oldCount = endOld - start
        let newCount = endNew - start
        if oldCount == 0 || newCount == 0 {
            return (merge(old[start..<endOld].map(\.range)), merge(new[start..<endNew].map(\.range)))
        }
        let cost = oldCount.multipliedReportingOverflow(by: newCount)
        guard !cost.overflow, cost.partialValue <= work else { return nil }
        work -= cost.partialValue
        let difference = Array(new[start..<endNew].map(\.key))
            .difference(from: Array(old[start..<endOld].map(\.key)))
        var oldRanges: [NSRange] = []
        var newRanges: [NSRange] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): oldRanges.append(old[start + offset].range)
            case .insert(let offset, _, _): newRanges.append(new[start + offset].range)
            }
        }
        return (merge(oldRanges), merge(newRanges))
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}
