import Level5Core
import Level5Design
import AppKit
import SwiftUI

public struct ContentView: View {
    private let profile: BuildProfile
    private let status: ScaffoldStatus

    public init(
        profile: BuildProfile = BuildProfile(),
        status: ScaffoldStatus = ScaffoldStatus()
    ) {
        self.profile = profile
        self.status = status
    }

    public var body: some View {
        ZStack {
            WindowBackgroundImage()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: L5Spacing.x6) {
                HStack(spacing: L5Spacing.x3) {
                    L5Asset.mark
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: L5Spacing.x1) {
                        Text("Level5")
                            .font(L5Font.h2)
                            .foregroundStyle(L5Color.textPrimary)

                        Text(profile.displayTitle)
                            .font(L5Font.caption)
                            .foregroundStyle(L5Color.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: L5Spacing.x4) {
                    Text(status.title)
                        .font(L5Font.h1)
                        .foregroundStyle(L5Color.textPrimary)

                    Text(status.detail)
                        .font(L5Font.body)
                        .foregroundStyle(L5Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: L5Spacing.x3) {
                        Button("Design primitives ready") {}
                            .buttonStyle(L5ButtonStyle(.primary))
                            .disabled(true)

                        Text("Native SwiftUI surface")
                            .font(L5Font.caption)
                            .foregroundStyle(L5Color.textMuted)
                    }
                }
                .padding(L5Spacing.x6)
                .frame(maxWidth: 480, alignment: .leading)
                .l5Surface(.glass)

                Spacer()

                Text("Version \(profile.version)")
                    .font(L5Font.mono(size: 12))
                    .foregroundStyle(L5Color.textMuted)
            }
            .padding(L5Spacing.x8)
        }
        .frame(minWidth: 640, minHeight: 420, alignment: .topLeading)
    }
}

private struct WindowBackgroundImage: View {
    var body: some View {
        GeometryReader { proxy in
            if let image = NSImage(named: "WindowBackground") ?? Self.resourceImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(L5Color.background.opacity(0.18))
            } else {
                L5Color.background
            }
        }
    }

    private static var resourceImage: NSImage? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "WindowBackground", withExtension: "jpeg") {
            return NSImage(contentsOf: url)
        }
        #endif

        guard let url = Bundle.main.url(forResource: "WindowBackground", withExtension: "jpeg") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}
