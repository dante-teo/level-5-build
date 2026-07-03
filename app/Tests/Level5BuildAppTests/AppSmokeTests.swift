import Testing
@testable import Level5BuildApp

@Suite("App smoke tests")
struct AppSmokeTests {
    @Test("Content view can be constructed")
    @MainActor
    func contentViewConstruction() {
        _ = ContentView()
    }
}
