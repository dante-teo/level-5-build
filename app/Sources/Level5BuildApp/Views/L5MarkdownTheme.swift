import Level5Design
import MarkdownUI
import SwiftUI

/// A `MarkdownUI` theme that mirrors the design system's typography and
/// color tokens (`L5Font`/`L5Color`) so agent/user messages that contain
/// Markdown (bold, code spans, lists, links, ...) render with real
/// formatting inside a transcript bubble instead of raw `**`/backtick/`-`
/// syntax, while still looking like the rest of the app.
extension Theme {
    @MainActor static let level5 = Theme()
        .text {
            FontFamily(.custom(L5Font.family))
            FontSize(14)
            ForegroundColor(L5Color.textPrimary)
        }
        .code {
            FontFamily(.custom(L5Font.monoFamily))
            FontSize(.em(0.9))
            ForegroundColor(L5Color.textPrimary)
            BackgroundColor(L5Color.secondaryBackground)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(L5Color.accent)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: L5Spacing.x3, bottom: L5Spacing.x1)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(2))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: L5Spacing.x3, bottom: L5Spacing.x1)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.5))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: L5Spacing.x2, bottom: L5Spacing.x1)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: L5Spacing.x2)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(L5Color.border)
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(L5Color.textSecondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamily(.custom(L5Font.monoFamily))
                        FontSize(.em(0.9))
                    }
                    .padding(L5Spacing.x3)
            }
            .background(L5Color.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: L5Radius.small))
            .markdownMargin(top: 0, bottom: L5Spacing.x2)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: L5Spacing.x1 / 2)
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(L5Color.accent, L5Color.secondaryBackground)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .thematicBreak {
            Divider()
                .overlay(L5Color.border)
                .markdownMargin(top: L5Spacing.x2, bottom: L5Spacing.x2)
        }
}
