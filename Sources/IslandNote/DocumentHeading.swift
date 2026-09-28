import Foundation

struct DocumentHeading: Identifiable, Equatable {
    var id: Int { offset }
    let offset: Int // UTF-16, matching NSTextView's source storage.
    let level: Int
    var title: String

    static func parse(_ source: String) -> [DocumentHeading] {
        // Foundation's Markdown parser handles fenced/indented code, escapes,
        // setext headings and inline formatting without another dependency.
        guard let markdown = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true
        )) else { return [] }
        let ns = source as NSString
        var lineOffsets: [Int] = []
        var offset = 0
        while offset < ns.length {
            lineOffsets.append(offset)
            offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        }
        var headings: [DocumentHeading] = []
        var lastIdentity: Int?
        for run in markdown.runs {
            guard let heading = run.presentationIntent?.components.first(where: {
                if case .header = $0.kind { return true }
                return false
            }), case .header(let level) = heading.kind,
                let position = run.markdownSourcePosition,
                lineOffsets.indices.contains(position.startLine - 1) else { continue }
            let title = String(markdown[run.range].characters)
            if lastIdentity == heading.identity, !headings.isEmpty {
                headings[headings.count - 1].title += title
            } else {
                headings.append(DocumentHeading(offset: lineOffsets[position.startLine - 1], level: level, title: title))
                lastIdentity = heading.identity
            }
        }
        return headings.compactMap { heading in
            var heading = heading
            heading.title = heading.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return heading.title.isEmpty ? nil : heading
        }
    }
}
