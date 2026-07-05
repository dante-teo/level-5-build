import AppKit
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
            L5IconView(.agent)
                .foregroundStyle(L5Color.accent)
        }
        .padding(L5Spacing.x4)
        .l5Surface(.card)
        .l5CompactControl()

        _ = view
    }

    @Test("Accent token keeps primary button foreground readable")
    func accentForegroundContrast() throws {
        let lightAccent = try sRGBColor(L5Color.accentLight)
        let lightForeground = try sRGBColor(L5Color.accentForegroundLight)
        let darkAccent = try sRGBColor(L5Color.accentDark)
        let darkForeground = try sRGBColor(L5Color.accentForegroundDark)

        #expect(hex(lightAccent) == "3F5CF5")
        #expect(contrastRatio(lightAccent, lightForeground) >= 4.5)
        #expect(contrastRatio(darkAccent, darkForeground) >= 4.5)
    }

    private func sRGBColor(_ color: NSColor) throws -> NSColor {
        try #require(color.usingColorSpace(.sRGB))
    }

    private func hex(_ color: NSColor) -> String {
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
