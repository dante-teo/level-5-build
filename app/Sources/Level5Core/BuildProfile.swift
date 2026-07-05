public struct BuildProfile: Equatable, Sendable {
    public let productName: String
    public let bundleIdentifier: String
    public let version: String

    public init(
        productName: String = "Level5 Build",
        bundleIdentifier: String = "io.anvia.level5.build",
        version: String = "0.0.0"
    ) {
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    public var displayTitle: String {
        "\(productName) \(version)"
    }
}
