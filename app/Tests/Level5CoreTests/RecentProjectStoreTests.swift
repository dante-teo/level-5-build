import Foundation
import Testing
import Level5Core

@Suite("Recent project store")
struct RecentProjectStoreTests {
    @Test("Migrations create the recent projects table")
    func migrationsCreateRecentProjectsTable() throws {
        let fixture = try StoreFixture()

        #expect(try fixture.store.hasRecentProjectsTable())
    }

    @Test("Upserting stores normalized path, display name, and timestamps")
    func upsertStoresProjectFields() throws {
        let fixture = try StoreFixture(now: Date(timeIntervalSince1970: 100))
        let projectURL = try fixture.createDirectory(named: "level-5-build")

        let project = try fixture.store.upsertSelectedFolder(at: projectURL.appendingPathComponent("."))

        #expect(project.path == projectURL.standardizedFileURL.path)
        #expect(project.displayName == "level-5-build")
        #expect(project.createdAt == Date(timeIntervalSince1970: 100))
        #expect(project.lastOpenedAt == Date(timeIntervalSince1970: 100))
        #expect(try fixture.store.listRecentProjects() == [project])
    }

    @Test("Re-selecting the same normalized path updates last opened without duplicating")
    func reselectUpdatesLastOpened() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let fixture = try StoreFixture(clock: clock)
        let projectURL = try fixture.createDirectory(named: "level-5-build")

        _ = try fixture.store.upsertSelectedFolder(at: projectURL)
        clock.date = Date(timeIntervalSince1970: 200)
        let updated = try fixture.store.upsertSelectedFolder(at: projectURL.appendingPathComponent("."))
        let projects = try fixture.store.listRecentProjects()

        #expect(projects.count == 1)
        #expect(projects.first == updated)
        #expect(projects.first?.createdAt == Date(timeIntervalSince1970: 100))
        #expect(projects.first?.lastOpenedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("Recent projects are ordered by last opened and pruned to ten")
    func recentsAreOrderedAndPruned() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let fixture = try StoreFixture(clock: clock)

        for index in 0..<12 {
            clock.date = Date(timeIntervalSince1970: TimeInterval(index))
            let url = try fixture.createDirectory(named: "project-\(index)")
            try fixture.store.upsertSelectedFolder(at: url)
        }

        let projects = try fixture.store.listRecentProjects()

        #expect(projects.count == 10)
        #expect(projects.map(\.displayName) == (2..<12).reversed().map { "project-\($0)" })
    }

    @Test("Removing a recent deletes only that path")
    func removeDeletesOnlyThatPath() throws {
        let fixture = try StoreFixture()
        let first = try fixture.store.upsertSelectedFolder(at: fixture.createDirectory(named: "first"))
        let second = try fixture.store.upsertSelectedFolder(at: fixture.createDirectory(named: "second"))

        try fixture.store.removeRecentProject(path: first.path)

        #expect(try fixture.store.listRecentProjects() == [second])
    }

    @Test("Directory validation accepts existing directories and rejects missing paths")
    func validatesDirectoryExistence() throws {
        let fixture = try StoreFixture()
        let existing = try fixture.createDirectory(named: "existing")
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let file = fixture.root.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(fixture.store.validateDirectoryExistence(path: existing.path).exists)
        #expect(fixture.store.validateDirectoryExistence(path: missing.path).exists == false)
        #expect(fixture.store.validateDirectoryExistence(path: file.path).exists == false)
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

private struct StoreFixture {
    let root: URL
    let store: RecentProjectStore

    init(now: Date = Date(timeIntervalSince1970: 0)) throws {
        let clock = TestClock(now)
        try self.init(clock: clock)
    }

    init(clock: TestClock) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Level5BuildTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try RecentProjectStore(
            databaseURL: root.appendingPathComponent("level5.sqlite"),
            now: { clock.date }
        )
    }

    func createDirectory(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
