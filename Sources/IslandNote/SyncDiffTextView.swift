import AppKit

/// Presentation folding never changes a source copy. Each visible span maps
/// back to its original UTF-16 range, including hidden unchanged paragraphs.
struct SyncDiffPresentation {
    struct Span { let source: NSRange; let display: NSRange; let folded: Bool }
    struct Side {
        let original: String
        let source: NSString
        var text = ""
        var displayLength = 0
        var spans: [Span] = []
        var highlights: [NSRange] = []

        init(original: String) { self.original = original; source = original as NSString }

        func sourceOffset(_ offset: Int, trailing: Bool = false) -> Int {
            for span in spans where offset < NSMaxRange(span.display) {
                if span.folded { return trailing ? NSMaxRange(span.source) : span.source.location }
                return span.source.location + max(0, offset - span.display.location)
            }
            return source.length
        }
        func displayOffset(_ offset: Int) -> Int {
            for span in spans where offset < NSMaxRange(span.source) {
                return span.display.location + (span.folded ? 0 : max(0, offset - span.source.location))
            }
            return displayLength
        }
        func originalText(in selection: NSRange) -> String {
            guard selection.length > 0 else { return "" }
            let start = sourceOffset(selection.location)
            // Map the last selected code unit, so a selection ending exactly
            // before a fold does not accidentally include hidden text.
            let last = sourceOffset(NSMaxRange(selection) - 1, trailing: true)
            let end: Int
            if let span = spans.first(where: { NSLocationInRange(NSMaxRange(selection) - 1, $0.display) }), span.folded {
                end = last
            } else { end = min(source.length, last + 1) }
            return source.substring(with: NSRange(location: start, length: max(0, end - start)))
        }
    }
    struct Block {
        let left: NSRange
        let right: NSRange
        let changed: Bool
        let folded: Bool
        let leftChanged: Bool
        let rightChanged: Bool
    }
    var left: Side
    var right: Side
    var blocks: [Block] = []

    init(diff: SyncDiff, collapseUnchanged: Bool) {
        left = Side(original: diff.left); right = Side(original: diff.right)
        for block in diff.blocks {
            if collapseUnchanged, block.kind == .equal, min(block.leftLineCount, block.rightLineCount) > 14 {
                let l = Self.lines(in: left.source, range: block.left), r = Self.lines(in: right.source, range: block.right)
                if l.count == r.count, l.count > 14 {
                    let hidden = l.count - 6
                    append(left: Self.join(l.prefix(3)), right: Self.join(r.prefix(3)), changed: false)
                    let marker = L10n.format("… %d unchanged lines …", hidden) + "\n"
                    append(left: Self.join(l.dropFirst(3).dropLast(3)), right: Self.join(r.dropFirst(3).dropLast(3)),
                           changed: false, marker: marker)
                    append(left: Self.join(l.suffix(3)), right: Self.join(r.suffix(3)), changed: false)
                    continue
                }
            }
            append(left: block.left, right: block.right, changed: block.kind == .changed,
                   leftHighlights: block.leftHighlights, rightHighlights: block.rightHighlights)
        }
    }
    private mutating func append(left l: NSRange, right r: NSRange, changed: Bool, marker: String? = nil,
                                 leftHighlights: [NSRange] = [], rightHighlights: [NSRange] = []) {
        func add(_ range: NSRange, highlights: [NSRange], side: inout Side) -> NSRange {
            let start = side.displayLength
            let text = marker ?? side.source.substring(with: range)
            let displayed = NSRange(location: start, length: (text as NSString).length)
            side.text += text
            side.displayLength += displayed.length
            if displayed.length > 0 { side.spans.append(Span(source: range, display: displayed, folded: marker != nil)) }
            if marker == nil {
                side.highlights += highlights.map { NSRange(location: start + $0.location - range.location, length: $0.length) }
            }
            return displayed
        }
        let lp = add(l, highlights: leftHighlights, side: &left)
        let rp = add(r, highlights: rightHighlights, side: &right)
        blocks.append(Block(left: lp, right: rp, changed: changed, folded: marker != nil,
                            leftChanged: !leftHighlights.isEmpty, rightChanged: !rightHighlights.isEmpty))
    }
    private static func lines(in string: NSString, range: NSRange) -> [NSRange] {
        var result: [NSRange] = [], offset = range.location
        while offset < NSMaxRange(range) {
            let line = NSIntersectionRange(string.lineRange(for: NSRange(location: offset, length: 0)), range)
            guard line.length > 0 else { break }
            result.append(line); offset = NSMaxRange(line)
        }
        return result
    }
    private static func join<S: BidirectionalCollection>(_ lines: S) -> NSRange where S.Element == NSRange {
        guard let first = lines.first, let last = lines.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}

enum SyncDiffPalette {
    static let removed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.48, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.17, blue: 0.20, alpha: 1)
    }
    static let added = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.82, blue: 0.57, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.47, blue: 0.28, alpha: 1)
    }
}

@MainActor
final class SyncDiffTextView: NSTextView {
    struct Decoration { let top: CGFloat; let height: CGFloat; let changed: Bool }
    var side = SyncDiffPresentation.Side(original: "")
    var decorations: [Decoration] = []
    var isLeft = true
    var leadingGap: CGFloat = 0
    private var fixedHeight: CGFloat?
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + leadingGap)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: fixedHeight ?? newSize.height))
    }
    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 5
        return style
    }
    func present(_ side: SyncDiffPresentation.Side, folded: [NSRange], isLeft: Bool) {
        self.side = side; self.isLeft = isLeft; leadingGap = 0; fixedHeight = nil
        let attributed = NSMutableAttributedString(string: side.text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: SettingsPalette.ink,
            .paragraphStyle: Self.paragraph
        ])
        let color = isLeft ? SyncDiffPalette.removed : SyncDiffPalette.added
        for range in side.highlights { attributed.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.18), range: range) }
        for range in folded { attributed.addAttributes([.foregroundColor: SettingsPalette.secondary, .font: NSFont.systemFont(ofSize: 13)], range: range) }
        textStorage?.setAttributedString(attributed)
        setAccessibilityValue(side.original)
    }
    func measure(width: CGFloat, ranges: [NSRange]) -> [CGFloat] {
        fixedHeight = nil; leadingGap = 0
        setFrameSize(NSSize(width: width, height: max(200, frame.height)))
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return [] }
        if storage.length > 0 { storage.addAttribute(.paragraphStyle, value: Self.paragraph, range: NSRange(location: 0, length: storage.length)) }
        layout.ensureLayout(for: container)
        return ranges.map { range in max(0, boundary(NSMaxRange(range)) - boundary(range.location)) }
    }
    func boundary(_ character: Int) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return 0 }
        if character >= storage.length {
            if layout.extraLineFragmentTextContainer != nil { return layout.extraLineFragmentRect.minY }
            return layout.usedRect(for: container).maxY
        }
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
    }
    func align(gaps: [(NSRange, CGFloat)], height: CGFloat) {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        var padding: [Int: CGFloat] = [:]
        for (range, gap) in gaps where gap > 0.01 {
            let before = NSMaxRange(range)
            if before == 0 { leadingGap += gap }
            else { padding[before - 1, default: 0] += gap }
        }
        storage.beginEditing()
        for (character, amount) in padding {
            let range = (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
            let style = Self.paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = amount
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        layout.ensureLayout(for: container)
        fixedHeight = height
        setFrameSize(NSSize(width: frame.width, height: height))
        needsDisplay = true
    }
    func setDocumentHeight(_ height: CGFloat) {
        fixedHeight = height
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let pieces = selectedRanges.map { side.originalText(in: $0.rangeValue) }
        return pasteboard.setString(pieces.joined(separator: "\n"), forType: .string)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = isLeft ? SyncDiffPalette.removed : SyncDiffPalette.added
        // Binary search to draw only decorations intersecting the viewport.
        var low = 0, high = decorations.count
        while low < high {
            let mid = (low + high) / 2
            if decorations[mid].top + decorations[mid].height < dirtyRect.minY { low = mid + 1 } else { high = mid }
        }
        for decoration in decorations.dropFirst(low) {
            if decoration.top > dirtyRect.maxY { break }
            guard decoration.changed else { continue }
            color.withAlphaComponent(0.065).setFill()
            NSRect(x: 0, y: decoration.top, width: bounds.width, height: decoration.height).fill()
            (isLeft ? "−" : "+").draw(at: NSPoint(x: 6, y: decoration.top + 1), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color
            ])
        }
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
