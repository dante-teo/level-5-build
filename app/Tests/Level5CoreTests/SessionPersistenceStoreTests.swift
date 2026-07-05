import Foundation
import Testing
import Level5Core

@Suite("Session persistence store")
struct SessionPersistenceStoreTests {
    @Test("Migrations create the sessions and transcript tables")
    func migrationsCreateTables() throws {
        let fixture = try StoreFixture()

        let tablesExist = try fixture.database.dbQueue.read { db in
            try db.tableExists("sessions")
                && db.tableExists("session_transcript_items")
                && db.tableExists("session_transcript_state")
        }
        #expect(tablesExist)
    }

    @Test("Session rows round-trip through upsert and list, scoped by project key")
    func sessionRowRoundTrip() throws {
        let fixture = try StoreFixture()
        let row = PersistedSessionRow(
            sessionId: "s1",
            projectKey: "/tmp/project",
            backend: "devin",
            title: "Fix bug",
            detail: "project - /tmp/project",
            providerUpdatedAt: 100,
            observedAt: 200,
            createdAt: 50
        )

        try fixture.store.upsertSessionRow(row)
        let otherProjectRow = PersistedSessionRow(
            sessionId: "s2",
            projectKey: "/tmp/other",
            backend: "devin",
            title: "Other",
            detail: "other",
            createdAt: 10
        )
        try fixture.store.upsertSessionRow(otherProjectRow)

        #expect(try fixture.store.listSessionRows(projectKey: "/tmp/project") == [row])
        #expect(try fixture.store.listSessionRows(projectKey: "/tmp/other") == [otherProjectRow])
    }

    @Test("Upserting a session row updates fields in place without duplicating")
    func sessionRowUpsertUpdatesInPlace() throws {
        let fixture = try StoreFixture()
        let original = PersistedSessionRow(
            sessionId: "s1",
            projectKey: "/tmp/project",
            backend: "devin",
            title: "Fix bug",
            detail: "detail",
            createdAt: 50
        )
        try fixture.store.upsertSessionRow(original)

        var updated = original
        updated.title = "Fix bug (updated)"
        updated.observedAt = 500
        try fixture.store.upsertSessionRow(updated)

        let rows = try fixture.store.listSessionRows(projectKey: "/tmp/project")
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Fix bug (updated)")
        #expect(rows.first?.observedAt == 500)
        #expect(rows.first?.createdAt == 50)
    }

    @Test("Sessions are ordered by observed activity, most recent first")
    func sessionRowsOrderedByObservedAt() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "old", projectKey: "/tmp/p", backend: "devin", title: "Old", detail: "d", observedAt: 1, createdAt: 1))
        try fixture.store.upsertSessionRow(.init(sessionId: "new", projectKey: "/tmp/p", backend: "devin", title: "New", detail: "d", observedAt: 2, createdAt: 1))

        let rows = try fixture.store.listSessionRows(projectKey: "/tmp/p")
        #expect(rows.map(\.sessionId) == ["new", "old"])
    }

    @Test("Transcript items round-trip in first-insertion order and upsert preserves that order")
    func transcriptItemsRoundTrip() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))

        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-1", kind: "message", payloadVersion: 1, payload: Data("{\"text\":\"hi\"}".utf8)),
            .init(itemId: "tool-1", kind: "tool", payloadVersion: 1, payload: Data("{\"title\":\"Tool\"}".utf8))
        ])
        // Upserting an update to the first item should not change its position.
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-1", kind: "message", payloadVersion: 1, payload: Data("{\"text\":\"hi there\"}".utf8))
        ])

        let items = try fixture.store.fetchTranscriptItems(sessionId: "s1")
        #expect(items.map(\.itemId) == ["message-1", "tool-1"])
        #expect(items.first?.payload == Data("{\"text\":\"hi there\"}".utf8))
    }

    @Test("Transcript state round-trips optional JSON payload fields")
    func transcriptStateRoundTrip() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))

        let state = PersistedTranscriptState(
            planPayload: Data("{\"title\":\"Plan\"}".utf8),
            usagePayload: nil,
            stopReasonsPayload: Data("[\"end_turn\"]".utf8),
            referencesPayload: nil,
            payloadVersion: 1
        )
        try fixture.store.upsertTranscriptState(sessionId: "s1", state: state)

        #expect(try fixture.store.fetchTranscriptState(sessionId: "s1") == state)
        #expect(try fixture.store.fetchTranscriptState(sessionId: "missing") == nil)
    }

    @Test("Deleting a session cascades to its transcript items and state")
    func deleteSessionCascades() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-1", kind: "message", payloadVersion: 1, payload: Data("{}".utf8))
        ])
        try fixture.store.upsertTranscriptState(sessionId: "s1", state: .init(payloadVersion: 1))

        try fixture.store.deleteSession(sessionId: "s1")

        #expect(try fixture.store.listSessionRows(projectKey: "/tmp/p").isEmpty)
        #expect(try fixture.store.fetchTranscriptItems(sessionId: "s1").isEmpty)
        #expect(try fixture.store.fetchTranscriptState(sessionId: "s1") == nil)
    }

    @Test("A corrupt transcript item row is skipped, not thrown, and removed so it cannot fail again")
    func corruptTranscriptItemRowIsSkipped() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-1", kind: "message", payloadVersion: 1, payload: Data("{}".utf8))
        ])
        // Bypass the store's typed API to simulate a corrupt row: a
        // payloadVersion value that cannot be decoded as an Int.
        try fixture.database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO session_transcript_items (sessionId, itemId, kind, payloadVersion, payload) VALUES (?, ?, ?, ?, ?)",
                arguments: ["s1", "tool-1", "tool", "not-a-number", "{}"]
            )
        }

        let items = try fixture.store.fetchTranscriptItems(sessionId: "s1")

        #expect(items.map(\.itemId) == ["message-1"])
        // The bad row was deleted, so a second read does not keep failing on it.
        #expect(try fixture.store.fetchTranscriptItems(sessionId: "s1").map(\.itemId) == ["message-1"])
    }

    @Test("A row absent from a fresh upsert batch is not pruned; pruning is delete-only")
    func upsertingFreshBatchDoesNotPruneAbsentRows() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-1", kind: "message", payloadVersion: 1, payload: Data("{}".utf8)),
            .init(itemId: "message-2", kind: "message", payloadVersion: 1, payload: Data("{}".utf8))
        ])

        // A later upsert batch that only contains one of the two items must
        // not remove the other: persistence pruning only ever happens via
        // an explicit `deleteSession` call.
        try fixture.store.upsertTranscriptItems(sessionId: "s1", items: [
            .init(itemId: "message-2", kind: "message", payloadVersion: 1, payload: Data("{\"text\":\"updated\"}".utf8))
        ])

        let items = try fixture.store.fetchTranscriptItems(sessionId: "s1")
        #expect(items.map(\.itemId) == ["message-1", "message-2"])
    }

    @Test("Marking a session hidden records it durably, independent of whether a cached row exists")
    func markingSessionHiddenRecordsItDurably() throws {
        let fixture = try StoreFixture()
        try fixture.store.upsertSessionRow(.init(sessionId: "s1", projectKey: "/tmp/p", backend: "devin", title: "t", detail: "d", createdAt: 1))

        #expect(try fixture.store.hiddenSessionIds().isEmpty)

        try fixture.store.deleteSession(sessionId: "s1")
        try fixture.store.markSessionHidden(sessionId: "s1", hiddenAt: 42)

        #expect(try fixture.store.hiddenSessionIds() == Set(["s1"]))
        // The hidden marker is independent of the (now-deleted) cache row.
        #expect(try fixture.store.listSessionRows(projectKey: "/tmp/p").isEmpty)
    }

    @Test("Marking the same session hidden twice does not duplicate or throw")
    func markingSessionHiddenTwiceIsIdempotent() throws {
        let fixture = try StoreFixture()

        try fixture.store.markSessionHidden(sessionId: "s1", hiddenAt: 1)
        try fixture.store.markSessionHidden(sessionId: "s1", hiddenAt: 2)

        #expect(try fixture.store.hiddenSessionIds() == Set(["s1"]))
    }
}

private struct StoreFixture {
    let root: URL
    let database: Level5Database
    let store: SessionPersistenceStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5BuildTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try Level5Database(
            databaseURL: root.appendingPathComponent("level5.sqlite"),
            migrations: SessionPersistenceStore.migrations
        )
        store = SessionPersistenceStore(database: database)
    }
}
