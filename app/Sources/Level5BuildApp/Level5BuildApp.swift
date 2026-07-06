import Level5Design
import SwiftUI

@main
public struct Level5BuildApp: App {
    @NSApplicationDelegateAdaptor(Level5AppDelegate.self) private var appDelegate
    @FocusedValue(\.shellCommands) private var shellCommands

    public init() {
        Level5DesignResources.registerFonts()
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    shellCommands?.newChat()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(shellCommands == nil)
            }

            CommandMenu("Workspace") {
                Button("Toggle Sidebar") {
                    shellCommands?.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(shellCommands == nil)

                Button("Focus Composer") {
                    shellCommands?.focusComposer()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(shellCommands == nil)

                Divider()

                Button("Clear Transcript") {
                    shellCommands?.clearTranscript()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(shellCommands == nil)
            }
        }
    }
}
