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

    /// Preferred initializer: shares the single connection/migrator owned by
    /// `database` instead of opening its own queue.
    public init(
        database: Level5Database,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseQueue = database.dbQueue
        self.fileManager = fileManager
        self.now = now
    }

    /// Convenience path that opens (and migrates) its own `Level5Database`
    /// scoped to just this store's schema. Kept so `ContentView.init` and
    /// existing tests can keep constructing a store directly from a
    /// database URL without needing to know about `Level5Database`.
    public convenience init(
        databaseURL: URL = RecentProjectStore.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let database = try Level5Database(
            databaseURL: databaseURL,
            fileManager: fileManager,
            migrations: RecentProjectStore.migrations
        )
        self.init(database: database, fileManager: fileManager, now: now)
    }

    public static func defaultDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        Level5Database.defaultDatabaseURL(homeDirectory: homeDirectory)
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

    /// This store's own named migrations, in the order they must apply.
    /// `Level5Database` composes these alongside every other store's
    /// migrations into one ordered migrator for the shared connection.
    public static let migrations: [DatabaseMigration] = [
        DatabaseMigration(identifier: "createRecentProjects") { db in
            try db.create(table: "recent_projects", ifNotExists: true) { table in
                table.column("path", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("createdAt", .double).notNull()
                table.column("lastOpenedAt", .double).notNull().indexed()
            }
        }
    ]

    private static func recentProject(from row: Row) -> RecentProject {
        RecentProject(
            path: row["path"],
            displayName: row["displayName"],
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            lastOpenedAt: Date(timeIntervalSince1970: row["lastOpenedAt"])
        )
    }
}
