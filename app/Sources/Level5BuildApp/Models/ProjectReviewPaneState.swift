import Foundation
import Level5Core

public struct ProjectReviewPaneState: Equatable, Sendable {
    public var isOpen: Bool
    public var projectPath: String?
    public var snapshot: ProjectReviewSnapshot?
    public var isRefreshing: Bool
    public var loadingPreviewFileIDs: Set<String>
    public var previewCache: [String: ProjectFilePreview]

    public init(
        isOpen: Bool = false,
        projectPath: String? = nil,
        snapshot: ProjectReviewSnapshot? = nil,
        isRefreshing: Bool = false,
        loadingPreviewFileIDs: Set<String> = [],
        previewCache: [String: ProjectFilePreview] = [:]
    ) {
        self.isOpen = isOpen
        self.projectPath = projectPath
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.loadingPreviewFileIDs = loadingPreviewFileIDs
        self.previewCache = previewCache
    }

    public var changedFileCount: Int? {
        snapshot?.totalChangedFiles
    }
}
