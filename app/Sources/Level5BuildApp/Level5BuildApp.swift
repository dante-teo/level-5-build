import Level5Design
import SwiftUI

@main
public struct Level5BuildApp: App {
    public init() {
        Level5DesignResources.registerFonts()
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
