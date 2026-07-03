import Testing
import Level5Core

@Suite("Build profile")
struct BuildProfileTests {
    @Test("Default profile preserves app identity")
    func defaultProfile() {
        let profile = BuildProfile()

        #expect(profile.productName == "Level5 Build")
        #expect(profile.bundleIdentifier == "io.anvia.level5.build")
        #expect(profile.version == "0.0.0")
        #expect(profile.displayTitle == "Level5 Build 0.0.0")
    }
}
