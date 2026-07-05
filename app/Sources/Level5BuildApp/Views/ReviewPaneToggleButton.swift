import Level5Design
import SwiftUI

struct ReviewPaneToggleButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReviewPaneGlyph()
                .stroke(
                    Color.primary.opacity(isSelected ? 0.92 : 0.78),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                )
                .frame(width: TopBarControlMetrics.glyphSize, height: TopBarControlMetrics.glyphSize)
                .topBarControlChrome(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Close Review" : "Open Review")
    }
}

enum TopBarControlMetrics {
    static let size: CGFloat = 44
    static let glyphSize: CGFloat = 24
}

extension View {
    func topBarControlChrome(isSelected: Bool) -> some View {
        modifier(TopBarControlChrome(isSelected: isSelected))
    }
}

private struct TopBarControlChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            base(content)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func base(_ content: Content) -> some View {
        content
            .frame(width: TopBarControlMetrics.size, height: TopBarControlMetrics.size)
            .contentShape(Circle())
    }

    private func fallback(_ content: Content) -> some View {
        base(content)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(L5Color.border.opacity(isSelected ? 1 : 0.82), lineWidth: 0.25)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, x: .zero, y: 2)
    }
}

private struct ReviewPaneGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width * 0.34
        let height = rect.height * 0.76
        let gap = rect.width * 0.10
        let leftX = rect.midX - gap / 2 - width
        let rightX = rect.midX + gap / 2
        let y = rect.midY - height / 2
        let radius = rect.width * 0.08

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: leftX, y: y, width: width, height: height),
            cornerSize: CGSize(width: radius, height: radius)
        )
        path.addRoundedRect(
            in: CGRect(x: rightX, y: y, width: width, height: height),
            cornerSize: CGSize(width: radius, height: radius)
        )
        return path
    }
}
