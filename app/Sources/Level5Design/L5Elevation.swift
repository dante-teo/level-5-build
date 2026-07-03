import SwiftUI

public enum L5Elevation {
    case e0
    case e1
    case e2
    case e3

    public var radius: CGFloat {
        switch self {
        case .e0: 0
        case .e1: 14
        case .e2: 22
        case .e3: 34
        }
    }

    public var y: CGFloat {
        switch self {
        case .e0: 0
        case .e1: 6
        case .e2: 12
        case .e3: 20
        }
    }

    public var opacity: Double {
        switch self {
        case .e0: 0
        case .e1: 0.08
        case .e2: 0.12
        case .e3: 0.16
        }
    }
}
