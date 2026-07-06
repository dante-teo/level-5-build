import SwiftUI

public enum L5Icon: Equatable {
    case agent
    case awaitingPermission
    case branch
    case chat
    case close
    case commit
    case completed
    case dashboard
    case error
    case local
    case newChat
    case pullRequest
    case refresh
    case running
    case settings
    case sourceDocument
    case sourceWeb
    case workingTreeChanges

    public var systemName: String {
        switch self {
        case .agent: "sparkles"
        case .awaitingPermission: "hand.raised.fill"
        case .branch: "point.3.connected.trianglepath.dotted"
        case .chat: "bubble.left"
        case .close: "xmark"
        case .commit: "smallcircle.filled.circle"
        case .completed: "checkmark.circle.fill"
        case .dashboard: "rectangle.3.group"
        case .error: "exclamationmark.triangle.fill"
        case .local: "laptopcomputer"
        case .newChat: "square.and.pencil"
        case .pullRequest: "globe"
        case .refresh: "arrow.clockwise"
        case .running: "circle.dotted"
        case .settings: "gearshape"
        case .sourceDocument: "doc"
        case .sourceWeb: "link"
        case .workingTreeChanges: "plus.rectangle"
        }
    }

    var weight: Font.Weight {
        switch self {
        case .agent, .awaitingPermission, .completed, .error, .running:
            .semibold
        default:
            .medium
        }
    }
}

public struct L5IconView: View {
    private let icon: L5Icon
    private let size: CGFloat

    public init(_ icon: L5Icon, size: CGFloat = L5Size.icon) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Image(systemName: icon.systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: icon.weight))
            .frame(width: size, height: size)
    }
}
