import Level5Core
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
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.productName)
                .font(.system(.largeTitle, design: .default, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text(status.title)
                    .font(.headline)

                Text(status.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text("Version \(profile.version)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 640, minHeight: 420, alignment: .topLeading)
        .padding(32)
        .background(.regularMaterial)
    }
}
