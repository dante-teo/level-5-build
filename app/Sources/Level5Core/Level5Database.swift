import Foundation
import GRDB

/// A single named migration owned and defined by the store whose schema it
/// creates or evolves. Stores expose their migrations as `static let`/`var`
/// arrays (see `RecentProjectStore.migrations`,
/// `SessionPersistenceStore.migrations`) so schema locality is preserved;
/// `Level5Database` only composes those lists into one explicit, ordered
/// migrator for the single shared connection.
public struct DatabaseMigration: Sendable {
    public let identifier: String
    public let migrate: @Sendable (Database) throws -> Void

    public init(identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier
        self.migrate = migrate
    }
}

/// Owns the single `DatabaseQueue` connection to the app's SQLite file and
/// the single `DatabaseMigrator` that evolves its schema. GRDB recommends one
/// writer connection per file; two independent `DatabaseQueue`s to the same
/// file would work but buy nothing here, so every store that needs durable
/// storage shares this one connection.
public final class Level5Database {
    public let dbQueue: DatabaseQueue

    public init(
        databaseURL: URL = Level5Database.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        migrations: [DatabaseMigration]
    ) throws {
        let databaseDirectory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )

        dbQueue = try DatabaseQueue(path: databaseURL.path)

        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier, migrate: migration.migrate)
        }
        try migrator.migrate(dbQueue)
    }

    public static func defaultDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".level5build", isDirectory: true)
            .appendingPathComponent("level5.sqlite")
    }
}
