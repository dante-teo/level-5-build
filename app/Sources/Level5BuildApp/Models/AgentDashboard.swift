import Foundation
import Level5Core
import Level5Design
import SwiftUI

struct AgentReference: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case web
        case file
    }

    var kind: Kind
    var title: String
    var uri: String

    var id: String { "\(kind)-\(uri)" }

    func hasSameIdentity(as reference: AgentReference) -> Bool {
        kind == reference.kind && uri == reference.uri
    }
}

struct ProjectDashboardState: Equatable, Sendable {
    var projectPath: String
    var gitStatus: ProjectGitStatus
    var references: [AgentReference]
    var isRefreshing: Bool

    init(
        projectPath: String,
        gitStatus: ProjectGitStatus = .unavailable(),
        references: [AgentReference] = [],
        isRefreshing: Bool = false
    ) {
        self.projectPath = projectPath
        self.gitStatus = gitStatus
        self.references = references
        self.isRefreshing = isRefreshing
    }
}

enum ProjectDashboardPresentation: Equatable, Sendable {
    case hidden
    case reserved
    case overlay
}

enum ProjectDashboardLayout: Equatable, Sendable {
    case compact
    case regular
    case wide

    private enum Breakpoint {
        static let compactWidth = L5AdaptiveBreakpoint.compactWorkspace
        static let wideWidth = L5AdaptiveBreakpoint.wideWorkspace
    }

    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?, workspaceWidth: CGFloat) -> ProjectDashboardLayout {
        if workspaceWidth >= Breakpoint.wideWidth {
            return .wide
        }
        if workspaceWidth <= Breakpoint.compactWidth {
            return .compact
        }
        if horizontalSizeClass == .compact {
            return .compact
        }
        return .regular
    }
}

private enum L5AdaptiveBreakpoint {
    static let compactWorkspace = L5Spacing.x16 * 12
    static let wideWorkspace = L5Spacing.x16 * 16
}

struct ProjectDashboardAdaptiveState: Equatable, Sendable {
    var layout: ProjectDashboardLayout = .regular
    var isOverlayTemporarilyOpen = false
    var isManuallyClosed = false

    var presentation: ProjectDashboardPresentation {
        if isManuallyClosed {
            return .hidden
        }
        switch layout {
        case .wide:
            return .reserved
        case .regular:
            return .reserved
        case .compact:
            return isOverlayTemporarilyOpen ? .overlay : .hidden
        }
    }

    mutating func update(horizontalSizeClass: UserInterfaceSizeClass?, workspaceWidth: CGFloat) {
        let nextLayout = ProjectDashboardLayout.resolve(
            horizontalSizeClass: horizontalSizeClass,
            workspaceWidth: workspaceWidth
        )
        if nextLayout != layout || isOverlayTemporarilyOpen {
            isOverlayTemporarilyOpen = false
        }
        layout = nextLayout
    }

    mutating func toggle() {
        switch layout {
        case .compact:
            isManuallyClosed = false
            isOverlayTemporarilyOpen.toggle()
        case .regular, .wide:
            isOverlayTemporarilyOpen = false
            isManuallyClosed.toggle()
        }
    }

    mutating func close() {
        switch layout {
        case .compact:
            isOverlayTemporarilyOpen = false
        case .regular, .wide:
            isManuallyClosed = true
        }
    }

    mutating func open() {
        isManuallyClosed = false
        guard layout == .compact else { return }
        isOverlayTemporarilyOpen = true
    }

    mutating func resetForContextChange() {
        isOverlayTemporarilyOpen = false
        isManuallyClosed = false
    }
}
