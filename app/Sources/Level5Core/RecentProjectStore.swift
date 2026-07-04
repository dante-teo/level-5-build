import Foundation
import GRDB

public struct RecentProject: Equatable, Sendable {
    public let path: String
    public let displayName: String
    public let createdAt: Date
    public let lastOpenedAt: Date

    public init(
        path: String,
        displayName: String,
        createdAt: Date,
        lastOpenedAt: Date
    ) {
        self.path = path
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct RecentProjectValidation: Equatable, Sendable {
    public let path: String
    public let exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

public final class RecentProjectStore {
    private let databaseQueue: DatabaseQueue
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        databaseURL: URL = RecentProjectStore.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.fileManager = fileManager
        self.now = now

        let databaseDirectory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )

        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(databaseQueue)
    }

    public static func defaultDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".level5build", isDirectory: true)
            .appendingPathComponent("level5.sqlite")
    }

    public static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public func listRecentProjects() throws -> [RecentProject] {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT path, displayName, createdAt, lastOpenedAt
                FROM recent_projects
                ORDER BY lastOpenedAt DESC
                """
            )

            return rows.map(Self.recentProject(from:))
        }
    }

    @discardableResult
    public func upsertSelectedFolder(at url: URL) throws -> RecentProject {
        let path = Self.normalizedPath(url.path)
        let displayName = URL(fileURLWithPath: path).lastPathComponent
        let openedAt = now()
        let openedAtInterval = openedAt.timeIntervalSince1970

        return try databaseQueue.write { db in
            let existingCreatedAt = try Double.fetchOne(
                db,
                sql: "SELECT createdAt FROM recent_projects WHERE path = ?",
                arguments: [path]
            )
            let createdAtInterval = existingCreatedAt ?? openedAtInterval

            try db.execute(
                sql: """
                INSERT INTO recent_projects (path, displayName, createdAt, lastOpenedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    displayName = excluded.displayName,
                    lastOpenedAt = excluded.lastOpenedAt
                """,
                arguments: [path, displayName, createdAtInterval, openedAtInterval]
            )

            try db.execute(
                sql: """
                DELETE FROM recent_projects
                WHERE path NOT IN (
                    SELECT path
                    FROM recent_projects
                    ORDER BY lastOpenedAt DESC
                    LIMIT 10
                )
                """
            )

            return RecentProject(
                path: path,
                displayName: displayName,
                createdAt: Date(timeIntervalSince1970: createdAtInterval),
                lastOpenedAt: openedAt
            )
        }
    }

    public func removeRecentProject(path: String) throws {
        let normalizedPath = Self.normalizedPath(path)

        try databaseQueue.write { db in
            try db.execute(
                sql: "DELETE FROM recent_projects WHERE path = ?",
                arguments: [normalizedPath]
            )
        }
    }

    public func validateDirectoryExistence(path: String) -> RecentProjectValidation {
        let normalizedPath = Self.normalizedPath(path)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)

        return RecentProjectValidation(
            path: normalizedPath,
            exists: exists && isDirectory.boolValue
        )
    }

    public func hasRecentProjectsTable() throws -> Bool {
        try databaseQueue.read { db in
            try db.tableExists("recent_projects")
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createRecentProjects") { db in
            try db.create(table: "recent_projects", ifNotExists: true) { table in
                table.column("path", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("createdAt", .double).notNull()
                table.column("lastOpenedAt", .double).notNull().indexed()
            }
        }

        return migrator
    }()

    private static func recentProject(from row: Row) -> RecentProject {
        RecentProject(
            path: row["path"],
            displayName: row["displayName"],
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            lastOpenedAt: Date(timeIntervalSince1970: row["lastOpenedAt"])
        )
    }
}
