import SwiftUI

public enum L5Font {
    public static let family = "Barlow"
    public static let monoFamily = "Departure Mono"

    public static var display: Font {
        Font.custom(family, size: 32, relativeTo: .largeTitle).weight(.bold)
    }

    public static var h1: Font {
        Font.custom(family, size: 28, relativeTo: .title).weight(.bold)
    }

    public static var h2: Font {
        Font.custom(family, size: 22, relativeTo: .title2).weight(.semibold)
    }

    public static var h3: Font {
        Font.custom(family, size: 18, relativeTo: .title3).weight(.semibold)
    }

    public static var body: Font {
        Font.custom(family, size: 14, relativeTo: .body).weight(.regular)
    }

    public static var caption: Font {
        Font.custom(family, size: 12, relativeTo: .caption).weight(.medium)
    }

    public static func mono(size: CGFloat = 13) -> Font {
        Font.custom(monoFamily, size: size, relativeTo: .body)
    }
}
