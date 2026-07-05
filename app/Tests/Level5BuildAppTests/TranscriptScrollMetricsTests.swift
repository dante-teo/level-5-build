import CoreGraphics
import Testing
@testable import Level5BuildApp

@Suite("Transcript scroll metrics")
struct TranscriptScrollMetricsTests {
    @Test("Flipped scroll views treat max visible Y as bottom")
    func flippedBottomDetection() {
        let document = CGRect(x: 0, y: 0, width: 800, height: 1_000)

        #expect(TranscriptScrollMetrics.bottomOriginY(
            documentBounds: document,
            viewportHeight: 300,
            isFlipped: true
        ) == 700)
        #expect(TranscriptScrollMetrics.isAtBottom(
            documentBounds: document,
            visibleRect: CGRect(x: 0, y: 700, width: 800, height: 300),
            viewportHeight: 300,
            isFlipped: true,
            threshold: 24
        ))
        #expect(!TranscriptScrollMetrics.isAtBottom(
            documentBounds: document,
            visibleRect: CGRect(x: 0, y: 650, width: 800, height: 300),
            viewportHeight: 300,
            isFlipped: true,
            threshold: 24
        ))
    }

    @Test("Non-flipped scroll views treat min visible Y as bottom")
    func nonFlippedBottomDetection() {
        let document = CGRect(x: 0, y: 0, width: 800, height: 1_000)

        #expect(TranscriptScrollMetrics.bottomOriginY(
            documentBounds: document,
            viewportHeight: 300,
            isFlipped: false
        ) == 0)
        #expect(TranscriptScrollMetrics.isAtBottom(
            documentBounds: document,
            visibleRect: CGRect(x: 0, y: 0, width: 800, height: 300),
            viewportHeight: 300,
            isFlipped: false,
            threshold: 24
        ))
        #expect(!TranscriptScrollMetrics.isAtBottom(
            documentBounds: document,
            visibleRect: CGRect(x: 0, y: 50, width: 800, height: 300),
            viewportHeight: 300,
            isFlipped: false,
            threshold: 24
        ))
    }

    @Test("Short content is always considered at bottom")
    func shortContentIsAtBottom() {
        #expect(TranscriptScrollMetrics.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 200),
            visibleRect: CGRect(x: 0, y: 0, width: 800, height: 200),
            viewportHeight: 300,
            isFlipped: true,
            threshold: 24
        ))
    }
}
