import SwiftUI

public struct ShellCommands {
    public let newChat: () -> Void
    public let toggleSidebar: () -> Void
    public let focusComposer: () -> Void
    public let clearTranscript: () -> Void

    public init(
        newChat: @escaping () -> Void,
        toggleSidebar: @escaping () -> Void,
        focusComposer: @escaping () -> Void,
        clearTranscript: @escaping () -> Void
    ) {
        self.newChat = newChat
        self.toggleSidebar = toggleSidebar
        self.focusComposer = focusComposer
        self.clearTranscript = clearTranscript
    }
}

private struct ShellCommandsKey: FocusedValueKey {
    typealias Value = ShellCommands
}

public extension FocusedValues {
    var shellCommands: ShellCommands? {
        get { self[ShellCommandsKey.self] }
        set { self[ShellCommandsKey.self] = newValue }
    }
}
