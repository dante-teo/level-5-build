import SwiftUI
import Testing
@testable import Level5Design

@Suite("Level5 design primitives")
struct Level5DesignTests {
    @Test("Token scales preserve documented values")
    func tokenScales() {
        #expect(L5Spacing.x1 == 4)
        #expect(L5Spacing.x6 == 24)
        #expect(L5Spacing.x16 == 64)
        #expect(L5Radius.panel == 24)
        #expect(L5Radius.button == 16)
        #expect(L5Elevation.e0.opacity == 0)
        #expect(L5Elevation.e2.y == 12)
    }

    @Test("Font resources are discoverable and register")
    func fontResources() {
        #expect(Level5DesignResources.fontResourceURLs.count == Level5DesignResources.fontResourceNames.count)
        #expect(Level5DesignResources.registerFonts())
        #expect(Level5DesignResources.registerFonts())
    }

    @Test("Identity mark resource is discoverable")
    func identityMarkResource() {
        #expect(Level5DesignResources.identityMarkURL != nil)
    }

    @Test("SwiftUI style APIs compile")
    @MainActor
    func styleSmoke() {
        let view = VStack {
            Text("Level5")
                .font(L5Font.h1)
                .foregroundStyle(L5Color.textPrimary)
            Button("Continue") {}
                .buttonStyle(L5ButtonStyle(.primary))
            TextField("Prompt", text: .constant(""))
                .l5InputSurface()
            L5Asset.mark
                .resizable()
                .frame(width: 16, height: 16)
        }
        .padding(L5Spacing.x4)
        .l5Surface(.card)
        .l5CompactControl()

        _ = view
    }
}
