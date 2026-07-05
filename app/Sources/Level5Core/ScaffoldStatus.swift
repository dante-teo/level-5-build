public struct ScaffoldStatus: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(
        title: String = "Native macOS scaffold",
        detail: String = "Runtime and workspace surfaces will be added in follow-up issues."
    ) {
        self.title = title
        self.detail = detail
    }
}
