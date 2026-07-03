import SwiftUI

public enum L5SurfaceStyle: Equatable {
    case glass
    case panel
    case card

    var material: Material {
        switch self {
        case .glass: .regularMaterial
        case .panel: .thickMaterial
        case .card: .thinMaterial
        }
    }

    var radius: CGFloat {
        switch self {
        case .glass: L5Radius.panel
        case .panel: L5Radius.panel
        case .card: L5Radius.card
        }
    }

    var elevation: L5Elevation {
        switch self {
        case .glass: .e2
        case .panel: .e1
        case .card: .e1
        }
    }
}

public struct L5SurfaceModifier: ViewModifier {
    private let style: L5SurfaceStyle
    private let cornerRadius: CGFloat?

    public init(_ style: L5SurfaceStyle = .glass, cornerRadius: CGFloat? = nil) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let radius = cornerRadius ?? style.radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *), style == .glass {
            decorated(content.glassEffect(.regular, in: shape), radius: radius)
        } else {
            decorated(content.background(style.material, in: shape), radius: radius)
        }
        #else
        decorated(content.background(style.material, in: shape), radius: radius)
        #endif
    }

    private func decorated(_ content: some View, radius: CGFloat) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(style.elevation.opacity),
                radius: style.elevation.radius,
                x: 0,
                y: style.elevation.y
            )
    }
}

public enum L5ButtonVariant {
    case primary
    case secondary
    case subtle
}

public struct L5ButtonStyle: ButtonStyle {
    private let variant: L5ButtonVariant

    public init(_ variant: L5ButtonVariant = .secondary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(L5Font.body.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, L5Spacing.x4)
            .frame(height: 32)
            .background {
                buttonBackground(configuration)
                    .clipShape(RoundedRectangle(cornerRadius: L5Radius.button, style: .continuous))
            }
            .overlay {
                if variant != .primary {
                    RoundedRectangle(cornerRadius: L5Radius.button, style: .continuous)
                        .stroke(L5Color.border, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    private var foregroundStyle: Color {
        switch variant {
        case .primary: .white
        case .secondary: L5Color.textPrimary
        case .subtle: L5Color.textSecondary
        }
    }

    @ViewBuilder
    private func buttonBackground(_ configuration: Configuration) -> some View {
        switch variant {
        case .primary:
            L5Color.accent.opacity(configuration.isPressed ? 0.82 : 1)
        case .secondary:
            Rectangle()
                .fill(.regularMaterial)
                .opacity(configuration.isPressed ? 0.70 : 1)
        case .subtle:
            L5Color.selectedSurface.opacity(configuration.isPressed ? 1 : 0)
        }
    }
}

public struct L5InputModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(L5Font.body)
            .textFieldStyle(.plain)
            .padding(.horizontal, L5Spacing.x4)
            .frame(minHeight: 36)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: L5Radius.input, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
    }
}

public struct L5CompactControlModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(L5Font.caption)
            .controlSize(.small)
            .buttonBorderShape(.roundedRectangle(radius: L5Radius.button))
    }
}

public extension View {
    func l5Surface(_ style: L5SurfaceStyle = .glass, cornerRadius: CGFloat? = nil) -> some View {
        modifier(L5SurfaceModifier(style, cornerRadius: cornerRadius))
    }

    func l5InputSurface() -> some View {
        modifier(L5InputModifier())
    }

    func l5CompactControl() -> some View {
        modifier(L5CompactControlModifier())
    }
}
