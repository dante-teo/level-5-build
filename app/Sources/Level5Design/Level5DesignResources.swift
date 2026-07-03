import CoreText
import Foundation

public enum Level5DesignResources {
    public static let fontResourceNames = [
        "Barlow-Regular",
        "Barlow-Medium",
        "Barlow-SemiBold",
        "Barlow-Bold",
        "DepartureMono-Regular"
    ]

    public static let identityMarkResourceName = "Level5Mark"

    public static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: Level5DesignBundleToken.self)
        #endif
    }

    public static var fontResourceURLs: [URL] {
        fontResourceNames.compactMap { name in
            resourceURL(for: name, withExtension: "otf", subdirectory: "Fonts")
        }
    }

    public static var identityMarkURL: URL? {
        resourceURL(for: identityMarkResourceName, withExtension: "png", subdirectory: "Assets")
    }

    @discardableResult
    public static func registerFonts() -> Bool {
        fontResourceURLs.count == fontResourceNames.count && fontResourceURLs.allSatisfy(registerFont)
    }

    private static func registerFont(at url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }

        guard let error else {
            return false
        }

        let nsError = error.takeRetainedValue() as Error as NSError
        return nsError.domain == kCTFontManagerErrorDomain as String
            && nsError.code == CTFontManagerError.alreadyRegistered.rawValue
    }

    private static func resourceURL(for name: String, withExtension ext: String, subdirectory: String) -> URL? {
        resourceBundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(subdirectory)")
            ?? resourceBundle.url(forResource: name, withExtension: ext)
    }
}

private final class Level5DesignBundleToken {}
