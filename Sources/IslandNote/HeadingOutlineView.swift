import AppKit
import SwiftUI

final class HeadingOutlineModel: ObservableObject {
    @Published var headings: [DocumentHeading] = []
    @Published var activeID: Int?
    @Published var hoveredID: Int?
    var onNavigate: ((DocumentHeading) -> Void)?
    private var lastHaptic: TimeInterval = 0

    var isVisible: Bool { headings.count >= 3 }

    func hover(_ id: Int?) {
        guard hoveredID != id else { return }
        hoveredID = id
        // One light tick when entering a heading; no pulses during scrolling.
        let now = ProcessInfo.processInfo.systemUptime
        if id != nil, now - lastHaptic > 0.09 {
            Haptics.outlinePreview()
            lastHaptic = now
        }
    }
}

struct HeadingOutline: View {
    @ObservedObject var model: HeadingOutlineModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation {
        reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.8)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.headings.enumerated()), id: \.element.id) { index, heading in
                            row(heading, index: index)
                                .id(heading.id)
                                .zIndex(model.hoveredID == heading.id ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .frame(height: min(geometry.size.height, CGFloat(model.headings.count) * 22 + 24))
                .frame(maxHeight: .infinity, alignment: .center)
                .onChange(of: model.activeID) { _, id in
                    guard model.hoveredID == nil, let id else { return }
                    withAnimation(motion) { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
        .opacity(model.isVisible ? 1 : 0)
        .animation(motion, value: model.isVisible)
        .animation(motion, value: model.hoveredID)
        .animation(motion, value: model.activeID)
        .accessibilityHidden(!model.isVisible)
    }

    private func row(_ heading: DocumentHeading, index: Int) -> some View {
        let hovered = model.hoveredID == heading.id
        let active = model.activeID == heading.id
        let hoverIndex = model.headings.firstIndex { $0.id == model.hoveredID }
        let distance = hoverIndex.map { abs($0 - index) } ?? 99
        let emphasis = max(0, 1 - Double(distance) / 3)
        let baseWidth = CGFloat(max(8, 20 - (heading.level - 1) * 3))
        return Button {
            model.onNavigate?(heading)
        } label: {
            Capsule()
                .fill(Color.white.opacity(hovered ? 1 : active ? 0.88 : 0.26 + emphasis * 0.28))
                .frame(width: baseWidth + (active ? 3 : 0) + emphasis * 12, height: hovered || active ? 3 : 2)
                .frame(width: 22, height: 22, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hover(heading.id) }
            else if model.hoveredID == heading.id { model.hover(nil) }
        }
        .overlay(alignment: .leading) {
            if hovered {
                Text(heading.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(width: 208, alignment: .leading)
                    .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .offset(x: 40)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -5)))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Heading \(heading.level): \(heading.title)")
        .accessibilityValue(active ? "Current section" : "")
        .accessibilityHint("Scroll to this section")
    }
}

/// The preview can extend over the note, but only the narrow rail takes input.
final class HeadingOutlineHost: NSHostingView<HeadingOutline> {
    let model: HeadingOutlineModel

    convenience init(model: HeadingOutlineModel) {
        self.init(rootView: HeadingOutline(model: model))
    }

    required init(rootView: HeadingOutline) {
        self.model = rootView.model
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard model.isVisible, local.x >= 0, local.x <= 22 else { return nil }
        return super.hitTest(point)
    }
}
