import Level5Design
import SwiftUI

struct TranscriptView: View {
    let items: [LocalTranscriptItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: L5Spacing.x4) {
                ForEach(items) { item in
                    TranscriptRow(item: item)
                }
            }
            .padding(L5Spacing.x6)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct TranscriptRow: View {
    let item: LocalTranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: L5Spacing.x3) {
            roleIcon
                .frame(width: 26, height: 26)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: L5Spacing.x1) {
                Text(roleTitle)
                    .font(L5Font.caption)
                    .foregroundStyle(.secondary)

                Text(item.text)
                    .font(L5Font.body)
                    .foregroundStyle(L5Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(L5Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(L5Color.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch item.role {
        case .user:
            Image(systemName: "person.fill")
                .foregroundStyle(.white)
        case .status:
            Image(systemName: "info")
                .foregroundStyle(.secondary)
        }
    }

    private var roleTitle: String {
        switch item.role {
        case .user: "You"
        case .status: "Status"
        }
    }

    private var iconBackground: Color {
        switch item.role {
        case .user: L5Color.accent
        case .status: L5Color.secondaryBackground
        }
    }

    private var rowMaterial: Material {
        switch item.role {
        case .user: .regularMaterial
        case .status: .thinMaterial
        }
    }
}
