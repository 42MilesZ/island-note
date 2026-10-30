// Structured list presentation. Source whitespace and numbering remain untouched.
import AppKit
import CoreText

enum ListMarkerMetrics {
    static let gap: CGFloat = 6
    static func bulletSize(for font: NSFont) -> CGFloat { max(3, font.pointSize / 4) }
    static func inkBounds(_ glyph: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return bounds.isEmpty ? CGRect(x: 0, y: 0, width: HeadingHelpers.textWidth(glyph, font: font), height: font.pointSize) : bounds
    }
}

extension MarkdownASTStyler {
    /// A level is only the nesting offset. Root markers share the prose margin.
    /// Every marker has the same six-point gap, independent of its source spelling.
    static func styleStructuredListItem(_ item: ListItem, ctx: Ctx, into attrs: inout [StyledRange]) {
        guard let depth = ctx.listDepths[item.marker.location] else { return }
        let ns = ctx.ns
        var end = NSMaxRange(item.range)
        while end > item.range.location, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
        var body = NSMaxRange(item.marker)
        func isSpace(_ position: Int) -> Bool {
            position < end && (ns.character(at: position) == 32 || ns.character(at: position) == 9)
        }
        while isSpace(body) { body += 1 }
        var checkbox: NSRange?
        var checked = false
        if body + 2 < end, ns.character(at: body) == 91, ns.character(at: body + 2) == 93,
           [32, 88, 120].contains(ns.character(at: body + 1)),
           body + 3 == end || isSpace(body + 3) {
            checkbox = NSRange(location: body, length: 3)
            checked = ns.character(at: body + 1) != 32
            body += 3
            while isSpace(body) { body += 1 }
        }
        let glyph = item.ordered ? ns.substring(with: item.marker) : ["•", "◦", "▪"][min(2, depth)]
        let markerWidth = checkbox == nil
            ? (item.ordered ? ListMarkerMetrics.inkBounds(glyph, font: ctx.baseFont).width : ListMarkerMetrics.bulletSize(for: ctx.baseFont))
            : TaskCheckboxGeometry.size(for: ctx.baseFont)
        let gap = ListMarkerMetrics.gap
        let indent = CGFloat(depth) * ctx.config.lists.indentPerLevel
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ctx.baseLineHeight + ctx.config.lists.extraLineHeight
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.paragraphSpacing = ctx.baseParagraphSpacing
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent + markerWidth + gap
        paragraph.defaultTabInterval = ctx.config.lists.indentPerLevel
        // Native tabs advance even at a tiny font size. Explicit stops collapse
        // indentation tabs at the margin and separator tabs at the body edge.
        var stops: [NSTextTab] = []
        var x = indent
        let prefixRange = NSRange(location: item.range.location, length: body - item.range.location)
        attrs.append((prefixRange, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear]))
        for position in item.range.location..<body {
            let character = ns.character(at: position)
            if character == 9 {
                x += 0.01
                stops.append(NSTextTab(textAlignment: .left, location: x))
                attrs.append((NSRange(location: position, length: 1), [.kern: 0]))
            } else {
                let range = NSRange(location: position, length: 1)
                let width = HeadingHelpers.textWidth(ns.substring(with: range), font: ctx.inlineMarkerFont)
                attrs.append((range, [.kern: -width]))
            }
            // Allocate layout advance on the source marker, not its following
            // spaces. A checkbox keeps the existing draw/hit-test anchor contract.
            if position == NSMaxRange(item.marker) - 1 {
                x += markerWidth + (checkbox == nil ? gap : TaskCheckboxGeometry.gap)
            }
            if let checkbox, position == NSMaxRange(checkbox) - 1 {
                x += gap - TaskCheckboxGeometry.gap
            }
        }
        paragraph.tabStops = stops
        attrs.append((NSRange(location: item.range.location, length: end - item.range.location), [.paragraphStyle: paragraph]))
        func advance(_ range: NSRange, by width: CGFloat) {
            let hiddenWidth = HeadingHelpers.textWidth(ns.substring(with: range), font: ctx.inlineMarkerFont)
            attrs.append((range, [.kern: (width - hiddenWidth) / CGFloat(max(1, range.length))]))
        }
        if let checkbox {
            advance(item.marker, by: markerWidth + TaskCheckboxGeometry.gap)
            advance(checkbox, by: gap - TaskCheckboxGeometry.gap)
            attrs.append((checkbox, [.taskCheckbox: checked]))
            if checked, body < end {
                attrs.append((NSRange(location: body, length: end - body), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor
                ]))
            }
        } else {
            advance(item.marker, by: markerWidth + gap)
            attrs.append((item.marker, [item.ordered ? .orderedMarker : .bulletMarker: glyph]))
        }
    }
}
