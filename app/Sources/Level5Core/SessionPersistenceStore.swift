import Foundation
import GRDB

/// A durable, provider-neutral record of a known agent session. Mirrors the
/// subset of app-private `AgentSessionRow` state that should survive a
/// relaunch; live turn-state (`isRunning`, `isAwaitingPermission`,
/// `hasCompletedTurn`) is intentionally not part of this shape.
public struct PersistedSessionRow: Equatable, Sendable {
    public var sessionId: String
    public var projectKey: String
    public var backend: String
    public var title: String
    public var detail: String
    public var providerUpdatedAt: Double?
    public var observedAt: Double?
    public var createdAt: Double

    public init(
        sessionId: String,
        projectKey: String,
        backend: String,
        title: String,
        detail: String,
        providerUpdatedAt: Double? = nil,
        observedAt: Double? = nil,
        createdAt: Double
    ) {
        self.sessionId = sessionId
        self.projectKey = projectKey
        self.backend = backend
        self.title = title
        self.detail = detail
        self.providerUpdatedAt = providerUpdatedAt
        self.observedAt = observedAt
        self.createdAt = createdAt
    }
}

/// One ordered transcript item (a message/tool/status/error row, keyed by
/// the same stable ids the in-memory reducer already uses). `kind` and
/// `payload` are opaque to this store: it never interprets transcript JSON
/// shape, so it stays reusable by any future non-GUI client.
public struct PersistedTranscriptItem: Equatable, Sendable {
    public var itemId: String
    public var kind: String
    public var payloadVersion: Int
    public var payload: Data

    public init(itemId: String, kind: String, payloadVersion: Int, payload: Data) {
        self.itemId = itemId
        self.kind = kind
        self.payloadVersion = payloadVersion
        self.payload = payload
    }
}

/// The singleton, per-session transcript fields that aren't an ordered list
/// (plan/usage/stop-reasons/references). Each field is independently
/// optional JSON, opaque to this store.
public struct PersistedTranscriptState: Equatable, Sendable {
    public var planPayload: Data?
    public var usagePayload: Data?
    public var stopReasonsPayload: Data?
    public var referencesPayload: Data?
    public var payloadVersion: Int

    public init(
        planPayload: Data? = nil,
        usagePayload: Data? = nil,
        stopReasonsPayload: Data? = nil,
        referencesPayload: Data? = nil,
        payloadVersion: Int
    ) {
        self.planPayload = planPayload
        self.usagePayload = usagePayload
        self.stopReasonsPayload = stopReasonsPayload
        self.referencesPayload = referencesPayload
        self.payloadVersion = payloadVersion
    }
}

/// Durable storage for sessions and their cached transcript content.
/// Provider-neutral and shape-agnostic about transcript internals: it only
/// ever sees `(kind: String, payload: Data)`. Synchronous/throwing, matching
/// `RecentProjectStore`'s existing style; there is no async ceremony here,
/// callers decide how/where to hop off the main actor.
public final class SessionPersistenceStore: Sendable {
    private let databaseQueue: DatabaseQueue

    public init(database: Level5Database) {
        self.databaseQueue = database.dbQueue
    }

    // MARK: - Sessions

    public func listSessionRows(projectKey: String) throws -> [PersistedSessionRow] {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sessionId, projectKey, backend, title, detail, providerUpdatedAt, observedAt, createdAt
                FROM sessions
                WHERE projectKey = ?
                ORDER BY observedAt DESC
                """,
                arguments: [projectKey]
            )
            return rows.compactMap(Self.sessionRow(from:))
        }
    }

    public func upsertSessionRow(_ row: PersistedSessionRow) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (sessionId, projectKey, backend, title, detail, providerUpdatedAt, observedAt, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET
                    projectKey = excluded.projectKey,
                    backend = excluded.backend,
                    title = excluded.title,
                    detail = excluded.detail,
                    providerUpdatedAt = excluded.providerUpdatedAt,
                    observedAt = excluded.observedAt
                """,
                arguments: [
                    row.sessionId,
                    row.projectKey,
                    row.backend,
                    row.title,
                    row.detail,
                    row.providerUpdatedAt,
                    row.observedAt,
                    row.createdAt
                ]
            )
        }
    }

    /// Removes the session row and, via `ON DELETE CASCADE`, every
    /// transcript item and state row for it.
    public func deleteSession(sessionId: String) throws {
        try databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE sessionId = ?", arguments: [sessionId])
        }
    }

    // MARK: - Hidden sessions

    /// Records that the user deleted `sessionId` locally. Some ACP backends
    /// (e.g. real Devin) don't implement `session/delete` at all, so our
    /// local session list is not required to stay consistent with whatever
    /// the ACP server still reports: once hidden, a session must never
    /// reappear via a later `session/list`/`session/update`, even across a
    /// relaunch, regardless of whether the backend could also forget it.
    public func markSessionHidden(sessionId: String, hiddenAt: Double) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO hidden_sessions (sessionId, hiddenAt)
                VALUES (?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET hiddenAt = excluded.hiddenAt
                """,
                arguments: [sessionId, hiddenAt]
            )
        }
    }

    public func hiddenSessionIds() throws -> Set<String> {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT sessionId FROM hidden_sessions")
            return Set(rows.compactMap { row -> String? in Self.safeValue(row, "sessionId") })
        }
    }

    // MARK: - Transcript items

    public func upsertTranscriptItems(sessionId: String, items: [PersistedTranscriptItem]) throws {
        guard !items.isEmpty else { return }
        try databaseQueue.write { db in
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO session_transcript_items (sessionId, itemId, kind, payloadVersion, payload)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(sessionId, itemId) DO UPDATE SET
                        kind = excluded.kind,
                        payloadVersion = excluded.payloadVersion,
                        payload = excluded.payload
                    """,
                    arguments: [
                        sessionId,
                        item.itemId,
                        item.kind,
                        item.payloadVersion,
                        String(decoding: item.payload, as: UTF8.self)
                    ]
                )
            }
        }
    }

    /// Ordered by first-insertion order (`ORDER BY id`; upserts preserve the
    /// original row, so no app-maintained sequence counter is needed). Rows
    /// that fail to decode are skipped and deleted so hydration never aborts
    /// and never repeatedly fails on the same bad row.
    public func fetchTranscriptItems(sessionId: String) throws -> [PersistedTranscriptItem] {
        try databaseQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, itemId, kind, payloadVersion, payload
                FROM session_transcript_items
                WHERE sessionId = ?
                ORDER BY id
                """,
                arguments: [sessionId]
            )
            var items: [PersistedTranscriptItem] = []
            for row in rows {
                guard let item = Self.transcriptItem(from: row) else {
                    if let id: Int64 = Self.safeValue(row, "id") {
                        try db.execute(sql: "DELETE FROM session_transcript_items WHERE id = ?", arguments: [id])
                    }
                    continue
                }
                items.append(item)
            }
            return items
        }
    }

    // MARK: - Transcript state

    public func upsertTranscriptState(sessionId: String, state: PersistedTranscriptState) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO session_transcript_state (sessionId, planPayload, usagePayload, stopReasonsPayload, referencesPayload, payloadVersion)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET
                    planPayload = excluded.planPayload,
                    usagePayload = excluded.usagePayload,
                    stopReasonsPayload = excluded.stopReasonsPayload,
                    referencesPayload = excluded.referencesPayload,
                    payloadVersion = excluded.payloadVersion
                """,
                arguments: [
                    sessionId,
                    state.planPayload.map { String(decoding: $0, as: UTF8.self) },
                    state.usagePayload.map { String(decoding: $0, as: UTF8.self) },
                    state.stopReasonsPayload.map { String(decoding: $0, as: UTF8.self) },
                    state.referencesPayload.map { String(decoding: $0, as: UTF8.self) },
                    state.payloadVersion
                ]
            )
        }
    }

    public func fetchTranscriptState(sessionId: String) throws -> PersistedTranscriptState? {
        try databaseQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT sessionId, planPayload, usagePayload, stopReasonsPayload, referencesPayload, payloadVersion
                FROM session_transcript_state
                WHERE sessionId = ?
                """,
                arguments: [sessionId]
            ) else { return nil }
            guard let state = Self.transcriptState(from: row) else {
                try db.execute(sql: "DELETE FROM session_transcript_state WHERE sessionId = ?", arguments: [sessionId])
                return nil
            }
            return state
        }
    }

    // MARK: - Migrations

    /// This store's own named migrations, in the order they must apply.
    /// `Level5Database` composes these alongside every other store's
    /// migrations into one ordered migrator for the shared connection.
    public static let migrations: [DatabaseMigration] = [
        DatabaseMigration(identifier: "createSessions") { db in
            try db.create(table: "sessions", ifNotExists: true) { table in
                table.column("sessionId", .text).primaryKey()
                table.column("projectKey", .text).notNull()
                table.column("backend", .text).notNull()
                table.column("title", .text).notNull()
                table.column("detail", .text).notNull()
                table.column("providerUpdatedAt", .double)
                table.column("observedAt", .double)
                table.column("createdAt", .double).notNull()
            }
            try db.create(
                index: "idx_sessions_projectKey_observedAt",
                on: "sessions",
                columns: ["projectKey", "observedAt"],
                ifNotExists: true
            )
        },
        DatabaseMigration(identifier: "createSessionTranscriptItems") { db in
            try db.create(table: "session_transcript_items", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("sessionId", .text).notNull().references("sessions", onDelete: .cascade)
                table.column("itemId", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("payloadVersion", .integer).notNull()
                table.column("payload", .text).notNull()
                table.uniqueKey(["sessionId", "itemId"])
            }
        },
        DatabaseMigration(identifier: "createSessionTranscriptState") { db in
            try db.create(table: "session_transcript_state", ifNotExists: true) { table in
                table.column("sessionId", .text).primaryKey().references("sessions", onDelete: .cascade)
                table.column("planPayload", .text)
                table.column("usagePayload", .text)
                table.column("stopReasonsPayload", .text)
                table.column("referencesPayload", .text)
                table.column("payloadVersion", .integer).notNull()
            }
        },
        // Deliberately not a foreign key onto `sessions`: a hidden marker
        // must outlive the (already-deleted) cached session row it refers
        // to, since its entire purpose is remembering a deletion after the
        // cache row is gone.
        DatabaseMigration(identifier: "createHiddenSessions") { db in
            try db.create(table: "hidden_sessions", ifNotExists: true) { table in
                table.column("sessionId", .text).primaryKey()
                table.column("hiddenAt", .double).notNull()
            }
        }
    ]

    // MARK: - Row decoding

    /// Never traps on a type/shape mismatch: uses the non-generic,
    /// non-throwing `Row` subscript and a safe cast so a corrupt row is
    /// reported as `nil` rather than crashing hydration.
    private static func safeValue<T>(_ row: Row, _ column: String) -> T? {
        row[column] as? T
    }

    /// SQLite `INTEGER` columns surface as `Int64` (see `DatabaseValue.Storage`),
    /// so integer fields need their own accessor rather than `safeValue<Int>`.
    private static func safeIntValue(_ row: Row, _ column: String) -> Int? {
        (safeValue(row, column) as Int64?).map(Int.init)
    }

    private static func sessionRow(from row: Row) -> PersistedSessionRow? {
        guard let sessionId: String = safeValue(row, "sessionId"),
              let projectKey: String = safeValue(row, "projectKey"),
              let backend: String = safeValue(row, "backend"),
              let title: String = safeValue(row, "title"),
              let detail: String = safeValue(row, "detail"),
              let createdAt: Double = safeValue(row, "createdAt")
        else { return nil }
        return PersistedSessionRow(
            sessionId: sessionId,
            projectKey: projectKey,
            backend: backend,
            title: title,
            detail: detail,
            providerUpdatedAt: safeValue(row, "providerUpdatedAt"),
            observedAt: safeValue(row, "observedAt"),
            createdAt: createdAt
        )
    }

    private static func transcriptItem(from row: Row) -> PersistedTranscriptItem? {
        guard let itemId: String = safeValue(row, "itemId"),
              let kind: String = safeValue(row, "kind"),
              let payloadVersion = safeIntValue(row, "payloadVersion"),
              let payload: String = safeValue(row, "payload")
        else { return nil }
        return PersistedTranscriptItem(
            itemId: itemId,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: Data(payload.utf8)
        )
    }

    private static func transcriptState(from row: Row) -> PersistedTranscriptState? {
        guard let payloadVersion = safeIntValue(row, "payloadVersion") else { return nil }
        let planPayload: String? = safeValue(row, "planPayload")
        let usagePayload: String? = safeValue(row, "usagePayload")
        let stopReasonsPayload: String? = safeValue(row, "stopReasonsPayload")
        let referencesPayload: String? = safeValue(row, "referencesPayload")
        return PersistedTranscriptState(
            planPayload: planPayload.map { Data($0.utf8) },
            usagePayload: usagePayload.map { Data($0.utf8) },
            stopReasonsPayload: stopReasonsPayload.map { Data($0.utf8) },
            referencesPayload: referencesPayload.map { Data($0.utf8) },
            payloadVersion: payloadVersion
        )
    }
}
